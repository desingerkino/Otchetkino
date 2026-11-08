import CoreData
import Combine
import Foundation

extension Notification.Name {
    /// Поля ввода сразу записывают отложенный текст в данные (перед сохранением, переходом, закрытием).
    static let rkFlushEdits = Notification.Name("rk.flushEdits")
}

/// Автоматическое сохранение: любое изменение записывается в базу через короткую паузу после последней правки;
/// при переходе к другой покупке, смене проекта, уходе в фон и закрытии приложения сохранение принудительное.
/// Ручная кнопка «Сохранить» вызывает тот же `saveNow()`.
@MainActor
final class SaveCoordinator: ObservableObject {
    enum State: Equatable {
        case saved
        case dirty
        case saving
        case failed(String)
    }

    static let shared = SaveCoordinator(context: PersistenceController.shared.viewContext)

    @Published private(set) var state: State = .saved
    @Published private(set) var lastSavedAt: Date?

    /// Пауза после последней правки перед автосохранением.
    var debounce: TimeInterval = 0.8

    private let context: NSManagedObjectContext
    private var observer: AnyCancellable?
    private var debounceWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    /// Чеки, которые сейчас открыты в редакторе: пока открыты, пустая форма не удаляется.
    private var activeReceipts = Set<NSManagedObjectID>()

    init(context: NSManagedObjectContext) {
        self.context = context
        observer = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.contextChanged() }
    }

    var isDirty: Bool {
        if case .dirty = state { return true }
        if case .failed = state { return true }
        return context.hasChanges
    }

    var errorText: String {
        if case .failed(let text) = state { return text }
        return ""
    }

    func setActive(_ ids: Set<NSManagedObjectID>) { activeReceipts = ids }

    private func contextChanged() {
        if case .saving = state { return }
        guard context.hasChanges else { return }
        if case .failed = state {} else { state = .dirty }
        scheduleSave()
    }

    private func scheduleSave() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in _ = self?.saveNow() }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Принудительное сохранение всего, что ожидает записи. Возвращает true, если всё записано.
    @discardableResult
    func saveNow() -> Bool {
        debounceWork?.cancel()
        NotificationCenter.default.post(name: .rkFlushEdits, object: nil)
        context.processPendingChanges()
        guard context.hasChanges else {
            state = .saved
            return true
        }
        state = .saving
        // служебные правки перед записью (дата изменения, написание магазина) — не шаг отмены: иначе ⌘Z после автосохранения
        // сначала «отменял» бы невидимое изменение, а не действие пользователя
        context.undoManager?.disableUndoRegistration()
        prepareForSave()
        context.processPendingChanges()
        context.undoManager?.enableUndoRegistration()
        do {
            try context.save()
            state = .saved
            lastSavedAt = Date()
            retryWork?.cancel()
            return true
        } catch {
            // Данные не откатываем и не теряем: они остаются в памяти, ошибка показывается, сохранение повторяется.
            state = .failed(error.localizedDescription)
            scheduleRetry()
            return false
        }
    }

    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in _ = self?.saveNow() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Перед записью: убирает пустые формы, приводит название магазина к единому написанию, запоминает магазин.
    private func prepareForSave() {
        let touched = context.insertedObjects.union(context.updatedObjects)
        var receipts = Set<RReceipt>()
        for o in touched {
            if let r = o as? RReceipt { receipts.insert(r) }
            else if let p = o as? RPurchase, let r = p.receipt { receipts.insert(r) }
            else if let ph = o as? RPhoto, let r = ph.receipt ?? ph.purchase?.receipt { receipts.insert(r) }
        }
        for r in receipts where !r.isDeleted {
            if r.isBlank && !activeReceipts.contains(r.objectID) {
                DataOps.deleteReceipts(context, [r])   // пустая форма исчезает, номера остальных остаются подряд
                continue
            }
            let storeChanged = r.isInserted || r.changedValues()["store"] != nil
            if storeChanged, !StoreDirectory.clean(r.store).isEmpty {
                let canonical = StoreDirectory.remember(context, name: r.store)
                if r.store != canonical { r.store = canonical }
            }
            r.updatedAt = Date()
        }
    }
}

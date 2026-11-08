import CoreData
import Combine
import Foundation

/// Хранилище: Core Data + CloudKit (NSPersistentCloudKitContainer).
/// Если iCloud недоступен (нет входа в аккаунт, нет прав, выключено в настройках) — приложение работает полностью локально,
/// а изменения уходят в iCloud сами, как только он станет доступен.
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()
    static let cloudContainerID = "iCloud.ru.desingerkino.rekvizit"
    static let iCloudPrefKey = "iCloudSyncEnabled"

    let container: NSPersistentContainer
    let cloudRequested: Bool
    @Published var syncStatus: String
    @Published var loadError: String?
    private var cancellables = Set<AnyCancellable>()
    private var maintenanceWork: DispatchWorkItem?

    var viewContext: NSManagedObjectContext { container.viewContext }

    static func shouldUseCloud() -> Bool {
        #if LOCAL_ONLY
        return false
        #else
        if let pref = UserDefaults.standard.object(forKey: iCloudPrefKey) as? Bool, pref == false { return false }
        return FileManager.default.ubiquityIdentityToken != nil
        #endif
    }

    /// `storeURL` — отдельный файл базы (для тестов перезапуска приложения); iCloud в этом случае не используется.
    init(inMemory: Bool = false, storeURL: URL? = nil) {
        let useCloud = !inMemory && storeURL == nil && Self.shouldUseCloud()
        cloudRequested = useCloud
        if useCloud {
            container = NSPersistentCloudKitContainer(name: "Rekvizit", managedObjectModel: ModelBuilder.model)
        } else {
            container = NSPersistentContainer(name: "Rekvizit", managedObjectModel: ModelBuilder.model)
        }
        syncStatus = useCloud ? "iCloud: подключение…" : Self.localReason()

        let description = container.persistentStoreDescriptions.first!
        if inMemory { description.url = URL(fileURLWithPath: "/dev/null") }
        if let storeURL = storeURL { description.url = storeURL }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if useCloud {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainerID)
        }

        container.loadPersistentStores { [weak self] _, error in
            if let error = error {
                DispatchQueue.main.async { self?.loadError = error.localizedDescription }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        // Конфликт одновременных правок на разных устройствах: побеждает последнее изменение конкретного поля.
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // Отмена/повтор действий (⌘Z / ⇧⌘Z) работают с реальными данными через undo-менеджер Core Data.
        let undo = UndoManager()
        undo.levelsOfUndo = 60
        container.viewContext.undoManager = undo

        observe()
        scheduleMaintenance(after: 0.5)
        if !inMemory && storeURL == nil { runLaunchCleanup() }
    }

    /// Разовая уборка при запуске: старые «черновики» становятся обычными записями (перед этим делается резервная копия),
    /// пустые формы без данных удаляются.
    private func runLaunchCleanup() {
        let container = self.container
        Task.detached(priority: .utility) {
            let probe = container.newBackgroundContext()
            let needsMigration: Bool = await probe.perform {
                let req = NSFetchRequest<RReceipt>(entityName: "RReceipt")
                req.predicate = NSPredicate(format: "isDraft == YES")
                req.fetchLimit = 1
                return ((try? probe.count(for: req)) ?? 0) > 0 || Maintenance.numbersNeedFix(probe)
            }
            if needsMigration { _ = try? await BackupService.create(container: container) }
            let ctx = container.newBackgroundContext()
            ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            await ctx.perform {
                Maintenance.clearDraftFlags(ctx)
                Maintenance.purgeBlankReceipts(ctx)
                Maintenance.fixDuplicateReceiptNumbers(ctx)
                if ctx.hasChanges { try? ctx.save() }
            }
        }
    }

    private static func localReason() -> String {
        #if LOCAL_ONLY
        return "Работает локально (сборка без iCloud)"
        #else
        if let pref = UserDefaults.standard.object(forKey: iCloudPrefKey) as? Bool, pref == false { return "Синхронизация выключена" }
        return "iCloud недоступен — данные хранятся на устройстве"
        #endif
    }

    private func observe() {
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleMaintenance(after: 1.5) }
            .store(in: &cancellables)

        if cloudRequested {
            NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    guard let self = self,
                          let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                          event.endDate != nil else { return }
                    if let error = event.error {
                        self.syncStatus = "iCloud: ошибка синхронизации (\(error.localizedDescription)). Данные сохранены локально."
                    } else {
                        self.syncStatus = "iCloud: синхронизировано в \(DateFormatter.localizedString(from: event.endDate ?? Date(), dateStyle: .none, timeStyle: .short))"
                    }
                }
                .store(in: &cancellables)
        }
    }

    func scheduleMaintenance(after delay: TimeInterval) {
        maintenanceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runMaintenance() }
        maintenanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Устраняет последствия синхронизации: дубли категорий и повторяющиеся номера чеков.
    func runMaintenance() {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.perform {
            Maintenance.dedupeCategories(ctx)
            Maintenance.fixDuplicateReceiptNumbers(ctx)
            StoreDirectory.seedAndDedupe(ctx)
            if ctx.hasChanges { try? ctx.save() }
        }
    }

    func save() {
        let ctx = viewContext
        guard ctx.hasChanges else { return }
        for o in ctx.updatedObjects {
            if let r = o as? RReceipt { r.updatedAt = Date() } else if let p = o as? RPurchase { p.receipt?.updatedAt = Date() }
        }
        do { try ctx.save() } catch { print("Ошибка сохранения: \(error)") }
    }

    /// Только для тестов и предпросмотра.
    static let preview: PersistenceController = PersistenceController(inMemory: true)
}

enum Maintenance {
    /// Версия 2.0: «черновиков» больше нет — все чеки обычные записи.
    static func clearDraftFlags(_ ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<RReceipt>(entityName: "RReceipt")
        req.predicate = NSPredicate(format: "isDraft == YES")
        for r in (try? ctx.fetch(req)) ?? [] { r.isDraft = false; r.updatedAt = Date() }
    }

    /// Удаляет пустые формы (без фото, магазина, комментария и заполненных позиций).
    static func purgeBlankReceipts(_ ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<RReceipt>(entityName: "RReceipt")
        let blanks = ((try? ctx.fetch(req)) ?? []).filter { $0.isBlank }
        DataOps.deleteReceipts(ctx, blanks)
    }

    static func dedupeCategories(_ ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<RCategory>(entityName: "RCategory")
        guard let all = try? ctx.fetch(req), all.count > 1 else { return }
        let sorted = all.sorted {
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            if a != b { return a < b }
            return ($0.uuid?.uuidString ?? "") < ($1.uuid?.uuidString ?? "")
        }
        var keepers: [String: RCategory] = [:]
        for cat in sorted {
            let key = cat.name.trimmingCharacters(in: .whitespaces).lowercased()
            if let keeper = keepers[key] {
                for p in (cat.purchases as? Set<RPurchase> ?? []) { p.category = keeper }
                ctx.delete(cat)
            } else {
                keepers[key] = cat
            }
        }
    }

    /// Нумерация чеков во всех проектах: без пропусков и повторов (в том числе после синхронизации с другого устройства).
    static func fixDuplicateReceiptNumbers(_ ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<RProject>(entityName: "RProject")
        for project in (try? ctx.fetch(req)) ?? [] { DataOps.normalizeNumbers(project) }
    }

    /// Есть ли проекты с пропусками или повторами в нумерации.
    static func numbersNeedFix(_ ctx: NSManagedObjectContext) -> Bool {
        let req = NSFetchRequest<RProject>(entityName: "RProject")
        for project in (try? ctx.fetch(req)) ?? [] {
            let nums = (project.receipts as? Set<RReceipt> ?? []).map { Int($0.number) }.sorted()
            if !nums.isEmpty, nums != Array(1...nums.count) { return true }
        }
        return false
    }
}

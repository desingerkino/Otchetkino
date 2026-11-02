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

    init(inMemory: Bool = false) {
        let useCloud = !inMemory && Self.shouldUseCloud()
        cloudRequested = useCloud
        if useCloud {
            container = NSPersistentCloudKitContainer(name: "Rekvizit", managedObjectModel: ModelBuilder.model)
        } else {
            container = NSPersistentContainer(name: "Rekvizit", managedObjectModel: ModelBuilder.model)
        }
        syncStatus = useCloud ? "iCloud: подключение…" : Self.localReason()

        let description = container.persistentStoreDescriptions.first!
        if inMemory { description.url = URL(fileURLWithPath: "/dev/null") }
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
        container.viewContext.undoManager = nil

        observe()
        scheduleMaintenance(after: 0.5)
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

    /// Если на двух устройствах одновременно появились чеки с одним номером — более поздний получает следующий свободный номер.
    static func fixDuplicateReceiptNumbers(_ ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<RProject>(entityName: "RProject")
        guard let projects = try? ctx.fetch(req) else { return }
        for project in projects {
            let receipts = (project.receipts as? Set<RReceipt> ?? []).sorted {
                if $0.number != $1.number { return $0.number < $1.number }
                let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
                if a != b { return a < b }
                return ($0.uuid?.uuidString ?? "") < ($1.uuid?.uuidString ?? "")
            }
            var used = Set<Int32>()
            var maxNumber = receipts.map { $0.number }.max() ?? 0
            for r in receipts {
                if r.number <= 0 || used.contains(r.number) {
                    maxNumber += 1
                    r.number = maxNumber
                    r.updatedAt = Date()
                }
                used.insert(r.number)
            }
        }
    }
}

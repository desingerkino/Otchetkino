import Foundation
import CoreData

/// Резервные копии: один ZIP с data.json и оригиналами фотографий. Хранятся в Documents/Резервные копии.
/// Копия создаётся автоматически не чаще раза в сутки; хранятся последние 7.
enum BackupService {
    struct Dump: Codable {
        struct Project: Codable { var uuid: String; var name: String; var holder: String; var createdAt: Date?; var startDate: Date?; var endDate: Date?; var isArchived: Bool }
        struct Advance: Codable { var uuid: String; var project: String?; var kind: Int16; var amountKop: Int64; var date: Date?; var note: String }
        struct Scene: Codable { var uuid: String; var project: String?; var code: String; var title: String; var sortOrder: Int32 }
        struct Category: Codable { var uuid: String; var name: String; var sortOrder: Int32 }
        struct Receipt: Codable { var uuid: String; var project: String?; var number: Int32; var date: Date?; var store: String; var inn: String; var comment: String; var rawText: String; var noReceipt: Bool; var isDraft: Bool; var createdAt: Date? }
        struct Purchase: Codable { var uuid: String; var receipt: String?; var category: String?; var scenes: [String]; var title: String; var amountKop: Int64; var quantity: Double; var purpose: String; var sortOrder: Int32 }
        struct Photo: Codable { var uuid: String; var receipt: String?; var purchase: String?; var fileExtension: String; var sortOrder: Int32; var file: String }
        var version = 1
        var createdAt = Date()
        var projects: [Project] = [], advances: [Advance] = [], scenes: [Scene] = [], categories: [Category] = []
        var receipts: [Receipt] = [], purchases: [Purchase] = [], photos: [Photo] = []
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Резервные копии", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func existingBackups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "zip" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Автокопия: вызывается при запуске и при уходе в фон.
    static func autoBackupIfNeeded(container: NSPersistentContainer) {
        let key = "lastAutoBackup"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task.detached(priority: .utility) {
            if (try? await create(container: container)) != nil {
                UserDefaults.standard.set(Date(), forKey: key)
                prune(keep: 7)
            }
        }
    }

    static func prune(keep: Int) {
        for url in existingBackups().dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }

    @discardableResult
    static func create(container: NSPersistentContainer) async throws -> URL {
        let ctx = container.newBackgroundContext()
        let (dump, files): (Dump, [String: Data]) = await ctx.perform {
            var d = Dump()
            var files: [String: Data] = [:]
            func ids<T: NSManagedObject>(_ set: NSSet?, _ t: T.Type) -> [String] { (set as? Set<T> ?? []).compactMap { ($0.value(forKey: "uuid") as? UUID)?.uuidString } }
            let projects = (try? ctx.fetch(NSFetchRequest<RProject>(entityName: "RProject"))) ?? []
            for p in projects {
                d.projects.append(.init(uuid: p.uuid?.uuidString ?? "", name: p.name, holder: p.holder, createdAt: p.createdAt, startDate: p.startDate, endDate: p.endDate, isArchived: p.isArchived))
                for a in p.advanceList { d.advances.append(.init(uuid: a.uuid?.uuidString ?? "", project: p.uuid?.uuidString, kind: a.kind, amountKop: a.amountKop, date: a.date, note: a.note)) }
                for s in p.sceneList { d.scenes.append(.init(uuid: s.uuid?.uuidString ?? "", project: p.uuid?.uuidString, code: s.code, title: s.title, sortOrder: s.sortOrder)) }
                for r in p.receiptList {
                    d.receipts.append(.init(uuid: r.uuid?.uuidString ?? "", project: p.uuid?.uuidString, number: r.number, date: r.date, store: r.store, inn: r.inn, comment: r.comment, rawText: r.rawText, noReceipt: r.noReceipt, isDraft: r.isDraft, createdAt: r.createdAt))
                    for it in r.purchaseList {
                        d.purchases.append(.init(uuid: it.uuid?.uuidString ?? "", receipt: r.uuid?.uuidString, category: it.category?.uuid?.uuidString,
                                                 scenes: it.sceneList.compactMap { $0.uuid?.uuidString }, title: it.title, amountKop: it.amountKop, quantity: it.quantity, purpose: it.purpose, sortOrder: it.sortOrder))
                        for ph in it.itemPhotoList { addPhoto(ph, receipt: nil, purchase: it.uuid?.uuidString) }
                    }
                    for ph in r.photoList { addPhoto(ph, receipt: r.uuid?.uuidString, purchase: nil) }
                }
            }
            func addPhoto(_ ph: RPhoto, receipt: String?, purchase: String?) {
                guard let data = ph.data, let id = ph.uuid?.uuidString else { return }
                let name = "photos/\(id).\(ph.fileExtension.isEmpty ? "jpg" : ph.fileExtension)"
                files[name] = data
                d.photos.append(.init(uuid: id, receipt: receipt, purchase: purchase, fileExtension: ph.fileExtension, sortOrder: ph.sortOrder, file: name))
            }
            for c in (try? ctx.fetch(NSFetchRequest<RCategory>(entityName: "RCategory"))) ?? [] {
                d.categories.append(.init(uuid: c.uuid?.uuidString ?? "", name: c.name, sortOrder: c.sortOrder))
            }
            return (d, files)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var zip = ZipWriter()
        zip.add(name: "data.json", data: try enc.encode(dump))
        for (name, data) in files { zip.add(name: name, data: data) }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm"
        let url = directory.appendingPathComponent("Реквизит_\(df.string(from: Date())).zip")
        try zip.finish().write(to: url, options: .atomic)
        return url
    }

    /// Восстановление: добавляет то, чего ещё нет (по uuid); существующие записи не перезаписываются.
    static func restore(from url: URL, container: NSPersistentContainer) async throws -> Int {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let zipData = try Data(contentsOf: url)
        guard let files = ZipReader.read(zipData), let json = files["data.json"] else { throw CocoaError(.fileReadCorruptFile) }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let dump = try dec.decode(Dump.self, from: json)
        let ctx = container.newBackgroundContext()
        return try await ctx.perform {
            var added = 0
            func existing<T: NSManagedObject>(_ entity: String, _ type: T.Type) -> [String: T] {
                var map: [String: T] = [:]
                for o in (try? ctx.fetch(NSFetchRequest<T>(entityName: entity))) ?? [] { if let u = (o.value(forKey: "uuid") as? UUID)?.uuidString { map[u] = o } }
                return map
            }
            var projects = existing("RProject", RProject.self), categories = existing("RCategory", RCategory.self), scenes = existing("RScene", RScene.self)
            var receipts = existing("RReceipt", RReceipt.self), purchases = existing("RPurchase", RPurchase.self)
            let advances = existing("RAdvance", RAdvance.self), photos = existing("RPhoto", RPhoto.self)
            for p in dump.projects where projects[p.uuid] == nil {
                let o = RProject(context: ctx); o.uuid = UUID(uuidString: p.uuid); o.name = p.name; o.holder = p.holder; o.createdAt = p.createdAt
                o.startDate = p.startDate; o.endDate = p.endDate; o.isArchived = p.isArchived; projects[p.uuid] = o; added += 1
            }
            for c in dump.categories where categories[c.uuid] == nil {
                let o = RCategory(context: ctx); o.uuid = UUID(uuidString: c.uuid); o.name = c.name; o.sortOrder = c.sortOrder; categories[c.uuid] = o; added += 1
            }
            for s in dump.scenes where scenes[s.uuid] == nil {
                let o = RScene(context: ctx); o.uuid = UUID(uuidString: s.uuid); o.code = s.code; o.title = s.title; o.sortOrder = s.sortOrder
                o.project = s.project.flatMap { projects[$0] }; scenes[s.uuid] = o; added += 1
            }
            for a in dump.advances where advances[a.uuid] == nil {
                let o = RAdvance(context: ctx); o.uuid = UUID(uuidString: a.uuid); o.kind = a.kind; o.amountKop = a.amountKop; o.date = a.date; o.note = a.note
                o.project = a.project.flatMap { projects[$0] }; added += 1
            }
            for r in dump.receipts where receipts[r.uuid] == nil {
                let o = RReceipt(context: ctx); o.uuid = UUID(uuidString: r.uuid); o.number = r.number; o.date = r.date; o.store = r.store; o.inn = r.inn
                o.comment = r.comment; o.rawText = r.rawText; o.noReceipt = r.noReceipt; o.isDraft = r.isDraft; o.createdAt = r.createdAt
                o.project = r.project.flatMap { projects[$0] }; receipts[r.uuid] = o; added += 1
            }
            for p in dump.purchases where purchases[p.uuid] == nil {
                let o = RPurchase(context: ctx); o.uuid = UUID(uuidString: p.uuid); o.title = p.title; o.amountKop = p.amountKop; o.quantity = p.quantity
                o.purpose = p.purpose; o.sortOrder = p.sortOrder; o.receipt = p.receipt.flatMap { receipts[$0] }; o.category = p.category.flatMap { categories[$0] }
                o.mutableSetValue(forKey: "scenes").addObjects(from: p.scenes.compactMap { scenes[$0] }); purchases[p.uuid] = o; added += 1
            }
            for ph in dump.photos where photos[ph.uuid] == nil {
                guard let data = files[ph.file] else { continue }
                let o = RPhoto(context: ctx); o.uuid = UUID(uuidString: ph.uuid); o.data = data; o.thumb = ImageTools.thumbnailJPEG(from: data)
                o.fileExtension = ph.fileExtension; o.sortOrder = ph.sortOrder
                o.receipt = ph.receipt.flatMap { receipts[$0] }; o.purchase = ph.purchase.flatMap { purchases[$0] }; added += 1
            }
            try ctx.save()
            return added
        }
    }
}

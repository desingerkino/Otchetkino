import CoreData
import Foundation

// MARK: - Итоги

struct ProjectTotals {
    var issued: Int64 = 0
    var returned: Int64 = 0
    var spent: Int64 = 0
    var purchaseCount = 0
    var receiptCount = 0          // чеки с фотографией/чеком
    var noReceiptPurchases = 0    // покупки без чека
    /// Остаток = выдано − потрачено − возвращено
    var balance: Int64 { issued - spent - returned }
    var isOverspent: Bool { balance < 0 }
}

struct CategoryTotal: Identifiable {
    let id: String
    let name: String
    let amount: Int64
}

struct CumulativePoint: Identifiable {
    let id: Date
    let date: Date
    let total: Double
}

extension RProject {
    var advanceList: [RAdvance] {
        (advances as? Set<RAdvance> ?? []).sorted {
            let a = $0.date ?? .distantPast, b = $1.date ?? .distantPast
            if a != b { return a < b }
            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }
    var sceneList: [RScene] {
        (scenes as? Set<RScene> ?? []).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.code.localizedStandardCompare($1.code) == .orderedAscending
        }
    }
    var receiptList: [RReceipt] {
        (receipts as? Set<RReceipt> ?? []).sorted {
            if $0.number != $1.number { return $0.number < $1.number }
            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }
    /// Все осмысленные чеки: пустые формы (без данных, фото и суммы) в учёте не участвуют.
    var liveReceipts: [RReceipt] { receiptList.filter { !$0.isBlank } }
    var displayName: String { name.isEmpty ? "Без названия" : name }

    /// Следующий номер: после выравнивания номера идут подряд 1…N, значит новый чек получает N+1.
    var nextReceiptNumber: Int32 { (receiptList.filter { !$0.isDeleted }.map { $0.number }.max() ?? 0) + 1 }

    func totals(from: Date? = nil, to: Date? = nil) -> ProjectTotals {
        var t = ProjectTotals()
        let cal = Calendar.current
        func inRange(_ d: Date?) -> Bool {
            guard let d = d else { return true }
            if let from = from, d < cal.startOfDay(for: from) { return false }
            if let to = to, d >= cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))! { return false }
            return true
        }
        for a in advanceList where inRange(a.date) {
            if a.kind == 0 { t.issued += a.amountKop } else { t.returned += a.amountKop }
        }
        for r in receiptList {
            if r.isBlank { continue }
            guard inRange(r.date) else { continue }
            let items = r.purchaseList.filter { !$0.isBlank }
            t.spent += r.itemsSum
            t.purchaseCount += items.count
            if r.noReceipt { t.noReceiptPurchases += items.count } else { t.receiptCount += 1 }
        }
        return t
    }

    func categoryTotals() -> [CategoryTotal] {
        var map: [String: Int64] = [:]
        for r in liveReceipts {
            for p in r.purchaseList { map[p.category?.name ?? "Без категории", default: 0] += p.amountKop }
        }
        return map.map { CategoryTotal(id: $0.key, name: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
    }

    func cumulativeSpending() -> [CumulativePoint] {
        var perDay: [Date: Int64] = [:]
        let cal = Calendar.current
        for r in liveReceipts {
            let day = cal.startOfDay(for: r.date ?? Date())
            perDay[day, default: 0] += r.itemsSum
        }
        var running: Int64 = 0
        return perDay.keys.sorted().map { d in
            running += perDay[d] ?? 0
            return CumulativePoint(id: d, date: d, total: Money.double(running))
        }
    }
}

extension RReceipt {
    var purchaseList: [RPurchase] {
        (purchases as? Set<RPurchase> ?? []).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }
    /// Фотографии самого чека (без фото товаров).
    var photoList: [RPhoto] {
        (photos as? Set<RPhoto> ?? []).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }
    var itemsSum: Int64 { purchaseList.reduce(0) { $0 + $1.amountKop } }
    /// Пустая форма: ни фотографий, ни магазина, ни комментария, ни заполненных позиций.
    var isBlank: Bool {
        store.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rawText.isEmpty
            && photoList.isEmpty
            && purchaseList.allSatisfy { $0.isBlank }
    }
    var numberText: String { Fmt.number(number) }
    var storeText: String { store.isEmpty ? "—" : store }
    func touch() { updatedAt = Date() }
}

extension RPurchase {
    var sceneList: [RScene] {
        (scenes as? Set<RScene> ?? []).sorted {
            $0.code.localizedStandardCompare($1.code) == .orderedAscending
        }
    }
    var scenesText: String { sceneList.map { $0.code.isEmpty ? $0.title : $0.code }.joined(separator: ", ") }
    var itemPhotoList: [RPhoto] {
        (photos as? Set<RPhoto> ?? []).sorted { ($0.sortOrder, $0.createdAt ?? .distantPast) < ($1.sortOrder, $1.createdAt ?? .distantPast) }
    }
    var categoryName: String { category?.name ?? "—" }
    /// Пустая позиция: нет названия, суммы, назначения, фото, категории и сцен.
    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && amountKop == 0
            && purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && itemPhotoList.isEmpty
            && category == nil
            && sceneList.isEmpty
    }
}

extension RScene {
    var displayTitle: String {
        if code.isEmpty { return title.isEmpty ? "Сцена" : title }
        return title.isEmpty ? "Сцена \(code)" : "Сцена \(code) — \(title)"
    }
}

// MARK: - Операции

enum DataOps {
    static let defaultCategories = ["Реквизит", "Бытовая техника", "Мебель", "Одежда", "Продукты", "Канцелярия",
                                    "Расходные материалы", "Изготовление реквизита", "Транспорт", "Аренда", "Полиграфия", "Прочее"]

    static func ensureDefaultCategories(_ ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<RCategory>(entityName: "RCategory")
        req.fetchLimit = 1
        guard (try? ctx.count(for: req)) == 0 else { return }
        for (i, name) in defaultCategories.enumerated() {
            let c = RCategory(context: ctx)
            c.name = name
            c.sortOrder = Int32(i)
        }
    }

    @discardableResult
    static func createProject(_ ctx: NSManagedObjectContext, name: String, holder: String, issued: Int64, date: Date = Date()) -> RProject {
        ensureDefaultCategories(ctx)
        let p = RProject(context: ctx)
        p.name = name
        p.holder = holder
        p.startDate = date
        if issued > 0 { addAdvance(ctx, project: p, kind: 0, amount: issued, date: date, note: "Первоначальная выдача") }
        try? ctx.save()
        return p
    }

    @discardableResult
    static func addAdvance(_ ctx: NSManagedObjectContext, project: RProject, kind: Int16, amount: Int64, date: Date, note: String) -> RAdvance {
        let a = RAdvance(context: ctx)
        a.kind = kind
        a.amountKop = amount
        a.date = date
        a.note = note
        a.project = project
        return a
    }

    @discardableResult
    static func addItem(_ ctx: NSManagedObjectContext, to receipt: RReceipt, title: String = "", amount: Int64 = 0) -> RPurchase {
        let p = RPurchase(context: ctx)
        p.title = title
        p.amountKop = amount
        p.quantity = 1
        p.sortOrder = Int32((receipt.purchaseList.map { Int($0.sortOrder) }.max() ?? -1) + 1)
        p.receipt = receipt
        receipt.touch()
        return p
    }

    @discardableResult
    static func addPhoto(_ ctx: NSManagedObjectContext, data: Data, to receipt: RReceipt) -> RPhoto {
        let ph = RPhoto(context: ctx)
        ph.data = data
        ph.thumb = ImageTools.thumbnailJPEG(from: data)
        ph.fileExtension = ImageTools.fileExtension(for: data)
        ph.sortOrder = Int32((receipt.photoList.map { Int($0.sortOrder) }.max() ?? -1) + 1)
        ph.receipt = receipt
        receipt.touch()
        return ph
    }

    @discardableResult
    static func addItemPhoto(_ ctx: NSManagedObjectContext, data: Data, to purchase: RPurchase) -> RPhoto {
        let ph = RPhoto(context: ctx)
        ph.data = data
        ph.thumb = ImageTools.thumbnailJPEG(from: data)
        ph.fileExtension = ImageTools.fileExtension(for: data)
        ph.sortOrder = Int32((purchase.itemPhotoList.map { Int($0.sortOrder) }.max() ?? -1) + 1)
        ph.purchase = purchase
        purchase.receipt?.touch()
        return ph
    }

    /// Создаёт новый чек со следующим порядковым номером. Отдельного «подтверждения» нет: чек сразу обычная запись.
    @discardableResult
    static func createReceipt(_ ctx: NSManagedObjectContext, project: RProject, photos: [Data], noReceipt: Bool) -> RReceipt {
        let r = RReceipt(context: ctx)
        r.number = project.nextReceiptNumber
        r.project = project
        r.date = Date()
        r.noReceipt = noReceipt || photos.isEmpty
        r.isDraft = false
        for d in photos { addPhoto(ctx, data: d, to: r) }
        return r
    }

    /// ЕДИНЫЙ принцип нумерации: номера идут подряд 1…N без пропусков в порядке создания чеков.
    /// Порядок задают (текущий номер, время создания, uuid), поэтому дата, сортировка и группировка номера не меняют,
    /// а после удаления следующие чеки сдвигаются вверх. Изменения только вносятся в контекст; запись — одним `save()` вместе с остальным
    /// (атомарно: либо удаление и новые номера записаны вместе, либо ничего).
    @discardableResult
    static func normalizeNumbers(_ project: RProject) -> Bool {
        let live = (project.receipts as? Set<RReceipt> ?? []).filter { !$0.isDeleted }.sorted {
            if $0.number != $1.number { return $0.number < $1.number }
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            if a != b { return a < b }
            return ($0.uuid?.uuidString ?? "") < ($1.uuid?.uuidString ?? "")
        }
        var changed = false
        for (i, r) in live.enumerated() {
            let n = Int32(i + 1)
            if r.number != n { r.number = n; r.updatedAt = Date(); changed = true }
        }
        return changed
    }

    /// Ручная кнопка «Выровнять нумерацию»: закрывает пропуски и устраняет повторы, порядок создания сохраняется.
    static func renumber(_ ctx: NSManagedObjectContext, project: RProject) {
        normalizeNumbers(project)
        try? ctx.save()
    }

    /// Удаляет чеки (вместе с позициями, фото и результатами распознавания — каскадно) и сразу выравнивает номера оставшихся.
    /// Всё попадает в один шаг отмены; запись в базу делает вызывающий (`saveNow()`), поэтому перенумерация не опережает сохранение.
    static func deleteReceipts(_ ctx: NSManagedObjectContext, _ receipts: [RReceipt]) {
        var projects = [RProject]()
        for r in receipts where !r.isDeleted {
            if let p = r.project, !projects.contains(where: { $0 === p }) { projects.append(p) }
            ctx.delete(r)
        }
        for p in projects { normalizeNumbers(p) }
        ctx.processPendingChanges()
    }

    /// Удаляет позиции; если в чеке не осталось ни одной — удаляется и сам чек (с выравниванием номеров).
    static func deletePurchases(_ ctx: NSManagedObjectContext, _ purchases: [RPurchase]) {
        var receipts = [RReceipt]()
        for p in purchases {
            if let r = p.receipt, !receipts.contains(where: { $0 === r }) { receipts.append(r) }
            ctx.delete(p)
        }
        let empty = receipts.filter { r in !r.isDeleted && r.purchaseList.allSatisfy { $0.isDeleted } }
        deleteReceipts(ctx, empty)
        ctx.processPendingChanges()
    }

    static func delete(_ ctx: NSManagedObjectContext, _ objects: [NSManagedObject]) {
        for o in objects { ctx.delete(o) }
        try? ctx.save()
    }
}

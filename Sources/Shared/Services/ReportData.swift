import Foundation
import CoreData

/// Снимок данных проекта для отчёта (значения, не зависящие от Core Data — можно строить в фоне).
struct ReportSnapshot {
    struct Item {
        var title: String
        var category: String
        var scenes: String
        var amount: Int64
        var quantity: Double
        var purpose: String
    }
    struct Receipt {
        var number: Int
        var date: Date
        var store: String
        var inn: String
        var comment: String
        var noReceipt: Bool
        var items: [Item]
        var photos: [ImageTools.ReportImage]
        var total: Int64 { items.reduce(0) { $0 + $1.amount } }
    }
    var projectName: String
    var holder: String
    var periodText: String
    var issued: Int64
    var returned: Int64
    var spent: Int64
    var balance: Int64
    var purchaseCount: Int
    var receiptCount: Int
    var noReceiptCount: Int
    var generatedAt: Date
    var receipts: [Receipt]
    var categories: [(name: String, amount: Int64)]
    var advances: [(date: Date, kind: Int16, amount: Int64, note: String)]
}

enum ReportService {
    /// Собирает снимок в фоновом контексте. Фото сразу приводятся к JPEG разумного размера.
    static func makeSnapshot(container: NSPersistentContainer, projectID: NSManagedObjectID, from: Date?, to: Date?) async -> ReportSnapshot? {
        let ctx = container.newBackgroundContext()
        return await ctx.perform {
            guard let project = try? ctx.existingObject(with: projectID) as? RProject else { return nil }
            let totals = project.totals(from: from, to: to)
            let cal = Calendar.current
            func inRange(_ d: Date?) -> Bool {
                guard let d = d else { return true }
                if let from = from, d < cal.startOfDay(for: from) { return false }
                if let to = to, d >= cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))! { return false }
                return true
            }
            var receipts: [ReportSnapshot.Receipt] = []
            var catMap: [String: Int64] = [:]
            for r in project.confirmedReceipts where inRange(r.date) {
                let items = r.purchaseList.map { p -> ReportSnapshot.Item in
                    let cat = p.category?.name ?? "Без категории"
                    catMap[cat, default: 0] += p.amountKop
                    return ReportSnapshot.Item(title: p.title, category: cat, scenes: p.scenesText, amount: p.amountKop, quantity: p.quantity, purpose: p.purpose)
                }
                let photos = r.photoList.compactMap { ph in ph.data.flatMap { ImageTools.reportImage(from: $0) } }
                receipts.append(.init(number: Int(r.number), date: r.date ?? Date(), store: r.store, inn: r.inn, comment: r.comment,
                                      noReceipt: r.noReceipt, items: items, photos: photos))
            }
            var period = "за весь период"
            if from != nil || to != nil {
                period = "\(from.map { Fmt.date.string(from: $0) } ?? "…") — \(to.map { Fmt.date.string(from: $0) } ?? "…")"
            } else if let first = receipts.map({ $0.date }).min(), let last = receipts.map({ $0.date }).max() {
                period = "\(Fmt.date.string(from: first)) — \(Fmt.date.string(from: last))"
            }
            let advances = project.advanceList.filter { inRange($0.date) }.map { ($0.date ?? Date(), $0.kind, $0.amountKop, $0.note) }
            return ReportSnapshot(
                projectName: project.displayName, holder: project.holder, periodText: period,
                issued: totals.issued, returned: totals.returned, spent: totals.spent, balance: totals.balance,
                purchaseCount: totals.purchaseCount, receiptCount: totals.receiptCount, noReceiptCount: totals.noReceiptPurchases,
                generatedAt: Date(), receipts: receipts,
                categories: catMap.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }, advances: advances)
        }
    }
}

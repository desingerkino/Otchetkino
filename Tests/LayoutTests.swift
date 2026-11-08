import XCTest
import CoreData
@testable import Rekvizit

/// Чередование цветов строк таблицы расходов (Mac): сквозное через группы дат.
@MainActor
final class LayoutTests: XCTestCase {
    private func rows(_ counts: [Int], in ctx: NSManagedObjectContext, project: RProject) -> [DayGroup] {
        var groups: [DayGroup] = []
        var number = counts.reduce(0, +)
        for (g, c) in counts.enumerated() {
            let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6 - g, hour: 12))!
            var rs: [PurchaseRow] = []
            for _ in 0..<c {
                let r = DataOps.createReceipt(ctx, project: project, photos: [], noReceipt: true)
                let it = DataOps.addItem(ctx, to: r, title: "т\(number)", amount: 100)
                rs.append(PurchaseRow(id: it.objectID, receiptID: r.objectID, number: number, order: 0, date: day, title: "т", category: "", scenes: "",
                                      store: "", amount: 100, hasReceipt: false, isPlaceholder: false))
                number -= 1
            }
            groups.append(DayGroup(day: day, rows: rs))
        }
        return groups
    }

    func testZebraContinuesAcrossDateGroups() {
        let p = PersistenceController(inMemory: true)
        let proj = DataOps.createProject(p.viewContext, name: "Ф", holder: "М", issued: 1)
        let groups = rows([2, 3, 3], in: p.viewContext, project: proj)   // 6, 5, 4 ноября — как в задании
        let zebra = MacWorkspace.zebraIndex(groups)
        let flat = groups.flatMap { $0.rows }
        XCTAssertEqual(flat.map { zebra[$0.id] }, Array(0..<8), "заголовки дат не участвуют в счёте")
        // белая, серая, белая, серая… без сброса на новой дате
        XCTAssertEqual(flat.map { MacWorkspace.isEvenRow(zebra[$0.id]!) }, [false, true, false, true, false, true, false, true])
        // первая строка второй группы (третья в списке) — белая, не сбрасывается на «первую в группе»
        XCTAssertFalse(MacWorkspace.isEvenRow(zebra[groups[1].rows[0].id]!))
        // после третьей группы цвет продолжается: 6-я строка серая
        XCTAssertTrue(MacWorkspace.isEvenRow(zebra[groups[2].rows[0].id]!))
    }

    func testZebraRecalculatesAfterRowRemoval() {
        let p = PersistenceController(inMemory: true)
        let proj = DataOps.createProject(p.viewContext, name: "Ф", holder: "М", issued: 1)
        var groups = rows([2, 2], in: p.viewContext, project: proj)
        groups[0] = DayGroup(day: groups[0].day, rows: [groups[0].rows[0]])   // удалили одну строку
        let zebra = MacWorkspace.zebraIndex(groups)
        XCTAssertEqual(groups.flatMap { $0.rows }.map { zebra[$0.id] }, [0, 1, 2])
        XCTAssertEqual(zebra[groups[1].rows[0].id], 1)
    }
}

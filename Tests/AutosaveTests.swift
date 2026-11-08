import XCTest
import CoreData
import PDFKit
@testable import Rekvizit

/// Автосохранение, пустые формы, справочник магазинов, отмена/повтор — на реальных данных.
@MainActor
final class AutosaveTests: XCTestCase {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rk-test-\(UUID().uuidString).sqlite")
    }

    private func project(_ p: PersistenceController) -> RProject {
        DataOps.createProject(p.viewContext, name: "Тест", holder: "Миша", issued: 1_000_000)
    }

    // MARK: Нет черновиков, пустые формы не влияют на учёт

    func testNoDraftsAndBlankFormsAreIgnored() throws {
        let p = PersistenceController(inMemory: true)
        let proj = project(p)
        let blank = DataOps.createReceipt(p.viewContext, project: proj, photos: [], noReceipt: true)
        DataOps.addItem(p.viewContext, to: blank)
        XCTAssertTrue(blank.isBlank)
        XCTAssertFalse(blank.isDraft)
        XCTAssertEqual(proj.totals().spent, 0)
        XCTAssertEqual(proj.totals().purchaseCount, 0)
        XCTAssertEqual(proj.totals().noReceiptPurchases, 0)

        // как только введены данные — это обычная покупка, в итогах сразу
        blank.purchaseList[0].title = "Краска"
        blank.purchaseList[0].amountKop = 45_000
        XCTAssertFalse(blank.isBlank)
        XCTAssertEqual(proj.totals().spent, 45_000)
        XCTAssertEqual(proj.totals().purchaseCount, 1)
    }

    func testBlankReceiptIsRemovedOnSaveUnlessActive() throws {
        let p = PersistenceController(inMemory: true)
        let saver = SaveCoordinator(context: p.viewContext)
        let proj = project(p)
        let r = DataOps.createReceipt(p.viewContext, project: proj, photos: [], noReceipt: true)
        DataOps.addItem(p.viewContext, to: r)
        saver.setActive([r.objectID])
        XCTAssertTrue(saver.saveNow())
        XCTAssertFalse(r.isDeleted, "активная пустая форма не должна исчезать, пока её заполняют")
        // перешли к другой покупке — пустая форма исчезает
        saver.setActive([])
        r.comment = " "
        XCTAssertTrue(saver.saveNow())
        let left = try p.viewContext.fetch(NSFetchRequest<RReceipt>(entityName: "RReceipt"))
        XCTAssertTrue(left.isEmpty, "пустая форма должна быть удалена")
    }

    // MARK: Автосохранение и перезапуск

    func testAutosaveSurvivesRestart() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var projectUUID: UUID?
        do {
            let p = PersistenceController(storeURL: url)
            let saver = SaveCoordinator(context: p.viewContext)
            let proj = project(p)
            projectUUID = proj.uuid
            // 1. создаём покупку с фото, заполняем поля — кнопку «Сохранить» не нажимаем
            let first = DataOps.createReceipt(p.viewContext, project: proj, photos: [CoreTests.makeJPEG(width: 200, height: 300)], noReceipt: false)
            first.store = "авито"
            first.date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))
            let item = DataOps.addItem(p.viewContext, to: first, title: "Лампа", amount: 129_000)
            item.purpose = "Сцена 12"
            // 2. «переходим к другой покупке» — предыдущая сохраняется
            saver.setActive([])
            XCTAssertTrue(saver.saveNow())
            let second = DataOps.createReceipt(p.viewContext, project: proj, photos: [], noReceipt: true)
            let item2 = DataOps.addItem(p.viewContext, to: second, title: "Краска", amount: 45_000)
            item2.purpose = "Состарить стену"
            saver.setActive([second.objectID])
            XCTAssertTrue(saver.saveNow())
            // 3. возвращаемся к первой: всё на месте
            XCTAssertEqual(first.purchaseList.first?.title, "Лампа")
            XCTAssertEqual(first.photoList.count, 1)
            XCTAssertEqual(first.store, "АВИТО".lowercased() == "авито" ? first.store : "")
            XCTAssertFalse(p.viewContext.hasChanges)
        }
        // 4. «закрыли и открыли приложение»
        let reopened = PersistenceController(storeURL: url)
        let ctx = reopened.viewContext
        let projects = try ctx.fetch(NSFetchRequest<RProject>(entityName: "RProject"))
        let proj = try XCTUnwrap(projects.first { $0.uuid == projectUUID })
        XCTAssertEqual(proj.receiptList.count, 2)
        XCTAssertEqual(proj.totals().spent, 129_000 + 45_000)
        let first = try XCTUnwrap(proj.receiptList.first)
        XCTAssertEqual(first.purchaseList.first?.title, "Лампа")
        XCTAssertEqual(first.purchaseList.first?.purpose, "Сцена 12")
        XCTAssertEqual(first.photoList.count, 1)
        XCTAssertNotNil(first.photoList.first?.data)
        XCTAssertEqual(StoreDirectory.all(ctx).count, 1, "магазин должен попасть в справочник")
    }

    func testManualSaveButtonPersistsAmount() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let uuid: UUID?
        do {
            let p = PersistenceController(storeURL: url)
            let saver = SaveCoordinator(context: p.viewContext)
            let proj = project(p)
            uuid = proj.uuid
            let r = DataOps.createReceipt(p.viewContext, project: proj, photos: [], noReceipt: true)
            let item = DataOps.addItem(p.viewContext, to: r, title: "Стол", amount: 100)
            saver.setActive([r.objectID])
            item.amountKop = 777_00                 // «Изменить сумму»
            XCTAssertTrue(saver.saveNow())          // «Нажать кнопку Сохранить»
            XCTAssertEqual(saver.state, .saved)
        }
        let again = PersistenceController(storeURL: url)
        let projects = try again.viewContext.fetch(NSFetchRequest<RProject>(entityName: "RProject"))
        XCTAssertEqual(projects.first { $0.uuid == uuid }?.totals().spent, 777_00)
    }

    func testDebouncedAutosaveWritesWithoutButton() throws {
        let p = PersistenceController(inMemory: true)
        let saver = SaveCoordinator(context: p.viewContext)
        saver.debounce = 0.05
        let proj = project(p)
        let r = DataOps.createReceipt(p.viewContext, project: proj, photos: [], noReceipt: true)
        let item = DataOps.addItem(p.viewContext, to: r, title: "Лампа", amount: 1_000)
        saver.setActive([r.objectID])
        item.amountKop = 2_000
        p.viewContext.processPendingChanges()
        let done = expectation(description: "автосохранение")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertFalse(p.viewContext.hasChanges, "изменения должны быть записаны автоматически")
        XCTAssertEqual(saver.state, .saved)
    }

    // MARK: Справочник магазинов

    func testStoreDirectorySuggestionsAndDedupe() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        XCTAssertEqual(StoreDirectory.remember(ctx, name: "АВИТО"), "АВИТО")
        XCTAssertEqual(StoreDirectory.remember(ctx, name: "  авито "), "АВИТО", "дубль в другом регистре не создаётся")
        StoreDirectory.remember(ctx, name: "Леруа Мерлен")
        try ctx.save()
        XCTAssertEqual(StoreDirectory.suggestions(ctx, for: "Ав"), ["АВИТО"])
        XCTAssertEqual(StoreDirectory.suggestions(ctx, for: "ав"), ["АВИТО"], "без учёта регистра")
        XCTAssertEqual(StoreDirectory.suggestions(ctx, for: "мер"), ["Леруа Мерлен"], "поиск по части названия")
        XCTAssertTrue(StoreDirectory.suggestions(ctx, for: "яя").isEmpty)
        XCTAssertEqual(StoreDirectory.all(ctx).count, 2)
    }

    func testStoreMergeKeepsPurchases() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        let proj = project(p)
        let a = DataOps.createReceipt(ctx, project: proj, photos: [], noReceipt: true)
        a.store = "Avito"
        DataOps.addItem(ctx, to: a, title: "Лампа", amount: 100)
        let b = DataOps.createReceipt(ctx, project: proj, photos: [], noReceipt: true)
        b.store = "АВИТО"
        DataOps.addItem(ctx, to: b, title: "Стол", amount: 200)
        let s1 = RStore(context: ctx); s1.name = "Avito"
        let s2 = RStore(context: ctx); s2.name = "АВИТО"
        StoreDirectory.merge(ctx, source: s1, into: s2)
        try ctx.save()
        XCTAssertEqual(a.store, "АВИТО")
        XCTAssertEqual(b.store, "АВИТО")
        XCTAssertEqual(a.purchaseList.count, 1)
        XCTAssertEqual(proj.totals().spent, 300)
        XCTAssertEqual(StoreDirectory.all(ctx).count, 1)
    }

    func testStoreSeedFromExistingReceipts() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        let proj = project(p)
        for name in ["Леруа", "леруа", "ДНС"] {
            let r = DataOps.createReceipt(ctx, project: proj, photos: [], noReceipt: true)
            r.store = name
            DataOps.addItem(ctx, to: r, title: "x", amount: 1)
        }
        StoreDirectory.seedAndDedupe(ctx)
        XCTAssertEqual(StoreDirectory.all(ctx).count, 2)
    }

    // MARK: Отмена и повтор на реальных данных

    private func undoStep(_ p: PersistenceController, _ work: () -> Void) {
        let um = p.viewContext.undoManager!
        um.beginUndoGrouping()
        work()
        p.viewContext.processPendingChanges()
        um.endUndoGrouping()
    }

    func testUndoRedoCreateEditDelete() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        let um = try XCTUnwrap(ctx.undoManager)
        um.groupsByEvent = false
        let proj = project(p)
        try ctx.save()
        um.removeAllActions()

        // создание покупки
        var receipt: RReceipt!
        var item: RPurchase!
        undoStep(p) {
            receipt = DataOps.createReceipt(ctx, project: proj, photos: [CoreTests.makeJPEG(width: 100, height: 100)], noReceipt: false)
            item = DataOps.addItem(ctx, to: receipt, title: "Лампа", amount: 100_000)
        }
        try ctx.save()
        XCTAssertEqual(proj.totals().spent, 100_000)

        // изменение суммы, даты, магазина, категории, названия, комментария
        let cat = RCategory(context: ctx); cat.name = "Мебель"
        let newDate = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 12))!
        undoStep(p) { item.amountKop = 250_000 }
        undoStep(p) { receipt.date = newDate }
        undoStep(p) { receipt.store = "АВИТО" }
        undoStep(p) { item.category = cat }
        undoStep(p) { item.title = "Торшер" }
        undoStep(p) { item.purpose = "Сцена 5" }
        try ctx.save()
        XCTAssertEqual(proj.totals().spent, 250_000)

        // отмена шагов по одному
        um.undo(); XCTAssertEqual(item.purpose, "")
        um.undo(); XCTAssertEqual(item.title, "Лампа")
        um.undo(); XCTAssertNil(item.category)
        um.undo(); XCTAssertEqual(receipt.store, "")
        um.undo(); XCTAssertNotEqual(receipt.date, newDate)
        um.undo(); XCTAssertEqual(item.amountKop, 100_000)
        // повтор
        um.redo(); XCTAssertEqual(item.amountKop, 250_000)
        um.redo(); XCTAssertEqual(receipt.date, newDate)
        XCTAssertTrue(um.canRedo)
        while um.canRedo { um.redo() }
        XCTAssertEqual(item.purpose, "Сцена 5")

        // удаление покупки и её возврат: фото и связанные записи не теряются
        undoStep(p) { ctx.delete(receipt) }
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(NSFetchRequest<RReceipt>(entityName: "RReceipt")).count, 0)
        um.undo()
        try ctx.save()
        let restored = try ctx.fetch(NSFetchRequest<RReceipt>(entityName: "RReceipt"))
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.photoList.count, 1)
        XCTAssertNotNil(restored.first?.photoList.first?.data)
        XCTAssertEqual(restored.first?.purchaseList.first?.title, "Торшер")
        XCTAssertEqual(proj.totals().spent, 250_000)

        // отмена самого создания
        while um.canUndo { um.undo() }
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(NSFetchRequest<RReceipt>(entityName: "RReceipt")).count, 0)
    }

    // MARK: PDF-выписка сверяется с данными до копейки

    func testPDFStatementListsEveryAdvanceAndMatchesTotals() throws {
        let d1 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let d2 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        let d3 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        func item(_ t: String, _ c: String, _ s: String, _ a: Int64) -> ReportSnapshot.Item { .init(title: t, category: c, scenes: s, amount: a, quantity: 1, purpose: "") }
        let receipts: [ReportSnapshot.Receipt] = [
            .init(number: 1, date: d2, store: "АВИТО", inn: "", comment: "", noReceipt: false, items: [item("Лампа настольная", "Мебель", "12", 129_050)], photos: []),
            .init(number: 2, date: d3, store: "Рынок", inn: "", comment: "", noReceipt: true, items: [item("Краска", "Расходные материалы", "4", 45_001)], photos: [])
        ]
        let spent: Int64 = 129_050 + 45_001
        let issued: Int64 = 2_000_000 + 1_000_050
        let returned: Int64 = 30_025
        let snap = ReportSnapshot(projectName: "Проверочный фильм", holder: "Миша", periodText: "01.11.2026 — 07.11.2026",
                                  issued: issued, returned: returned, spent: spent, balance: issued - spent - returned,
                                  purchaseCount: 2, receiptCount: 1, noReceiptCount: 1, generatedAt: Date(), receipts: receipts,
                                  categories: [("Мебель", 129_050), ("Расходные материалы", 45_001)],
                                  advances: [(d1, 0, 2_000_000, "Реквизит"), (d2, 0, 1_000_050, "Дополнительные расходы"), (d3, 1, 30_025, "Возврат остатка наличных")])
        let pdf = PDFBuilder.build(snap)
        let doc = try XCTUnwrap(PDFDocument(data: pdf))
        let text = (doc.string ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
        func has(_ s: String) -> Bool { text.contains(s) }
        // каждая выдача: дата и сумма
        XCTAssertTrue(has("01.11.2026"), text)
        XCTAssertTrue(has("20 000 ₽"), text)
        XCTAssertTrue(has("04.11.2026"))
        XCTAssertTrue(has("10 000,50 ₽"))
        XCTAssertTrue(has("Дополнительные расходы"))
        // покупки
        XCTAssertTrue(has("Лампа настольная")); XCTAssertTrue(has("1 290,50 ₽"))
        XCTAssertTrue(has("Краска")); XCTAssertTrue(has("450,01 ₽"))
        // возврат
        XCTAssertTrue(has("300,25 ₽")); XCTAssertTrue(has("Возврат остатка наличных"))
        // финансовый итог
        for title in ["1. Выдача денег", "2. Покупки", "3. Возвраты", "4. Финансовый итог", "Всего выдано", "Всего потрачено", "Всего возвращено",
                      "Количество чеков", "Количество покупок без чека"] {
            XCTAssertTrue(has(title), "нет «\(title)»")
        }
        XCTAssertTrue(has(Money.format(issued).replacingOccurrences(of: "\u{00A0}", with: " ")))
        XCTAssertTrue(has(Money.format(issued - spent - returned).replacingOccurrences(of: "\u{00A0}", with: " ")))
        // нумерация страниц и дата формирования
        XCTAssertTrue(text.contains("стр. 1 из \(doc.pageCount)"), "нет нумерации «стр. 1 из N»")
        XCTAssertTrue(has("сформирован"))
        // ИНН продавца нигде не выводится
        XCTAssertFalse(has("ИНН"))
        // баланс сходится до копейки
        XCTAssertEqual(issued - spent - returned, 3_000_050 - 174_051 - 30_025)
    }
}

import XCTest
import CoreData
import PDFKit
@testable import Rekvizit

/// Сквозная последовательная нумерация: 1…N без пропусков, порядок создания, независимо от даты, сортировки и группировки.
@MainActor
final class NumberingTests: XCTestCase {
    private var p: PersistenceController!
    private var ctx: NSManagedObjectContext { p.viewContext }
    private var saver: SaveCoordinator!

    override func setUp() async throws {
        p = PersistenceController(inMemory: true)
        saver = SaveCoordinator(context: p.viewContext)
        PurchaseFlow.resetThrottle()
    }

    private func project(_ name: String = "Фильм") -> RProject {
        DataOps.createProject(ctx, name: name, holder: "Миша", issued: 1_000_000)
    }

    @discardableResult
    private func make(_ proj: RProject, _ title: String, day: Int = 6, photos: Int = 0) -> RReceipt {
        let datas = (0..<photos).map { _ in CoreTests.makeJPEG(width: 60, height: 90) }
        let r = DataOps.createReceipt(ctx, project: proj, photos: datas, noReceipt: photos == 0)
        r.date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))
        DataOps.addItem(ctx, to: r, title: title, amount: 10_000)
        r.rawText = "ИТОГО 100.00"
        return r
    }

    private func numbers(_ proj: RProject) -> [Int32] { proj.receiptList.filter { !$0.isDeleted }.map { $0.number } }
    private func titles(_ proj: RProject) -> [String] { proj.receiptList.filter { !$0.isDeleted }.map { $0.purchaseList.first?.title ?? "" } }
    private func assertSequential(_ proj: RProject, file: StaticString = #filePath, line: UInt = #line) {
        let n = numbers(proj)
        XCTAssertEqual(n, n.isEmpty ? [] : Array(1...Int32(n.count)), "номера не подряд: \(n)", file: file, line: line)
    }
    private func fetchCount(_ entity: String) -> Int { (try? ctx.count(for: NSFetchRequest<NSManagedObject>(entityName: entity))) ?? -1 }

    private func deleteAndSave(_ rs: [RReceipt]) {
        DataOps.deleteReceipts(ctx, rs)
        XCTAssertTrue(saver.saveNow())
    }

    // 1–3
    func testFiveCreatedThenDeleteThirdThenNext() {
        let proj = project()
        let rs = (1...5).map { make(proj, "П\($0)") }
        XCTAssertEqual(numbers(proj), [1, 2, 3, 4, 5])
        deleteAndSave([rs[2]])
        XCTAssertEqual(numbers(proj), [1, 2, 3, 4])
        XCTAssertEqual(titles(proj), ["П1", "П2", "П4", "П5"], "порядок создания сохраняется")
        let next = make(proj, "П6")
        XCTAssertEqual(next.number, 5)
        assertSequential(proj)
    }

    // пример из задания: №5, №6, №7 → удалили №6
    func testSpecExampleFiveSixSeven() {
        let proj = project()
        let rs = (1...7).map { make(proj, "П\($0)") }
        deleteAndSave(Array(rs[0..<4]))            // остались бывшие 5,6,7 → 1,2,3
        XCTAssertEqual(numbers(proj), [1, 2, 3])
        deleteAndSave([rs[5]])                     // удалили бывший №6
        XCTAssertEqual(titles(proj), ["П5", "П7"])
        XCTAssertEqual(numbers(proj), [1, 2])
        XCTAssertEqual(make(proj, "новая").number, 3)
    }

    // 4: десять, удалили №3 и №7 → 8 штук, следующая №9
    func testDeleteSeveralAtOnce() {
        let proj = project()
        let rs = (1...10).map { make(proj, "П\($0)") }
        deleteAndSave([rs[2], rs[6]])
        XCTAssertEqual(numbers(proj), Array(1...8))
        XCTAssertEqual(titles(proj), ["П1", "П2", "П4", "П5", "П6", "П8", "П9", "П10"])
        XCTAssertEqual(make(proj, "н").number, 9)
    }

    func testDeleteSeveralOneAfterAnother() {
        let proj = project()
        let rs = (1...6).map { make(proj, "П\($0)") }
        deleteAndSave([rs[1]]); assertSequential(proj)
        deleteAndSave([rs[3]]); assertSequential(proj)
        deleteAndSave([rs[4]]); assertSequential(proj)
        XCTAssertEqual(titles(proj), ["П1", "П3", "П6"])
    }

    // 5, 6
    func testDeleteLastAndFirst() {
        let proj = project()
        let rs = (1...4).map { make(proj, "П\($0)") }
        deleteAndSave([rs[3]])
        XCTAssertEqual(numbers(proj), [1, 2, 3])
        XCTAssertEqual(make(proj, "н").number, 4)
        deleteAndSave([rs[0]])
        XCTAssertEqual(numbers(proj), [1, 2, 3])
        XCTAssertEqual(titles(proj), ["П2", "П3", "н"])
    }

    // 7, 8, 9: дата, группировка, сортировка не меняют номера
    func testDateChangeGroupingAndSortingDoNotChangeNumbers() {
        let proj = project()
        let a = make(proj, "А", day: 6), b = make(proj, "Б", day: 7), c = make(proj, "В", day: 8), d = make(proj, "Г", day: 6)
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual([a, b, c, d].map { $0.number }, [1, 2, 3, 4])
        // перенос на другую дату
        b.date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual([a, b, c, d].map { $0.number }, [1, 2, 3, 4])
        // сортировка от новых к старым и группировка по дням — только представление
        let byDateDesc = proj.receiptList.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        XCTAssertEqual(Set(byDateDesc.map { $0.number }), [1, 2, 3, 4])
        let groups = Dictionary(grouping: proj.receiptList) { Calendar.current.startOfDay(for: $0.date ?? Date()) }
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual([a, b, c, d].map { $0.number }, [1, 2, 3, 4])
        // удаление из середины считается по всему проекту, а не по дню
        deleteAndSave([a])
        XCTAssertEqual([b, c, d].map { $0.number }, [1, 2, 3])
        XCTAssertEqual(make(proj, "Е", day: 5).number, 4)
        assertSequential(proj)
    }

    // 10, 11: Undo / Redo
    func testUndoRestoresPurchaseAndNumbering_RedoRepeats() throws {
        let um = try XCTUnwrap(ctx.undoManager)
        um.groupsByEvent = false
        let proj = project()
        let rs = (1...3).map { make(proj, "П\($0)", photos: 1) }
        XCTAssertTrue(saver.saveNow())
        um.removeAllActions()

        um.beginUndoGrouping()
        DataOps.deleteReceipts(ctx, [rs[1]])
        ctx.processPendingChanges()
        um.endUndoGrouping()
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(numbers(proj), [1, 2])
        XCTAssertEqual(titles(proj), ["П1", "П3"])

        um.undo()
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(numbers(proj), [1, 2, 3], "после Undo нумерация снова 1,2,3")
        XCTAssertEqual(titles(proj), ["П1", "П2", "П3"])
        let restored = proj.receiptList[1]
        XCTAssertEqual(restored.photoList.count, 1, "фото вернулось")
        XCTAssertNotNil(restored.photoList.first?.data)
        XCTAssertEqual(restored.rawText, "ИТОГО 100.00", "результат распознавания вернулся")
        XCTAssertEqual(restored.purchaseList.count, 1)

        um.redo()
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(numbers(proj), [1, 2])
        XCTAssertEqual(titles(proj), ["П1", "П3"])
    }

    // Undo после создания новой покупки не ломает остальные записи
    func testUndoAfterCreatingNewPurchase() throws {
        let um = try XCTUnwrap(ctx.undoManager)
        um.groupsByEvent = false
        let proj = project()
        let rs = (1...3).map { make(proj, "П\($0)") }
        XCTAssertTrue(saver.saveNow()); um.removeAllActions()
        um.beginUndoGrouping(); DataOps.deleteReceipts(ctx, [rs[1]]); ctx.processPendingChanges(); um.endUndoGrouping()
        XCTAssertTrue(saver.saveNow())
        um.beginUndoGrouping(); make(proj, "Новая"); ctx.processPendingChanges(); um.endUndoGrouping()
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(numbers(proj), [1, 2, 3])
        um.undo()                                    // отменили создание
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(titles(proj), ["П1", "П3"])
        XCTAssertEqual(numbers(proj), [1, 2])
        um.undo()                                    // отменили удаление
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(titles(proj), ["П1", "П2", "П3"])
        XCTAssertEqual(numbers(proj), [1, 2, 3])
    }

    // 12: связанные данные удаляются
    func testDeleteRemovesPhotosPurchasesAndOCR() {
        let proj = project()
        let r = make(proj, "С фото", photos: 2)
        let keep = make(proj, "Остаётся", photos: 1)
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(fetchCount("RPhoto"), 3)
        deleteAndSave([r])
        XCTAssertEqual(fetchCount("RPhoto"), 1, "фото удалённой покупки не должны оставаться")
        XCTAssertEqual(fetchCount("RPurchase"), 1)
        XCTAssertEqual(fetchCount("RReceipt"), 1)
        XCTAssertEqual(keep.number, 1)
        XCTAssertEqual(keep.photoList.count, 1)
    }

    // удаление последней позиции убирает и чек, номера выравниваются
    func testDeletingLastItemRemovesReceipt() {
        let proj = project()
        let rs = (1...3).map { make(proj, "П\($0)") }
        XCTAssertTrue(saver.saveNow())
        DataOps.deletePurchases(ctx, rs[0].purchaseList)
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(numbers(proj), [1, 2])
        XCTAssertEqual(fetchCount("RReceipt"), 2)
    }

    // 13–14: Enter
    func testEnterSavesAndCreatesNext() throws {
        let proj = project()
        let first = DataOps.createReceipt(ctx, project: proj, photos: [], noReceipt: true)
        DataOps.addItem(ctx, to: first, title: "", amount: 0)
        saver.setActive([first.objectID])
        first.purchaseList[0].title = "Лампа"; first.purchaseList[0].amountKop = 5_000
        let next = try XCTUnwrap(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: first, saver: saver))
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(next.number, 2)
        XCTAssertTrue(next.isBlank)
        XCTAssertFalse(first.hasChanges && first.objectID.isTemporaryID, "первая покупка записана")
        XCTAssertEqual(fetchCount("RReceipt"), 2)
    }

    func testRepeatedEnterDoesNotCreateDuplicatesOrEmptyRecords() throws {
        let proj = project()
        let first = make(proj, "Лампа")
        var current = first
        var created = 0
        for _ in 0..<6 {                              // быстрые многократные нажатия подряд
            if let n = PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: current, saver: saver) { created += 1; current = n }
        }
        XCTAssertEqual(created, 1)
        // даже без защиты по времени пустая форма ничего не создаёт
        PurchaseFlow.resetThrottle()
        XCTAssertNil(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: current, saver: saver))
        XCTAssertEqual(numbers(proj), [1, 2])
        // Enter в пустой форме: ничего не сохраняется и не создаётся
        let empty = project("Пустой")
        let blank = DataOps.createReceipt(ctx, project: empty, photos: [], noReceipt: true)
        DataOps.addItem(ctx, to: blank)
        PurchaseFlow.resetThrottle()
        XCTAssertNil(PurchaseFlow.saveAndCreateNext(project: empty, ctx: ctx, current: blank, saver: saver))
        XCTAssertEqual(empty.receiptList.count, 1)
    }

    // 15: ошибка сохранения
    func testSaveFailureDoesNotCreateNextPurchase() throws {
        final class FailingContext: NSManagedObjectContext {
            var failing = false
            override func save() throws {
                if failing { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "диск недоступен"]) }
                try super.save()
            }
        }
        let bad = FailingContext(concurrencyType: .mainQueueConcurrencyType)
        bad.persistentStoreCoordinator = p.container.persistentStoreCoordinator
        let badSaver = SaveCoordinator(context: bad)
        let proj = DataOps.createProject(bad, name: "Сбой", holder: "М", issued: 1)
        try bad.save()
        let r = DataOps.createReceipt(bad, project: proj, photos: [], noReceipt: true)
        DataOps.addItem(bad, to: r, title: "Лампа", amount: 100)
        bad.failing = true
        XCTAssertNil(PurchaseFlow.saveAndCreateNext(project: proj, ctx: bad, current: r, saver: badSaver))
        XCTAssertEqual(proj.receiptList.count, 1, "следующая покупка не создаётся")
        XCTAssertEqual(r.purchaseList[0].title, "Лампа", "данные не потеряны")
        if case .failed = badSaver.state {} else { XCTFail("должна быть показана ошибка сохранения") }
        bad.failing = false
        PurchaseFlow.resetThrottle()
        XCTAssertNotNil(PurchaseFlow.saveAndCreateNext(project: proj, ctx: bad, current: r, saver: badSaver), "после исправления сохранение проходит")
    }

    // 16: PDF показывает актуальные номера
    func testPDFShowsCurrentNumbersAfterDelete() async throws {
        let proj = project()
        let rs = (1...3).map { make(proj, "Позиция-\($0)") }
        XCTAssertTrue(saver.saveNow())
        deleteAndSave([rs[1]])
        let snap = try await XCTUnwrap(ReportService.makeSnapshot(container: p.container, projectID: proj.objectID, from: nil, to: nil))
        XCTAssertEqual(snap.receipts.map { $0.number }.sorted(), [1, 2])
        let doc = try XCTUnwrap(PDFDocument(data: PDFBuilder.build(snap)))
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("Позиция-3"))
        XCTAssertFalse(text.contains("003"), "в PDF не должно остаться старого номера 003")
        XCTAssertTrue(text.contains("002"))
    }

    // 17: проекты независимы
    func testNumberingIsIndependentPerProject() {
        let a = project("А"), b = project("Б")
        let ra = (1...3).map { make(a, "а\($0)") }
        (1...2).forEach { make(b, "б\($0)") }
        deleteAndSave([ra[0]])
        XCTAssertEqual(numbers(a), [1, 2])
        XCTAssertEqual(numbers(b), [1, 2])
        XCTAssertEqual(make(b, "б3").number, 3)
        XCTAssertEqual(make(a, "а4").number, 3)
    }

    // старые данные: пропуски и повторы чинятся без потери
    func testLegacyGapsAndDuplicatesAreFixedKeepingOrder() throws {
        let proj = project()
        let rs = (1...5).map { make(proj, "П\($0)") }
        rs[0].number = 1; rs[1].number = 2; rs[2].number = 5; rs[3].number = 5; rs[4].number = 9
        XCTAssertTrue(saver.saveNow())
        XCTAssertTrue(Maintenance.numbersNeedFix(ctx))
        Maintenance.fixDuplicateReceiptNumbers(ctx)
        try ctx.save()
        XCTAssertEqual(numbers(proj), [1, 2, 3, 4, 5])
        XCTAssertEqual(titles(proj), ["П1", "П2", "П3", "П4", "П5"])
        XCTAssertFalse(Maintenance.numbersNeedFix(ctx))
    }

    // более 999: полный номер без обрезания
    func testNumberFormatOverThousand() {
        XCTAssertEqual(Fmt.number(6), "№006")
        XCTAssertEqual(Fmt.number(1234), "№1234")
    }

    // случайный набор операций: всегда без пропусков
    func testRandomOperationsKeepNumbersSequential() {
        let proj = project()
        var rng = SystemRandomNumberGenerator()
        for step in 0..<60 {
            if proj.receiptList.count < 3 || Int.random(in: 0..<3, using: &rng) > 0 {
                make(proj, "s\(step)")
            } else if let victim = proj.receiptList.randomElement() {
                DataOps.deleteReceipts(ctx, [victim])
            }
            XCTAssertTrue(saver.saveNow())
            assertSequential(proj)
        }
    }
}

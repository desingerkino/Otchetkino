import XCTest
import SwiftUI
import AppKit
import CoreData
@testable import Rekvizit

/// Спокойная палитра и переход к новой позиции по Enter.
@MainActor
final class ComfortAndFlowTests: XCTestCase {
    private func hex(_ c: Color) -> String {
        var out = ""
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(c).usingColorSpace(.sRGB)!
            out = String(format: "#%02X%02X%02X", Int(round(ns.redComponent * 255)), Int(round(ns.greenComponent * 255)), Int(round(ns.blueComponent * 255)))
        }
        return out
    }
    private func luminance(_ c: Color) -> CGFloat {
        var l: CGFloat = 0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(c).usingColorSpace(.sRGB)!
            l = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        }
        return l
    }

    func testMutedPalette() {
        XCTAssertEqual(hex(.rkRowOdd), "#E9EAED")
        XCTAssertEqual(hex(.rkRowEven), "#D9DCE1")
        XCTAssertEqual(hex(.rkBackground), "#F0F1F3")
        XCTAssertEqual(hex(.rkCard), "#F3F4F6")
        XCTAssertLessThan(luminance(.rkField), luminance(.rkCard), "поля ввода темнее карточек")
        for c in [Color.rkBackground, .rkCard, .rkRowOdd, .rkRowEven, .rkField] {
            XCTAssertNotEqual(hex(c), "#FFFFFF", "чистого белого в интерфейсе быть не должно")
        }
        XCTAssertGreaterThan(luminance(.rkRowOdd) - luminance(.rkRowEven), 0.03, "оттенки строк заметно различимы")
        XCTAssertLessThan(luminance(.rkRowOdd) - luminance(.rkRowEven), 0.12, "но не слишком контрастны")
    }

    // Корень ошибки перехода: у новой записи идентификатор был временным и менялся при сохранении — выбор и панель теряли её
    func testNewPurchaseKeepsStableIdentityAcrossSave() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        let saver = SaveCoordinator(context: ctx)
        let proj = DataOps.createProject(ctx, name: "Ф", holder: "М", issued: 1)
        let r = AddFlow.createManual(project: proj, ctx: ctx)
        let item = try XCTUnwrap(r.purchaseList.first)
        XCTAssertFalse(r.objectID.isTemporaryID)
        XCTAssertFalse(item.objectID.isTemporaryID)
        let (rid, iid) = (r.objectID, item.objectID)
        saver.setActive([rid])
        item.title = "Сумка"; item.amountKop = 67_200
        XCTAssertTrue(saver.saveNow())
        XCTAssertEqual(r.objectID, rid, "идентификатор не изменился после сохранения")
        XCTAssertNotNil(try ctx.existingObject(with: rid) as? RReceipt, "панель находит новую покупку по сохранённому идентификатору")
        XCTAssertNotNil(try ctx.existingObject(with: iid) as? RPurchase, "строка таблицы находит позицию")
    }

    func testEnterFlowSelectsNewItemAndKeepsPreviousInList() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        let saver = SaveCoordinator(context: ctx)
        PurchaseFlow.resetThrottle()
        let proj = DataOps.createProject(ctx, name: "Ф", holder: "М", issued: 1)
        let first = AddFlow.createManual(project: proj, ctx: ctx)
        saver.setActive([first.objectID])
        first.purchaseList[0].title = "Сумка санитарная СССР"; first.purchaseList[0].amountKop = 67_200
        let next = try XCTUnwrap(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: first, saver: saver))
        // предыдущая сохранена и осталась; новая — пустая, следующая по номеру, с постоянным идентификатором
        XCTAssertEqual(first.purchaseList[0].title, "Сумка санитарная СССР")
        XCTAssertFalse(first.hasChanges)
        XCTAssertEqual(next.number, first.number + 1)
        XCTAssertTrue(next.isBlank)
        XCTAssertFalse(next.objectID.isTemporaryID)
        XCTAssertFalse(try XCTUnwrap(next.purchaseList.first).objectID.isTemporaryID)
        // быстрый ввод нескольких позиций подряд
        var current = next
        for i in 2...5 {
            current.purchaseList[0].title = "Позиция \(i)"; current.purchaseList[0].amountKop = Int64(i) * 100
            PurchaseFlow.resetThrottle()
            current = try XCTUnwrap(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: current, saver: saver))
        }
        XCTAssertEqual(proj.receiptList.filter { !$0.isBlank }.count, 5)
        XCTAssertEqual(proj.receiptList.map { $0.number }, [1, 2, 3, 4, 5, 6])
        XCTAssertNil(PurchaseFlow.lastError)
    }

    func testSaveFailureReportsReasonAndKeepsCurrentActive() throws {
        final class FailingContext: NSManagedObjectContext {
            override func save() throws { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "диск недоступен"]) }
        }
        let p = PersistenceController(inMemory: true)
        let bad = FailingContext(concurrencyType: .mainQueueConcurrencyType)
        bad.persistentStoreCoordinator = p.container.persistentStoreCoordinator
        let saver = SaveCoordinator(context: bad)
        PurchaseFlow.resetThrottle()
        let proj = DataOps.createProject(bad, name: "Ф", holder: "М", issued: 1)
        let r = AddFlow.createManual(project: proj, ctx: bad)
        r.purchaseList[0].title = "Лампа"
        XCTAssertNil(PurchaseFlow.saveAndCreateNext(project: proj, ctx: bad, current: r, saver: saver))
        XCTAssertEqual(PurchaseFlow.lastError, "диск недоступен")
        XCTAssertEqual(proj.receiptList.count, 1, "следующая позиция не создана")
        XCTAssertEqual(r.purchaseList[0].title, "Лампа", "данные не потеряны")
    }

    func testDoubleEnterAndEmptyEnterCreateNothingExtra() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        let saver = SaveCoordinator(context: ctx)
        PurchaseFlow.resetThrottle()
        let proj = DataOps.createProject(ctx, name: "Ф", holder: "М", issued: 1)
        let r = AddFlow.createManual(project: proj, ctx: ctx)
        saver.setActive([r.objectID])
        XCTAssertNil(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: r, saver: saver), "Enter в пустой форме ничего не создаёт")
        r.purchaseList[0].title = "Лампа"
        let next = try XCTUnwrap(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: r, saver: saver))
        XCTAssertNil(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: r, saver: saver), "двойное нажатие — одна новая позиция")
        XCTAssertNil(PurchaseFlow.saveAndCreateNext(project: proj, ctx: ctx, current: next, saver: saver), "и пустая новая позиция не плодит следующих")
        XCTAssertEqual(proj.receiptList.count, 2)
    }
}

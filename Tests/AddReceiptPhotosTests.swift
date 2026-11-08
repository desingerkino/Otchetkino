import XCTest
import CoreData
@testable import Rekvizit

/// Кнопка «+ Добавить чек»: прикрепление фотографий к текущей покупке; заголовки дат.
@MainActor
final class AddReceiptPhotosTests: XCTestCase {
    private var p: PersistenceController!
    private var ctx: NSManagedObjectContext { p.viewContext }

    override func setUp() async throws { p = PersistenceController(inMemory: true) }

    private func receipt(photos: [Data] = []) -> RReceipt {
        let proj = DataOps.createProject(ctx, name: "Фильм", holder: "Миша", issued: 1_000_000)
        let r = DataOps.createReceipt(ctx, project: proj, photos: photos, noReceipt: photos.isEmpty)
        r.date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))
        DataOps.addItem(ctx, to: r, title: "Лампа", amount: 12_300)
        try? ctx.save()
        return r
    }
    private func jpeg(_ w: Int) -> Data { CoreTests.makeJPEG(width: w, height: w + 40) }

    func testAttachOnePhotoToReceiptWithoutPhotos() {
        let r = receipt()
        let res = DataOps.attachPhotos(ctx, datas: [jpeg(60)], to: r)
        XCTAssertEqual(res.added, 1); XCTAssertEqual(res.skipped, 0)
        XCTAssertEqual(r.photoList.count, 1)
    }

    func testAttachSeveralPhotosAtOnceKeepsOrder() {
        let r = receipt()
        let a = jpeg(60), b = jpeg(70), c = jpeg(80)
        _ = DataOps.attachPhotos(ctx, datas: [a, b, c], to: r)
        XCTAssertEqual(r.photoList.compactMap { $0.data }, [a, b, c])
    }

    func testNewPhotosAreAddedToExistingNotReplacing() {
        let first = jpeg(60)
        let r = receipt(photos: [first])
        let res = DataOps.attachPhotos(ctx, datas: [jpeg(90), jpeg(100)], to: r)
        XCTAssertEqual(res.added, 2)
        XCTAssertEqual(r.photoList.count, 3)
        XCTAssertEqual(r.photoList.first?.data, first)
    }

    func testDuplicatesAreSkippedBothAgainstExistingAndWithinSelection() {
        let a = jpeg(60), b = jpeg(70)
        let r = receipt(photos: [a])
        let res = DataOps.attachPhotos(ctx, datas: [a, b, b], to: r)
        XCTAssertEqual(res.added, 1); XCTAssertEqual(res.skipped, 2)
        XCTAssertEqual(r.photoList.count, 2)
    }

    func testAttachDoesNotTouchNumberDateAmountOrCreatePurchases() {
        let r = receipt()
        let number = r.number, date = r.date, sum = r.itemsSum, count = r.purchaseList.count
        let receiptsBefore = (try? ctx.count(for: RReceipt.fetchRequest())) ?? -1
        _ = DataOps.attachPhotos(ctx, datas: [jpeg(60), jpeg(70)], to: r)
        XCTAssertEqual(r.number, number); XCTAssertEqual(r.date, date)
        XCTAssertEqual(r.itemsSum, sum); XCTAssertEqual(r.purchaseList.count, count)
        XCTAssertEqual((try? ctx.count(for: RReceipt.fetchRequest())) ?? -2, receiptsBefore)
    }

    func testCancelledSelectionChangesNothing() {
        let r = receipt(photos: [jpeg(60)])
        let res = DataOps.attachPhotos(ctx, datas: [], to: r)
        XCTAssertEqual(res.added, 0); XCTAssertEqual(res.skipped, 0)
        XCTAssertEqual(r.photoList.count, 1)
    }

    func testOriginalsAreStoredByteForByte() throws {
        let original = jpeg(120)
        let r = receipt()
        _ = DataOps.attachPhotos(ctx, datas: [original], to: r)
        XCTAssertEqual(try XCTUnwrap(r.photoList.first?.data), original)
    }

    func testPhotosSurviveSaveAndSwitchingBetweenReceipts() throws {
        let r1 = receipt()
        let r2 = DataOps.createReceipt(ctx, project: try XCTUnwrap(r1.project), photos: [], noReceipt: true)
        _ = DataOps.attachPhotos(ctx, datas: [jpeg(60), jpeg(70)], to: r1)
        _ = DataOps.attachPhotos(ctx, datas: [jpeg(80)], to: r2)
        try ctx.save()
        ctx.refreshAllObjects()
        XCTAssertEqual(r1.photoList.count, 2)
        XCTAssertEqual(r2.photoList.count, 1)
    }

    func testDateHeaderText() {
        let d = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
        XCTAssertEqual(DateHeaderView.text(d), "6 НОЯБРЯ 2026")
    }
}

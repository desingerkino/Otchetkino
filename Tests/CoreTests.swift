import XCTest
import CoreData
import CoreGraphics
import ImageIO
@testable import Rekvizit

final class CoreTests: XCTestCase {
    // MARK: помощники

    static func makeJPEG(width: Int, height: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: width / 2, height: height / 3))
        return ImageTools.jpegData(from: ctx.makeImage()!, quality: 0.9)!
    }

    @MainActor
    func makeProject(_ p: PersistenceController) -> RProject {
        DataOps.createProject(p.viewContext, name: "Тестовый фильм", holder: "Миша Черкасов", issued: 5_000_000)
    }

    // MARK: ZIP

    func testZipRoundTrip() {
        var z = ZipWriter()
        z.add(name: "a.txt", string: "привет")
        z.add(name: "dir/b.bin", data: Data([1, 2, 3, 4, 5]))
        let files = ZipReader.read(z.finish())
        XCTAssertEqual(files?["a.txt"], Data("привет".utf8))
        XCTAssertEqual(files?["dir/b.bin"], Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF43926)
    }

    // MARK: Деньги и нумерация

    @MainActor
    func testBalanceNumberingAndDrafts() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        let project = makeProject(p)
        XCTAssertEqual(project.totals().balance, 5_000_000)

        let r1 = DataOps.createReceipt(ctx, project: project, photos: [Self.makeJPEG(width: 300, height: 600)], noReceipt: false)
        let r2 = DataOps.createReceipt(ctx, project: project, photos: [], noReceipt: true)
        XCTAssertEqual(r1.number, 1)
        XCTAssertEqual(r2.number, 2)
        DataOps.addItem(ctx, to: r1, title: "Стиральная машина", amount: 1_850_000)
        DataOps.addItem(ctx, to: r1, title: "Шнур", amount: 50_000)
        DataOps.addItem(ctx, to: r2, title: "Краска", amount: 30_000)

        // черновики в итоги не входят
        XCTAssertEqual(project.totals().spent, 0)
        XCTAssertEqual(project.totals().draftCount, 2)
        r1.isDraft = false; r2.isDraft = false
        var t = project.totals()
        XCTAssertEqual(t.spent, 1_930_000)
        XCTAssertEqual(t.balance, 5_000_000 - 1_930_000)
        XCTAssertEqual(t.purchaseCount, 3)
        XCTAssertEqual(t.receiptCount, 1)
        XCTAssertEqual(t.noReceiptPurchases, 1)

        // возврат и дополнительная выдача
        DataOps.addAdvance(ctx, project: project, kind: 1, amount: 100_000, date: Date(), note: "")
        DataOps.addAdvance(ctx, project: project, kind: 0, amount: 200_000, date: Date(), note: "")
        t = project.totals()
        XCTAssertEqual(t.balance, 5_000_000 + 200_000 - 1_930_000 - 100_000)

        // перерасход
        let r3 = DataOps.createReceipt(ctx, project: project, photos: [], noReceipt: true)
        DataOps.addItem(ctx, to: r3, title: "Дорогая вещь", amount: 9_000_000)
        r3.isDraft = false
        XCTAssertTrue(project.totals().isOverspent)

        // повторяющиеся номера после синхронизации исправляются
        r3.number = 1
        Maintenance.fixDuplicateReceiptNumbers(ctx)
        let numbers = project.receiptList.map { $0.number }
        XCTAssertEqual(Set(numbers).count, numbers.count)
    }

    @MainActor
    func testCategoryDedupe() throws {
        let p = PersistenceController(inMemory: true)
        let ctx = p.viewContext
        for _ in 0..<2 { let c = RCategory(context: ctx); c.name = "Мебель" }
        let project = makeProject(p)
        let r = DataOps.createReceipt(ctx, project: project, photos: [], noReceipt: true)
        let item = DataOps.addItem(ctx, to: r, title: "Стол", amount: 100)
        let dup = (try ctx.fetch(NSFetchRequest<RCategory>(entityName: "RCategory"))).filter { $0.name == "Мебель" }
        item.category = dup.last
        Maintenance.dedupeCategories(ctx)
        try ctx.save()
        let left = try ctx.fetch(NSFetchRequest<RCategory>(entityName: "RCategory")).filter { $0.name == "Мебель" }
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(item.category?.name, "Мебель")
    }

    // MARK: Excel

    @MainActor
    func testXLSXHasEmbeddedImagesAndValidXML() throws {
        let jpeg = Self.makeJPEG(width: 600, height: 1500)
        let img = ImageTools.reportImage(from: jpeg)!
        let items1 = [ReportSnapshot.Item(title: "Стиральная <машина> & Ко", category: "Бытовая техника", scenes: "12, 14", amount: 1_850_000, quantity: 1, purpose: "Для квартиры"),
                      ReportSnapshot.Item(title: "Шнур", category: "Реквизит", scenes: "12", amount: 50_000, quantity: 2, purpose: "")]
        let items2 = [ReportSnapshot.Item(title: "Краска", category: "Расходные материалы", scenes: "", amount: 30_000, quantity: 1, purpose: "")]
        let snap = ReportSnapshot(
            projectName: "Фильм", holder: "Миша", periodText: "01.01.2026 — 02.01.2026", issued: 5_000_000, returned: 0, spent: 1_930_000, balance: 3_070_000,
            purchaseCount: 3, receiptCount: 1, noReceiptCount: 1, generatedAt: Date(),
            receipts: [.init(number: 1, date: Date(), store: "DNS", inn: "2540167061", comment: "", noReceipt: false, items: items1, photos: [img, img]),
                       .init(number: 2, date: Date(), store: "", inn: "", comment: "рынок", noReceipt: true, items: items2, photos: [])],
            categories: [("Бытовая техника", 1_850_000)], advances: [(Date(), 0, 5_000_000, "Аванс")])
        let data = XLSXBuilder.build(snap)
        let files = try XCTUnwrap(ZipReader.read(data))
        for name in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/styles.xml",
                     "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet3.xml", "xl/worksheets/sheet4.xml",
                     "xl/drawings/drawing1.xml", "xl/drawings/drawing2.xml", "xl/media/image1.jpeg"] {
            XCTAssertNotNil(files[name], "нет \(name)")
        }
        // 1 фото на листе «Детализация» + 2 на листе «Фотографии» — все физически внутри файла
        XCTAssertEqual(files.keys.filter { $0.hasPrefix("xl/media/") }.count, 3)
        for (name, content) in files where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            let parser = XMLParser(data: content)
            XCTAssertTrue(parser.parse(), "\(name) — некорректный XML: \(parser.parserError?.localizedDescription ?? "")")
        }
        XCTAssertTrue(String(decoding: files["xl/worksheets/sheet2.xml"]!, as: UTF8.self).contains("Стиральная &lt;машина&gt; &amp; Ко"))
        // сохраним для ручной проверки как артефакт CI
        try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-report.xlsx"))
        XCTAssertEqual(XLSXBuilder.serial(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 1, day: 26, hour: 12))!), 46048)
    }

    func testPDFIsValid() throws {
        let img = ImageTools.reportImage(from: Self.makeJPEG(width: 500, height: 900))!
        let item = ReportSnapshot.Item(title: "Товар", category: "Прочее", scenes: "1", amount: 10_000, quantity: 1, purpose: "")
        let snap = ReportSnapshot(projectName: "Фильм", holder: "Миша", periodText: "всё время", issued: 100_000, returned: 0, spent: 10_000, balance: 90_000,
                                  purchaseCount: 1, receiptCount: 1, noReceiptCount: 0, generatedAt: Date(),
                                  receipts: [.init(number: 1, date: Date(), store: "Магазин", inn: "", comment: "", noReceipt: false, items: [item], photos: [img])],
                                  categories: [("Прочее", 10_000)], advances: [])
        let pdf = PDFBuilder.build(snap)
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(pdf.count, 5_000)
    }

    // MARK: Резервная копия

    @MainActor
    func testBackupRoundTrip() async throws {
        let a = PersistenceController(inMemory: true)
        let project = makeProject(a)
        let r = DataOps.createReceipt(a.viewContext, project: project, photos: [Self.makeJPEG(width: 200, height: 300)], noReceipt: false)
        DataOps.addItem(a.viewContext, to: r, title: "Лампа", amount: 123_00)
        r.isDraft = false
        try a.viewContext.save()
        let url = try await BackupService.create(container: a.container)
        defer { try? FileManager.default.removeItem(at: url) }

        let b = PersistenceController(inMemory: true)
        let added = try await BackupService.restore(from: url, container: b.container)
        XCTAssertGreaterThan(added, 0)
        b.viewContext.refreshAllObjects()
        let projects = try b.viewContext.fetch(NSFetchRequest<RProject>(entityName: "RProject"))
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.totals().spent, 123_00)
        XCTAssertEqual(projects.first?.receiptList.first?.photoList.count, 1)
        // повторное восстановление ничего не дублирует
        let again = try await BackupService.restore(from: url, container: b.container)
        XCTAssertEqual(again, 0)
    }
}

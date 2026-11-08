import XCTest
import PDFKit
@testable import Rekvizit

/// Наименование покупки в заголовке чека (PDF) и в реестре (Excel).
final class ExportNamesTests: XCTestCase {
    private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!

    private func item(_ title: String, _ amount: Int64) -> ReportSnapshot.Item {
        .init(title: title, category: "Прочее", scenes: "1", amount: amount, quantity: 1, purpose: "")
    }
    private func receipt(_ n: Int, store: String = "АВИТО", _ items: [ReportSnapshot.Item], photos: Int = 1) -> ReportSnapshot.Receipt {
        let im = ImageTools.reportImage(from: CoreTests.makeJPEG(width: 400, height: 700))!
        return .init(number: n, date: day, store: store, inn: "", comment: "", noReceipt: false, items: items, photos: Array(repeating: im, count: photos))
    }
    private func snapshot(_ rs: [ReportSnapshot.Receipt]) -> ReportSnapshot {
        let spent = rs.reduce(Int64(0)) { $0 + $1.total }
        return ReportSnapshot(projectName: "Проект", holder: "Миша", periodText: "всё время", issued: 10_000_000, returned: 0, spent: spent,
                              balance: 10_000_000 - spent, purchaseCount: rs.reduce(0) { $0 + $1.items.count }, receiptCount: rs.count,
                              noReceiptCount: 0, generatedAt: Date(), receipts: rs, categories: [("Прочее", spent)], advances: [])
    }
    private func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
    private func pdfText(_ snap: ReportSnapshot) throws -> (text: String, doc: PDFDocument) {
        let doc = try XCTUnwrap(PDFDocument(data: PDFBuilder.build(snap)))
        return (norm(doc.string ?? ""), doc)
    }

    // MARK: Формат заголовка

    func testSingleItemCaptionHasAllFiveParts() {
        let r = receipt(6, [item("Сумка санитарная СССР", 183_500)])
        let lines = ReceiptCaption.lines(r)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(norm(lines[0]), "Чек №006 · 03.11.2026 · АВИТО · Сумка санитарная СССР · \(norm(Money.format(183_500)))")
        XCTAssertTrue(norm(lines[0]).hasSuffix("1 835 ₽"))
    }

    func testMultipleItemsGoToTwoLinesWithReceiptTotal() {
        let r = receipt(7, [item("Сумка санитарная СССР", 100_000), item("контейнеры для еды", 60_000), item("упаковка копирка СССР", 49_300)])
        let lines = ReceiptCaption.lines(r)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(norm(lines[0]), "Чек №007 · 03.11.2026 · АВИТО")
        XCTAssertEqual(norm(lines[1]), "Сумка санитарная СССР, контейнеры для еды, упаковка копирка СССР · \(norm(Money.format(209_300)))")
    }

    func testManyItemsAreTruncatedWithCount() {
        let items = (1...8).map { item("Т\($0)", 1_000) }
        let line = ReceiptCaption.lines(receipt(1, items))[1]
        XCTAssertTrue(line.contains("Т1, Т2, Т3, Т4 и ещё 4 позиции"), line)
        XCTAssertFalse(line.contains("Т5"))
        XCTAssertTrue(norm(line).hasSuffix(norm(Money.format(8_000))), "сумма — по всему чеку")
        XCTAssertEqual(ReceiptCaption.plural(1), "позиция"); XCTAssertEqual(ReceiptCaption.plural(3), "позиции")
        XCTAssertEqual(ReceiptCaption.plural(5), "позиций"); XCTAssertEqual(ReceiptCaption.plural(11), "позиций"); XCTAssertEqual(ReceiptCaption.plural(21), "позиция")
    }

    func testMissingNameLeavesNoEmptySeparators() {
        for items in [[item("", 5_000)], [item("   ", 5_000)], [ReportSnapshot.Item]()] {
            let r = receipt(2, items.isEmpty ? [] : items)
            let line = ReceiptCaption.lines(r).joined(separator: " ")
            XCTAssertFalse(line.contains("·  ·"), line)
            XCTAssertFalse(line.contains("  "), "двойные пробелы: \(line)")
            XCTAssertTrue(line.hasPrefix("Чек №002 · 03.11.2026 · АВИТО"))
        }
        XCTAssertEqual(norm(ReceiptCaption.lines(receipt(2, [item("", 5_000)]))[0]), "Чек №002 · 03.11.2026 · АВИТО · 50 ₽")
        // пустое название среди заполненных не попадает в перечень
        let mixed = ReceiptCaption.lines(receipt(3, [item("Лампа", 1), item("", 1), item("Стол", 1)]))
        XCTAssertTrue(mixed[1].hasPrefix("Лампа, Стол · "), mixed[1])
    }

    func testStoreIsNeverUsedAsItemNameAndNothingIsInvented() {
        let r = receipt(4, store: "", [item("", 100)])
        let line = ReceiptCaption.lines(r)[0]
        XCTAssertTrue(line.contains("магазин не указан"))
        XCTAssertEqual(ReceiptCaption.nameList(r), "")
        let withStore = receipt(5, store: "Рынок", [item("", 100)])
        XCTAssertEqual(ReceiptCaption.nameList(withStore), "", "название магазина не подставляется вместо наименования")
    }

    func testPhotoSuffixOnLastLine() {
        let r = receipt(9, [item("А", 1), item("Б", 1)], photos: 2)
        let lines = ReceiptCaption.lines(r, photoIndex: 1, photoCount: 2)
        XCTAssertFalse(lines[0].contains("фото"))
        XCTAssertTrue(lines[1].hasSuffix("фото 2 из 2"))
    }

    // MARK: PDF

    func testPDFShowsCaptionsForSingleMultipleLongAndUnnamed() throws {
        let long = "Очень длинное наименование покупки для проверки переноса строки в заголовке чека без наложения на фотографию " + String(repeating: "слово ", count: 18)
        let snap = snapshot([
            receipt(6, [item("Сумка санитарная СССР", 183_500)]),
            receipt(7, [item("Сумка санитарная СССР", 100_000), item("контейнеры для еды", 60_000), item("упаковка копирка СССР", 49_300)]),
            receipt(8, [item(long, 12_300)]),
            receipt(9, [item("", 5_000)])
        ])
        let (text, doc) = try pdfText(snap)
        XCTAssertTrue(text.contains("Чек №006 · 03.11.2026 · АВИТО · Сумка санитарная СССР · 1 835 ₽"), text)
        XCTAssertTrue(text.contains("Чек №007 · 03.11.2026 · АВИТО"))
        XCTAssertTrue(text.contains("Сумка санитарная СССР, контейнеры для еды, упаковка копирка СССР · 2 093 ₽"), text)
        XCTAssertTrue(text.contains(norm(long)), "длинное наименование должно уместиться целиком (с переносом)")
        XCTAssertTrue(text.contains("Чек №009 · 03.11.2026 · АВИТО · 50 ₽"), text)
        // не создаются отдельные страницы на каждый товар: заголовок чека №007 — ровно один раз
        XCTAssertEqual(text.components(separatedBy: "Чек №007 · 03.11.2026 · АВИТО").count - 1, 1)
        // фото каждого чека — отдельная страница, лишних страниц на позиции нет
        let captionPages = (0..<doc.pageCount).filter { (doc.page(at: $0)?.string ?? "").contains("Чек №00") }.count
        XCTAssertGreaterThanOrEqual(captionPages, 4)
    }

    func testPDFCaptionDoesNotOverlapPhoto() throws {
        // длинный заголовок занимает несколько строк; фото начинается ниже его
        let long = String(repeating: "наименование ", count: 40)
        let doc = try pdfText(snapshot([receipt(1, [item(long, 1_000)])])).doc
        let page = try XCTUnwrap((0..<doc.pageCount).compactMap { doc.page(at: $0) }.first { ($0.string ?? "").contains("Чек №001") })
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertGreaterThan(bounds.height, 0)
        let text = norm(page.string ?? "")
        XCTAssertTrue(text.contains(norm(long)))
        // текст заголовка не выходит за нижний край: все строки заголовка выше полей страницы
        let sel = try XCTUnwrap(page.selection(for: bounds))
        XCTAssertFalse(sel.string?.isEmpty ?? true)
    }

    // MARK: Excel

    func testExcelRegistryHasNameColumnAndNoDuplicatedSums() throws {
        let snap = snapshot([
            receipt(6, [item("Сумка санитарная СССР", 183_500)]),
            receipt(7, [item("Лампа", 100_000), item("Стол", 60_000)]),
            receipt(8, [item("", 5_000)])
        ])
        let files = try XCTUnwrap(ZipReader.read(XLSXBuilder.build(snap)))
        let registry = String(decoding: try XCTUnwrap(files["xl/worksheets/sheet3.xml"]), as: UTF8.self)
        XCTAssertTrue(registry.contains("Наименование покупки"))
        XCTAssertTrue(registry.contains("Сумка санитарная СССР"))
        XCTAssertTrue(registry.contains("Лампа, Стол"))
        XCTAssertTrue(registry.contains("1835"), "сумма чека №006")
        XCTAssertTrue(registry.contains("1600"), "сумма чека №007 — одна, по всем позициям")
        XCTAssertFalse(registry.contains(">1000<"), "сумма отдельной позиции в реестре не повторяется")
        XCTAssertTrue(registry.contains("SUM(E4:E6)"), "итог считается по столбцу сумм чеков")
        // детализация: отдельные строки позиций с суммой каждой позиции; итог = общие расходы
        let detail = String(decoding: try XCTUnwrap(files["xl/worksheets/sheet2.xml"]), as: UTF8.self)
        XCTAssertTrue(detail.contains("Лампа")); XCTAssertTrue(detail.contains("Стол"))
        XCTAssertTrue(detail.contains("SUM(G5:G8)"))
        // подписи на листе с фото в новом формате
        let photos = String(decoding: try XCTUnwrap(files["xl/worksheets/sheet4.xml"]), as: UTF8.self)
        XCTAssertTrue(photos.contains("Чек №006 · 03.11.2026 · АВИТО · Сумка санитарная СССР"))
    }
}

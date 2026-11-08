import XCTest
import PDFKit
import AppKit
@testable import Rekvizit

/// Чередование строк и заголовки страниц чеков в PDF и Excel.
final class ExportFormattingTests: XCTestCase {
    private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!

    private func item(_ t: String, _ a: Int64) -> ReportSnapshot.Item { .init(title: t, category: "Реквизит", scenes: "1", amount: a, quantity: 1, purpose: "") }
    private func receipt(_ n: Int, dayOffset: Int = 0, _ items: [ReportSnapshot.Item], photos: Int = 0) -> ReportSnapshot.Receipt {
        let im = ImageTools.reportImage(from: CoreTests.makeJPEG(width: 300, height: 500))!
        return .init(number: n, date: Calendar.current.date(byAdding: .day, value: dayOffset, to: day)!, store: "АВИТО", inn: "", comment: "",
                     noReceipt: photos == 0, items: items, photos: Array(repeating: im, count: photos))
    }
    private func snapshot(_ rs: [ReportSnapshot.Receipt]) -> ReportSnapshot {
        let spent = rs.reduce(Int64(0)) { $0 + $1.total }
        return ReportSnapshot(projectName: "Проект", holder: "Миша", periodText: "всё время", issued: 100_000_000, returned: 0, spent: spent,
                              balance: 100_000_000 - spent, purchaseCount: rs.reduce(0) { $0 + $1.items.count }, receiptCount: rs.count,
                              noReceiptCount: 0, generatedAt: Date(), receipts: rs, categories: [("Реквизит", spent), ("Мебель", 100)],
                              advances: [(day, 0, 1_000_000, "Реквизит"), (day, 0, 500_000, "Доп."), (day, 1, 10_000, "Возврат")])
    }
    private func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: " ,", with: ",")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: PDF — заголовок каждой страницы с фото чека

    func testEveryReceiptPhotoPageHasItsNameInHeader() throws {
        let rs = [
            receipt(17, [item("Деловой календарь 1992г.", 43_900)], photos: 1),
            receipt(10, dayOffset: 1, [item("Кобура оперативная ПМ", 100_000), item("Сумка тележка на колесах", 200_000), item("Стаканы винтаж складные", 71_100)], photos: 1),
            receipt(11, dayOffset: 1, [item("А", 1), item("Б", 1), item("В", 1), item("Г", 1), item("Д", 1)], photos: 2),
            receipt(12, [item("", 5_000)], photos: 1)
        ]
        let doc = try XCTUnwrap(PDFDocument(data: PDFBuilder.build(snapshot(rs))))
        let pages = (0..<doc.pageCount).map { norm(doc.page(at: $0)?.string ?? "") }
        func page(containing s: String) -> String? { pages.first { $0.contains(s) && !$0.contains("Расходы по категориям") && $0.contains("стр.") && $0.contains("Чек №") && !$0.contains("1. Выдача") } }
        // «Чек №017 · 03.11.2026 · АВИТО · Деловой календарь 1992г. · 439 ₽» — на странице с фото, не только в таблице
        let p17 = try XCTUnwrap(pages.first { $0.hasPrefix("Чек №017") || ($0.contains("Чек №017 · 03.11.2026 · АВИТО · Деловой календарь 1992г. · 439 ₽") && !$0.contains("Наименование")) })
        XCTAssertTrue(p17.contains("Чек №017 · 03.11.2026 · АВИТО · Деловой календарь 1992г. · 439 ₽"), p17)
        let p10 = try XCTUnwrap(pages.first { $0.contains("Чек №010 · 04.11.2026 · АВИТО") && !$0.contains("Наименование") })
        XCTAssertTrue(p10.contains("Кобура оперативная ПМ, Сумка тележка на колесах, Стаканы винтаж складные · 3 711 ₽"), p10)
        // больше трёх: первые три и «и ещё N позиций»; на каждой из двух страниц с фото чека №011
        let p11 = pages.filter { $0.contains("Чек №011 · 04.11.2026 · АВИТО") && !$0.contains("Наименование") }
        XCTAssertEqual(p11.count, 2)
        for p in p11 { XCTAssertTrue(p.contains("А, Б, В и ещё 2 позиции"), p) }
        // без наименования — без пустых разделителей
        let p12 = try XCTUnwrap(pages.first { $0.contains("Чек №012 · 03.11.2026 · АВИТО · 50 ₽") })
        XCTAssertFalse(p12.contains("·  ·"))
        _ = page(containing: "x")
        // всего страниц с фото — по числу фотографий (на позиции отдельных страниц нет)
        XCTAssertEqual(pages.filter { $0.contains("· фото") || ($0.contains("Чек №0") && !$0.contains("Наименование") && !$0.contains("ФИНАНСОВЫЙ")) }.count >= 5, true)
    }

    // MARK: PDF — чередование

    func testPDFZebraIsContinuousAcrossPagesAndTotalRowIsDistinct() throws {
        PDFBuilder.rowTrace = []
        defer { PDFBuilder.rowTrace = nil }
        let rs = (1...70).map { receipt($0, dayOffset: $0 / 10, [item("Покупка \($0)", 10_000)]) }   // много строк и несколько дат
        let data = PDFBuilder.build(snapshot(rs))
        let trace = try XCTUnwrap(PDFBuilder.rowTrace)
        let rows = trace.filter { $0.table == "2. Покупки" && $0.kind != .total }
        XCTAssertEqual(rows.count, 70)
        XCTAssertGreaterThan(Set(rows.map { $0.page }).count, 1, "таблица должна занять несколько страниц")
        for (i, r) in rows.enumerated() {
            XCTAssertEqual(r.index, i)
            XCTAssertEqual(r.kind, i % 2 == 0 ? .odd : .even, "чередование нарушено на строке \(i + 1) (страница \(r.page))")
        }
        // первая строка новой страницы продолжает последовательность, а не начинается заново
        for i in 1..<rows.count where rows[i].page != rows[i - 1].page { XCTAssertNotEqual(rows[i].kind, rows[i - 1].kind) }
        XCTAssertEqual(trace.filter { $0.table == "2. Покупки" && $0.kind == .total }.count, 1)
        // чередование во всех таблицах
        for t in Set(trace.map { $0.table }) {
            let seq = trace.filter { $0.table == t && $0.kind != .total }
            for (i, r) in seq.enumerated() { XCTAssertEqual(r.kind, i % 2 == 0 ? .odd : .even, t) }
        }
        // цвета действительно в документе: светло-серый #F2F3F5 и итог #E9EAED присутствуют на странице таблицы
        let doc = try XCTUnwrap(PDFDocument(data: data))
        func pixelCount(_ page: PDFPage, _ rgb: (Int, Int, Int), tol: Int = 4) -> Int {
            let w = 842 * 2, h = 595 * 2
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let box = page.bounds(for: .mediaBox)
            ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
            page.draw(with: .mediaBox, to: ctx)
            var n = 0
            for i in 0..<(w * h) {
                let o = i * 4
                if abs(Int(buf[o]) - rgb.0) <= tol && abs(Int(buf[o + 1]) - rgb.1) <= tol && abs(Int(buf[o + 2]) - rgb.2) <= tol { n += 1 }
            }
            return n
        }
        let tablePage = try XCTUnwrap((0..<doc.pageCount).compactMap { doc.page(at: $0) }.first { ($0.string ?? "").contains("Покупка 1") })
        XCTAssertGreaterThan(pixelCount(tablePage, (242, 243, 245)), 1_000, "светло-серые строки #F2F3F5")
        let lastPage = try XCTUnwrap((0..<doc.pageCount).compactMap { doc.page(at: $0) }.first { ($0.string ?? "").contains("ИТОГО") && ($0.string ?? "").contains("Покупка 70") })
        XCTAssertGreaterThan(pixelCount(lastPage, (233, 234, 237)), 500, "строка ИТОГО #E9EAED")
    }

    // MARK: Excel

    private func styleIndexes(_ xml: String, column: String, rows: ClosedRange<Int>) -> [Int] {
        rows.compactMap { r -> Int? in
            guard let range = xml.range(of: "<c r=\"\(column)\(r)\" s=\"") else { return nil }
            let rest = xml[range.upperBound...]
            return Int(rest.prefix { $0.isNumber })
        }
    }

    func testExcelZebraIsContinuousAcrossDatesAndSheets() throws {
        let rs = [
            receipt(1, dayOffset: 0, [item("Лампа", 100_000), item("Стол", 60_000)]),
            receipt(2, dayOffset: 1, [item("Кресло", 30_000)]),
            receipt(3, dayOffset: 2, [item("Шкаф", 20_000), item("Ковёр", 10_000)]),
            receipt(4, dayOffset: 2, [item("Люстра", 5_000)])
        ]
        let files = try XCTUnwrap(ZipReader.read(XLSXBuilder.build(snapshot(rs))))
        let styles = String(decoding: try XCTUnwrap(files["xl/styles.xml"]), as: UTF8.self)
        // заливки: белая, светло-серая, итог
        XCTAssertTrue(styles.contains("FFFFFFFF")); XCTAssertTrue(styles.contains("FFF2F3F5")); XCTAssertTrue(styles.contains("FFE9EAED"))
        XCTAssertFalse(styles.contains("FFF1F2F4"), "старый оттенок итога заменён на #E9EAED")
        // детализация: 6 строк позиций, стили колонки «№» чередуются 25/26 без сброса на новой дате и новом чеке
        let detail = String(decoding: try XCTUnwrap(files["xl/worksheets/sheet2.xml"]), as: UTF8.self)
        XCTAssertEqual(styleIndexes(detail, column: "A", rows: 5...10), [25, 26, 25, 26, 25, 26])
        XCTAssertEqual(styleIndexes(detail, column: "C", rows: 5...10), [17, 18, 17, 18, 17, 18], "наименования: белая/серая")
        XCTAssertEqual(styleIndexes(detail, column: "G", rows: 5...10), [19, 20, 19, 20, 19, 20], "суммы сохраняют денежный формат")
        XCTAssertEqual(styleIndexes(detail, column: "B", rows: 5...10), [21, 22, 21, 22, 21, 22], "даты сохраняют формат")
        // итог: формула и особый стиль (фон #E9EAED, жирный)
        XCTAssertTrue(detail.contains("SUM(G5:G10)"))
        XCTAssertEqual(styleIndexes(detail, column: "G", rows: 11...11), [10])
        // реестр: 4 чека — то же чередование; итог
        let registry = String(decoding: try XCTUnwrap(files["xl/worksheets/sheet3.xml"]), as: UTF8.self)
        XCTAssertEqual(styleIndexes(registry, column: "A", rows: 4...7), [25, 26, 25, 26])
        XCTAssertEqual(styleIndexes(registry, column: "E", rows: 4...7), [19, 20, 19, 20])
        XCTAssertEqual(styleIndexes(registry, column: "E", rows: 8...8), [10])
        XCTAssertTrue(registry.contains("SUM(E4:E7)"))
        // шапка осталась тёмной (стиль 2 → заливка 2 с белым шрифтом)
        XCTAssertEqual(styleIndexes(detail, column: "A", rows: 4...4), [2])
        // сводный лист: таблица категорий и выдач тоже чередуется
        let summary = String(decoding: try XCTUnwrap(files["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        XCTAssertTrue(summary.contains("s=\"17\"") && summary.contains("s=\"18\""))
    }

    func testStylesXMLIsWellFormedWithMatchingCounts() throws {
        let files = try XCTUnwrap(ZipReader.read(XLSXBuilder.build(snapshot([receipt(1, [item("Лампа", 100)])]))))
        let data = try XCTUnwrap(files["xl/styles.xml"])
        let parser = XMLParser(data: data)
        XCTAssertTrue(parser.parse(), "styles.xml должен быть корректным XML: \(String(describing: parser.parserError))")
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<xf numFmtId").count - 1, 27 + 1)   // 27 ячеечных стилей + 1 в cellStyleXfs
        XCTAssertTrue(xml.contains("<fills count=\"6\">"))
        XCTAssertEqual(xml.components(separatedBy: "<fill>").count - 1, 6)
    }
}

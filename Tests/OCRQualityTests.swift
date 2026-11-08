import XCTest
import CoreImage
@testable import Rekvizit

/// Проверка распознавания даты и итоговой суммы на «проверочных» чеках.
final class OCRQualityTests: XCTestCase {
    private let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!

    private func ymd(_ d: Date?) -> String {
        guard let d = d else { return "nil" }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: Итог не путается с промежуточными суммами

    func testTotalIgnoresSubtotalDiscountAndCash() {
        let p = ReceiptParser.parse(lines: ["Магазин «Всё для дома»", "Лампа 1 x 1500.00 = 1500.00", "ПОДЫТОГ 1500.00", "СКИДКА 200.00",
                                            "ИТОГО К ОПЛАТЕ 1300.00", "НАЛИЧНЫМИ 2000.00", "СДАЧА 700.00", "12.10.2026 14:21"], now: now)
        XCTAssertEqual(p.totalKop, 130_000)
        XCTAssertTrue(p.totalConfident)
        XCTAssertEqual(ymd(p.date), "2026-10-12")
        XCTAssertTrue(p.dateConfident)
    }

    func testToPayWinsOverItogo() {
        let p = ReceiptParser.parse(lines: ["ИП Иванов", "Товар 1 000.00", "ИТОГО 1000.00", "СКИДКА 100.00", "К ОПЛАТЕ 900.00", "08.11.2026 12:00"], now: now)
        XCTAssertEqual(p.totalKop, 90_000)
    }

    func testTotalWithWordVsego() {
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Хлеб 45.00", "Молоко 89.90", "НДС 10% 12.26", "ВСЕГО 134.90", "Спасибо за покупку", "03.11.2026 10:05:11"], now: now)
        XCTAssertEqual(p.totalKop, 13_490)
        XCTAssertEqual(ymd(p.date), "2026-11-03")
    }

    func testTotalWithWordSumma() {
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Гвозди 120.00", "СУММА 120.00", "НДС 20% 20.00", "05.11.2026 09:30"], now: now)
        XCTAssertEqual(p.totalKop, 12_000)
    }

    func testTotalKopecksSeparatedBySpace() {
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Гвозди 1 120.00", "ИТОГО 1120 00", "05.11.2026 09:30"], now: now)
        XCTAssertEqual(p.totalKop, 112_000)
    }

    func testDiscountLineIsNotTreatedAsTotal() {
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Чайник 2 500.00", "ИТОГО СКИДКА 250.00", "ИТОГО 2250.00", "05.11.2026 09:30"], now: now)
        XCTAssertEqual(p.totalKop, 225_000)
    }

    func testUnreliableTotalIsFlaggedForReview() {
        // ключевых слов нет — берётся наибольшая сумма, но поле помечается для проверки
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Что-то 120.00", "Ещё 80.00", "05.11.2026 09:30"], now: now)
        XCTAssertEqual(p.totalKop, 12_000)
        XCTAssertFalse(p.totalConfident)
        XCTAssertTrue(p.reviewFields.contains("сумма"))
    }

    func testNothingIsInvented() {
        let p = ReceiptParser.parse(lines: ["просто какой-то текст", "без цифр"], now: now)
        XCTAssertNil(p.totalKop)
        XCTAssertNil(p.date)
        XCTAssertTrue(p.items.isEmpty)
    }

    // MARK: Даты

    func testDateFormats() {
        let cases: [(String, String)] = [
            ("Дата 08/11/2026 12:30", "2026-11-08"),
            ("8 ноября 2026 г. 12:30", "2026-11-08"),
            ("2026-11-08 12:30:00", "2026-11-08"),
            ("08.11.26 12:30", "2026-11-08"),
            ("20261108T1230", "2026-11-08"),
            ("ДАТА: 08,11,2026", "2026-11-08"),
            ("O8.11.2O26 12:30", "2026-11-08")
        ]
        for (line, expected) in cases {
            let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Товар 10.00", "ИТОГО 10.00", line], now: now)
            XCTAssertEqual(ymd(p.date), expected, "не распознана дата в «\(line)»")
        }
    }

    func testPurchaseDateBeatsShelfLifeDate() {
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Молоко 89.90", "Срок годности до 01.10.2026", "ИТОГО 89.90", "Чек от 08.11.2026 12:30"], now: now)
        XCTAssertEqual(ymd(p.date), "2026-11-08")
    }

    func testFutureAndAbsurdDatesAreRejected() {
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Товар 10.00", "ИТОГО 10.00", "31.12.2030 10:00", "01.01.1999"], now: now)
        XCTAssertNil(p.date)
    }

    func testLowConfidenceDateIsFlagged() {
        let p = ReceiptParser.parse(lines: ["ООО Ромашка", "Товар 10.00", "ИТОГО 10.00", "05.11.26"], now: now)
        XCTAssertEqual(ymd(p.date), "2026-11-05")
        XCTAssertFalse(p.dateConfident)
        XCTAssertTrue(p.reviewFields.contains("дата"))
    }

    func testStoreFromFirstLineIsFlagged() {
        let p = ReceiptParser.parse(lines: ["Пятёрочка", "Хлеб 45.00", "ИТОГО 45.00", "05.11.2026 09:30"], now: now)
        XCTAssertEqual(p.store, "Пятёрочка")
        XCTAssertTrue(p.reviewFields.contains("магазин"))
    }

    // MARK: Фото → текст → поля (Apple Vision на отрисованных чеках)

    private let tricky = ["ООО \"Ромашка\"", "КАССОВЫЙ ЧЕК / ПРИХОД", "Лампа настольная 1 x 1500.00 = 1500.00", "ПОДЫТОГ 1500.00", "СКИДКА 200.00",
                          "ИТОГО К ОПЛАТЕ 1300.00", "НАЛИЧНЫМИ 2000.00", "СДАЧА 700.00", "12.10.2026 14:21"]

    func testVisionReadsDiscountReceipt() throws {
        let data = CoreTests.renderReceipt(lines: tricky)
        let (lines, parsed) = OCRService.recognizeBest(data)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(parsed.totalKop, 130_000, "итог не распознан: \(lines)")
        XCTAssertEqual(ymd(parsed.date), "2026-10-12", "дата не распознана: \(lines)")
    }

    func testVisionReadsSidewaysPhoto() throws {
        // чек сфотографировали боком: повёрнутое на 90° изображение
        let upright = try XCTUnwrap(ImageTools.cgImage(from: CoreTests.renderReceipt(lines: tricky), maxPixel: 4000))
        let turned = try XCTUnwrap(ReceiptImagePrep.rotated(upright, .right))
        let data = try XCTUnwrap(ImageTools.jpegData(from: turned, quality: 0.9))
        let (lines, parsed) = OCRService.recognizeBest(data)
        XCTAssertEqual(parsed.totalKop, 130_000, "итог не распознан на повёрнутом фото: \(lines)")
        XCTAssertEqual(ymd(parsed.date), "2026-10-12", "дата не распознана на повёрнутом фото: \(lines)")
    }

    func testEnhancementProducesImage() throws {
        let cg = try XCTUnwrap(ImageTools.cgImage(from: CoreTests.renderReceipt(lines: tricky), maxPixel: 3000))
        let enhanced = try XCTUnwrap(ReceiptImagePrep.enhanced(cg))
        XCTAssertGreaterThan(enhanced.width, 100)
        XCTAssertGreaterThan(enhanced.height, 100)
    }
}

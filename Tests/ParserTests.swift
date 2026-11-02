import XCTest
@testable import Rekvizit

final class ParserTests: XCTestCase {
    func testMoneyFormat() {
        XCTAssertEqual(Money.format(1_850_000), "18\u{00A0}500\u{00A0}₽")
        XCTAssertEqual(Money.format(123_450), "1\u{00A0}234,50\u{00A0}₽")
        XCTAssertEqual(Money.format(-5_000), "−50\u{00A0}₽")
    }
    func testMoneyParse() {
        XCTAssertEqual(Money.parse("18 500"), 1_850_000)
        XCTAssertEqual(Money.parse("1 200,5 руб"), 120_050)
        XCTAssertEqual(Money.parse("99.99"), 9_999)
        XCTAssertNil(Money.parse("abc"))
    }
    func testParseReceipt() {
        let lines = [
            "ООО \"ДНС Ритейл\"", "КАССОВЫЙ ЧЕК / ПРИХОД", "ИНН 2540167061", "Стиральная машина LG 1 x 18500.00 = 18500.00",
            "Шнур питания", "2 x 250.00 = 500.00", "ИТОГО 19000.00", "НАЛИЧНЫМИ 19000.00", "НДС 20% 3166.67", "26.01.2026 14:35"
        ]
        let p = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(p.totalKop, 1_900_000)
        XCTAssertEqual(p.inn, "2540167061")
        XCTAssertEqual(p.store, "ООО \"ДНС Ритейл\"")
        XCTAssertEqual(p.items.count, 2)
        XCTAssertEqual(p.items.first?.sumKop, 1_850_000)
        XCTAssertEqual(p.items.last?.quantity, 2)
        XCTAssertTrue(p.itemsConsistent)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: p.date!)
        XCTAssertEqual(c.day, 26); XCTAssertEqual(c.month, 1); XCTAssertEqual(c.year, 2026)
    }
    func testTotalOnNextLine() {
        let p = ReceiptParser.parse(lines: ["Магазин Мир", "Хлеб 45,00", "Молоко 89,90", "ИТОГ", "134,90", "01.02.26"])
        XCTAssertEqual(p.totalKop, 13_490)
        XCTAssertEqual(p.items.count, 2)
        XCTAssertTrue(p.itemsConsistent)
    }
}

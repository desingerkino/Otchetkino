import Foundation

struct ParsedItem: Equatable {
    var title: String
    var quantity: Double
    var priceKop: Int64
    var sumKop: Int64
}

struct ParsedReceipt {
    var date: Date?
    var store: String?
    var inn: String?
    var totalKop: Int64?
    var items: [ParsedItem] = []
    /// Позиции сходятся с итогом — им можно доверять
    var itemsConsistent: Bool {
        guard let total = totalKop, !items.isEmpty else { return false }
        return items.reduce(0) { $0 + $1.sumKop } == total
    }
    var isEmpty: Bool { date == nil && store == nil && inn == nil && totalKop == nil && items.isEmpty }
}

/// Разбор текста кассового чека (после OCR). Чистая логика без зависимостей от Vision — её можно тестировать.
enum ReceiptParser {
    private static let stopWords = [
        "ИТОГ", "НДС", "НАЛИЧН", "ЭЛЕКТРОН", "БЕЗНАЛ", "СДАЧА", "КАССОВЫЙ", "ЧЕК", "ККТ", "ФН ", "ФД", "ФП", "ФПД", "СНО", "ИНН",
        "КАССИР", "СМЕНА", "СУММА", "ВСЕГО", "СКИДК", "ОПЛАТА", "ПОЛУЧЕНО", "САЙТ", "WWW", "HTTP", "ОФД", "СПАСИБО", "ДОБРО",
        "ПРИХОД", "РН ККТ", "ЗН ККТ", "ТЕЛ", "АДРЕС", "МЕСТО РАСЧ", "ВИД ОПЕРАЦИИ", "ЧЕК №", "ПРИЗНАК", "ПОКУПАТЕЛЬ", "ВОЗВРАТ ПРИХОДА",
        "СЧЕТ", "СЧЁТ", "ТЕРМИНАЛ", "КАРТА", "VISA", "MASTERCARD", "МИР "
    ]
    private static let amountRegex = try! NSRegularExpression(pattern: #"(?<![\d.,])(\d{1,3}(?:[ \x{00A0}]\d{3})+|\d+)[.,](\d{2})(?![\d])"#)
    private static let qtyRegex = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d+)?)\s*(?:шт\.?|кг|г|л|м|уп\.?)?\s*[xхXХ*×]\s*(\d{1,3}(?:[ \x{00A0}]\d{3})*[.,]\d{2}|\d+[.,]\d{2}|\d+)"#)

    static func parse(lines rawLines: [String], now: Date = Date()) -> ParsedReceipt {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result = ParsedReceipt()
        guard !lines.isEmpty else { return result }

        result.date = findDate(in: lines, now: now)
        result.inn = findINN(in: lines)
        result.store = findStore(in: lines)
        let (total, totalIndex) = findTotal(in: lines)
        result.totalKop = total
        result.items = findItems(in: lines, upTo: totalIndex)
        return result
    }

    // MARK: Дата

    static func findDate(in lines: [String], now: Date) -> Date? {
        let patterns = [#"(\d{2})[.\-/](\d{2})[.\-/](\d{4})"#, #"(\d{2})[.\-/](\d{2})[.\-/](\d{2})(?!\d)"#, #"(\d{4})-(\d{2})-(\d{2})"#, #"(\d{4})(\d{2})(\d{2})T\d{4}"#]
        let cal = Calendar(identifier: .gregorian)
        let maxYear = cal.component(.year, from: now) + 1
        for (pi, pattern) in patterns.enumerated() {
            let re = try! NSRegularExpression(pattern: pattern)
            for line in lines {
                let ns = line as NSString
                for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    guard m.numberOfRanges == 4,
                          let a = Int(ns.substring(with: m.range(at: 1))),
                          let b = Int(ns.substring(with: m.range(at: 2))),
                          let c = Int(ns.substring(with: m.range(at: 3))) else { continue }
                    var day = a, month = b, year = c
                    if pi == 2 || pi == 3 { year = a; month = b; day = c }
                    if pi == 1 { year = 2000 + c }
                    guard (2000...maxYear).contains(year), (1...12).contains(month), (1...31).contains(day) else { continue }
                    var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = day; comps.hour = 12
                    if let d = cal.date(from: comps) { return d }
                }
            }
        }
        return nil
    }

    // MARK: ИНН

    static func findINN(in lines: [String]) -> String? {
        let re = try! NSRegularExpression(pattern: #"ИНН\D{0,12}(\d{12}|\d{10})(?!\d)"#, options: [.caseInsensitive])
        let skipWords = ["ПОКУПАТЕЛ", "ОФД"]
        for line in lines where !skipWords.contains(where: { line.uppercased().contains($0) }) {
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1))
            }
        }
        // ИНН мог оказаться на следующей строке
        for (i, line) in lines.enumerated() where line.uppercased().hasPrefix("ИНН") && i + 1 < lines.count {
            let digits = lines[i + 1].filter { $0.isNumber }
            if digits.count == 10 || digits.count == 12 { return digits }
        }
        return nil
    }

    // MARK: Магазин

    static func findStore(in lines: [String]) -> String? {
        let org = ["ООО", "ИП ", "АО ", "ЗАО", "ПАО", "ОАО", "МАГАЗИН", "ТЦ ", "ТК ", "ГИПЕРМАРКЕТ", "СУПЕРМАРКЕТ"]
        let skip = ["ЧЕК", "КАССОВЫЙ", "ДОБРО ПОЖАЛОВАТЬ", "ТОВАРНЫЙ", "ПРИХОД", "КАССИР", "СМЕНА", "ИНН", "ДАТА", "WWW", "HTTP", "ТЕЛ"]
        let head = Array(lines.prefix(10))
        func letters(_ s: String) -> Int { s.filter { $0.isLetter }.count }
        func clean(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:*-_=\"'«»")) }
        // 1) строка с «ООО/ИП/…»
        if let l = head.first(where: { line in
            let u = line.uppercased(); return org.contains(where: { u.hasPrefix($0) || u.contains(" " + $0) }) && letters(line) >= 4
        }) { return clean(l) }
        // 2) первая осмысленная строка
        if let l = head.first(where: { line in
            let u = line.uppercased()
            return letters(line) >= 3 && !skip.contains(where: { u.contains($0) }) && !amountMatch(line)
        }) { return clean(l) }
        return nil
    }

    private static func amountMatch(_ line: String) -> Bool {
        amountRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    // MARK: Суммы

    static func amounts(in line: String) -> [(kop: Int64, range: NSRange)] {
        let ns = line as NSString
        return amountRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let whole = ns.substring(with: m.range(at: 1)).filter { $0.isNumber }
            let frac = ns.substring(with: m.range(at: 2))
            guard let w = Int64(whole), let f = Int64(frac) else { return nil }
            return (w * 100 + f, m.range)
        }
    }

    static func findTotal(in lines: [String]) -> (Int64?, Int) {
        let primary = ["ИТОГО", "ИТОГ", "К ОПЛАТЕ", "TOTAL", "ВСЕГО К ОПЛАТЕ"]
        var best: (Int64, Int)? = nil
        for (i, line) in lines.enumerated() {
            let u = line.uppercased()
            guard primary.contains(where: { u.contains($0) }), !u.contains("НДС") else { continue }
            var found = amounts(in: line).map { $0.kop }
            if found.isEmpty, i + 1 < lines.count { found = amounts(in: lines[i + 1]).map { $0.kop } }
            if let v = found.max(), v > 0 {
                // «ИТОГО» обычно одно; если несколько — берём наибольшее
                if best == nil || v > best!.0 { best = (v, i) }
            }
        }
        if let b = best { return (b.0, b.1) }
        for (i, line) in lines.enumerated() {
            let u = line.uppercased()
            guard u.contains("НАЛИЧН") || u.contains("ЭЛЕКТРОН") || u.contains("БЕЗНАЛ") || u.contains("СУММА") else { continue }
            if let v = amounts(in: line).map({ $0.kop }).max(), v > 0 { return (v, i) }
        }
        // запасной вариант: наибольшая сумма в документе
        var maxV: Int64 = 0, maxI = lines.count
        for (i, line) in lines.enumerated() {
            for a in amounts(in: line) where a.kop > maxV { maxV = a.kop; maxI = i }
        }
        return maxV > 0 ? (maxV, maxI) : (nil, lines.count)
    }

    // MARK: Позиции

    static func findItems(in lines: [String], upTo end: Int) -> [ParsedItem] {
        var items: [ParsedItem] = []
        var pendingTitle: String? = nil
        let limit = min(end, lines.count)
        guard limit > 0 else { return [] }

        func isStop(_ line: String) -> Bool {
            let u = line.uppercased()
            return stopWords.contains { u.contains($0) }
        }
        func cleanTitle(_ s: String) -> String {
            var t = s
            if let re = try? NSRegularExpression(pattern: #"^\s*\d{1,3}\s*[.)]\s+"#) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: " =*-_.,;:|"))
            return t
        }
        func letters(_ s: String) -> Int { s.filter { $0.isLetter }.count }

        for i in 0..<limit {
            let line = lines[i]
            if isStop(line) { pendingTitle = nil; continue }
            let ns = line as NSString
            let amts = amounts(in: line)

            // «2 x 100.00 = 200.00»
            if let q = qtyRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let qty = Double(ns.substring(with: q.range(at: 1)).replacingOccurrences(of: ",", with: ".")),
               let price = Money.parse(ns.substring(with: q.range(at: 2))) {
                var title = cleanTitle(ns.substring(to: q.range.location))
                if letters(title) < 2, let p = pendingTitle { title = p }
                var sum = Int64((Double(price) * qty).rounded())
                let after = ns.substring(from: q.range.location + q.range.length)
                if let a = amounts(in: after).last { sum = a.kop }
                if letters(title) >= 2 {
                    items.append(ParsedItem(title: title, quantity: qty, priceKop: price, sumKop: sum))
                }
                pendingTitle = nil
                continue
            }
            // «Название ...... 123.45»
            if let last = amts.last {
                let title = cleanTitle(ns.substring(to: amts.first!.range.location))
                let tail = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: CharacterSet(charactersIn: " ₽РрRr*=A-Za-z.")).isEmpty
                if letters(title) >= 2 && tail {
                    items.append(ParsedItem(title: title, quantity: 1, priceKop: last.kop, sumKop: last.kop))
                    pendingTitle = nil
                } else if letters(title) < 2, let p = pendingTitle, tail {
                    items.append(ParsedItem(title: p, quantity: 1, priceKop: last.kop, sumKop: last.kop))
                    pendingTitle = nil
                }
                continue
            }
            // строка без сумм — возможное название следующей строки
            if letters(line) >= 3 { pendingTitle = cleanTitle(line) } else { pendingTitle = nil }
        }
        return items
    }
}

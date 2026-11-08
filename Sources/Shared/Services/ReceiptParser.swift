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
    /// Насколько можно доверять найденному (низкая уверенность → поле подсвечивается для проверки)
    var dateConfident = false
    var totalConfident = false
    var storeConfident = false
    /// Какие поля стоит проверить человеку
    var reviewFields: [String] {
        var f: [String] = []
        if date != nil && !dateConfident { f.append("дата") }
        if totalKop != nil && !totalConfident { f.append("сумма") }
        if store != nil && !storeConfident { f.append("магазин") }
        return f
    }
    /// Оценка качества распознавания — по ней выбирается лучший из вариантов обработки фото
    var score: Double {
        var v = 0.0
        if date != nil { v += dateConfident ? 3 : 1 }
        if totalKop != nil { v += totalConfident ? 4 : 1 }
        if itemsConsistent { v += 3 }
        v += Double(min(items.count, 6)) * 0.2
        if store != nil { v += storeConfident ? 1 : 0.3 }
        return v
    }
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
        let trimmed = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result = ParsedReceipt()
        guard !trimmed.isEmpty else { return result }
        // «O» вместо «0», «l» вместо «1» внутри чисел и дат — типичные ошибки распознавания
        let lines = trimmed.map { fixDigits($0) }

        if let d = findDateScored(in: lines, now: now) { result.date = d.date; result.dateConfident = d.confident }
        result.inn = findINN(in: trimmed)
        let st = findStoreDetailed(in: trimmed)
        result.store = st.name
        result.storeConfident = st.confident
        let t = findTotalDetailed(in: lines)
        result.totalKop = t.kop
        result.items = findItems(in: lines, upTo: t.index)
        if let total = t.kop {
            if t.tier <= 1 { result.totalConfident = true }
            else if t.tier < 9, !result.items.isEmpty, result.items.reduce(0, { $0 + $1.sumKop }) == total { result.totalConfident = true }
        }
        return result
    }

    // MARK: Исправление типичных ошибок распознавания цифр

    private static func regexReplace(_ pattern: String, _ template: String, in text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    static func fixDigits(_ line: String) -> String {
        var t = line
        t = regexReplace(#"(?<=\d)[OОоo](?=[\d.,:/\-])"#, "0", in: t)
        t = regexReplace(#"(?<=[.,:/\-])[OОоo](?=\d)"#, "0", in: t)
        t = regexReplace(#"(?<=\d)[lIl|](?=\d)"#, "1", in: t)
        return t
    }

    // MARK: Дата

    static func findDate(in lines: [String], now: Date) -> Date? { findDateScored(in: lines, now: now)?.date }

    private static let monthNames: [String: Int] = [
        "янв": 1, "фев": 2, "мар": 3, "апр": 4, "мая": 5, "май": 5, "июн": 6, "июл": 7, "авг": 8, "сен": 9, "окт": 10, "ноя": 11, "дек": 12
    ]

    /// Ищет дату покупки среди всех строк и выбирает самую правдоподобную:
    /// рядом со временем, рядом со словом «дата», не из «срока годности», не из будущего.
    static func findDateScored(in lines: [String], now: Date) -> (date: Date, confident: Bool)? {
        let cal = Calendar(identifier: .gregorian)
        let latest = now.addingTimeInterval(2 * 86_400)
        let earliest = cal.date(from: DateComponents(year: 2015, month: 1, day: 1)) ?? .distantPast
        // шаблон, порядок групп (d, m, y), признак четырёхзначного года
        let numeric: [(String, (Int, Int, Int), Bool)] = [
            (#"(?<!\d)(\d{1,2})[.\-/,](\d{1,2})[.\-/,](\d{4})(?!\d)"#, (1, 2, 3), true),
            (#"(?<!\d)(\d{1,2})[.\-/,](\d{1,2})[.\-/,](\d{2})(?!\d)"#, (1, 2, 3), false),
            (#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#, (3, 2, 1), true),
            (#"(?<!\d)(\d{4})(\d{2})(\d{2})T\d{4}"#, (3, 2, 1), true)
        ]
        let timeRe = try? NSRegularExpression(pattern: #"(?<![\d.])([01]?\d|2[0-3]):[0-5]\d"#)
        let wordRe = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{1,2})\s+(янв|фев|мар|апр|мая|май|июн|июл|авг|сен|окт|ноя|дек)[а-я]*\.?\s+(\d{4})"#, options: [.caseInsensitive])

        func make(_ d: Int, _ m: Int, _ y: Int) -> Date? {
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
            guard let date = cal.date(from: comps), cal.component(.day, from: date) == d, date >= earliest, date <= latest else { return nil }
            return date
        }

        var candidates: [(date: Date, score: Int, fullYear: Bool)] = []
        for line in lines {
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            let u = line.uppercased()
            var base = 0
            if timeRe?.firstMatch(in: line, range: whole) != nil { base += 3 }
            if u.contains("ДАТА") || u.contains("ВРЕМЯ") || u.contains("ЧЕК") { base += 1 }
            if u.contains("СРОК") || u.contains("ГОДЕН") || u.contains("ДО КОНЦА") || u.contains("ИЗГОТОВ") { base -= 4 }
            for (pattern, order, full) in numeric {
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                for m in re.matches(in: line, range: whole) {
                    guard let a = Int(ns.substring(with: m.range(at: order.0))),
                          let b = Int(ns.substring(with: m.range(at: order.1))),
                          let c = Int(ns.substring(with: m.range(at: order.2))) else { continue }
                    let year = full ? c : 2000 + c
                    if let d = make(a, b, year) { candidates.append((d, base + (full ? 1 : 0), full)) }
                }
            }
            if let re = wordRe {
                for m in re.matches(in: line, range: whole) {
                    guard let day = Int(ns.substring(with: m.range(at: 1))), let year = Int(ns.substring(with: m.range(at: 3))),
                          let month = monthNames[ns.substring(with: m.range(at: 2)).lowercased()] else { continue }
                    if let d = make(day, month, year) { candidates.append((d, base + 1, true)) }
                }
            }
        }
        guard let top = candidates.map({ $0.score }).max() else { return nil }
        guard let best = candidates.first(where: { $0.score == top }) else { return nil }
        let distinct = Set(candidates.map { cal.startOfDay(for: $0.date) }).count
        // уверенно: полная дата со временем/словом «дата» или единственная найденная дата
        let confident = best.fullYear && (top >= 3 || distinct == 1)
        return (best.date, confident)
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

    static func findStore(in lines: [String]) -> String? { findStoreDetailed(in: lines).name }

    static func findStoreDetailed(in lines: [String]) -> (name: String?, confident: Bool) {
        let org = ["ООО", "ИП ", "АО ", "ЗАО", "ПАО", "ОАО", "МАГАЗИН", "ТЦ ", "ТК ", "ГИПЕРМАРКЕТ", "СУПЕРМАРКЕТ"]
        let skip = ["ЧЕК", "КАССОВЫЙ", "ДОБРО ПОЖАЛОВАТЬ", "ТОВАРНЫЙ", "ПРИХОД", "КАССИР", "СМЕНА", "ИНН", "ДАТА", "WWW", "HTTP", "ТЕЛ"]
        let head = Array(lines.prefix(10))
        func letters(_ s: String) -> Int { s.filter { $0.isLetter }.count }
        func clean(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:*-_=")) }
        // 1) строка с «ООО/ИП/…»
        if let l = head.first(where: { line in
            let u = line.uppercased(); return org.contains(where: { u.hasPrefix($0) || u.contains(" " + $0) }) && letters(line) >= 4
        }) { return (clean(l), true) }
        // 2) первая осмысленная строка — название менее надёжно, его стоит проверить
        if let l = head.first(where: { line in
            let u = line.uppercased()
            return letters(line) >= 3 && !skip.contains(where: { u.contains($0) }) && !amountMatch(line)
        }) { return (clean(l), false) }
        return (nil, false)
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
        let t = findTotalDetailed(in: lines)
        return (t.kop, t.index)
    }

    private static func letterCount(_ s: String) -> Int { s.filter { $0.isLetter }.count }

    /// Итог чека. Приоритет: «К ОПЛАТЕ» → «ИТОГО/ИТОГ» → «ВСЕГО/СУММА» → строки об оплате → наибольшая сумма (ненадёжно).
    /// Промежуточные суммы (НДС, скидка, подытог, сдача, полученные деньги) игнорируются.
    static func findTotalDetailed(in lines: [String]) -> (kop: Int64?, index: Int, tier: Int) {
        struct Candidate { var kop: Int64; var index: Int; var tier: Int }
        var cands: [Candidate] = []

        func amountsNear(_ i: Int) -> [Int64] {
            var found = amounts(in: lines[i]).map { $0.kop }
            if found.isEmpty, i + 1 < lines.count, letterCount(lines[i + 1]) <= 4 { found = amounts(in: lines[i + 1]).map { $0.kop } }
            if found.isEmpty {
                // «ИТОГО 1000 00» — копейки отделены пробелом
                let ns = lines[i] as NSString
                if let re = try? NSRegularExpression(pattern: #"(?<![\d.,])(\d{1,6})[ ]+(\d{2})\s*[₽РрRr]?\s*$"#),
                   let m = re.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)),
                   let w = Int64(ns.substring(with: m.range(at: 1))), let f = Int64(ns.substring(with: m.range(at: 2))) {
                    found = [w * 100 + f]
                }
            }
            return found
        }

        let excluded = ["НДС", "ПОДЫТОГ", "ПРОМЕЖУТОЧ", "СДАЧА", "ПОЛУЧЕНО", "ВНЕСЕНО", "ОКРУГЛ", "БОНУС", "БАЛЛ", "ЭКОНОМ", "АВАНС"]
        for (i, line) in lines.enumerated() {
            let u = line.uppercased()
            if excluded.contains(where: { u.contains($0) }) { continue }
            if u.contains("СКИДК") && !(u.contains("СО СКИДК") || u.contains("С УЧЕТОМ") || u.contains("С УЧЁТОМ")) { continue }
            var tier = -1
            if u.contains("К ОПЛАТЕ") { tier = 0 }
            else if u.contains("ИТОГО") || u.contains("ИТОГ ") || u.hasSuffix("ИТОГ") || u.contains("TOTAL") { tier = 1 }
            else if u.contains("ВСЕГО") || u.contains("СУММА") { tier = 2 }
            else if u.contains("НАЛИЧН") || u.contains("ЭЛЕКТРОН") || u.contains("БЕЗНАЛ") || u.contains("КАРТОЙ") { tier = 3 }
            guard tier >= 0 else { continue }
            if let v = amountsNear(i).last, v > 0 { cands.append(Candidate(kop: v, index: i, tier: tier)) }
        }

        if let bestTier = cands.map({ $0.tier }).min() {
            let group = cands.filter { $0.tier == bestTier }
            // если несколько — выбираем то, что подтверждается другими строками (ИТОГО = НАЛИЧНЫМИ), иначе последнее
            let chosen = group.first(where: { g in cands.contains(where: { $0.tier != g.tier && $0.kop == g.kop }) }) ?? group.last!
            let firstKeywordIndex = cands.filter { $0.tier <= 1 }.map { $0.index }.min() ?? chosen.index
            return (chosen.kop, bestTier <= 1 ? firstKeywordIndex : chosen.index, bestTier)
        }
        // запасной вариант: наибольшая сумма в документе — ненадёжно
        var maxV: Int64 = 0, maxI = lines.count
        for (i, line) in lines.enumerated() {
            for a in amounts(in: line) where a.kop > maxV { maxV = a.kop; maxI = i }
        }
        return maxV > 0 ? (maxV, maxI, 9) : (nil, lines.count, 9)
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

import Foundation

/// Деньги хранятся в копейках (Int64), чтобы не накапливать ошибок округления.
enum Money {
    private static func makeFormatter(fraction: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = "\u{00A0}"
        f.decimalSeparator = ","
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        return f
    }
    private static let whole = makeFormatter(fraction: 0)
    private static let cents = makeFormatter(fraction: 2)

    /// «18 500 ₽» или «18 500,50 ₽»
    static func format(_ kop: Int64, symbol: Bool = true) -> String {
        let negative = kop < 0
        let absKop = kop.magnitude
        let value = NSDecimalNumber(value: absKop).dividing(by: 100)
        let f = absKop % 100 == 0 ? whole : cents
        var s = f.string(from: value) ?? "\(absKop / 100)"
        if negative { s = "−" + s }
        return symbol ? s + "\u{00A0}₽" : s
    }

    /// Разбирает ввод пользователя: «18500», «18 500,50», «1 200.5 руб».
    static func parse(_ text: String) -> Int64? {
        var allowed = ""
        for ch in text {
            if ch.isNumber || ch == "," || ch == "." || ch == "-" || ch == "−" { allowed.append(ch == "−" ? "-" : ch) }
        }
        allowed = allowed.replacingOccurrences(of: ",", with: ".")
        guard !allowed.isEmpty else { return nil }
        // несколько точек: последняя — десятичная
        let parts = allowed.split(separator: ".", omittingEmptySubsequences: false)
        var normalized = allowed
        if parts.count > 2 {
            normalized = parts.dropLast().joined() + "." + parts.last!
        }
        guard let dec = Decimal(string: normalized) else { return nil }
        var scaled = dec * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func double(_ kop: Int64) -> Double { Double(kop) / 100.0 }

    /// Приводит ввод к виду «1 234 567,50»: только цифры, не более двух знаков после запятой, пробелы между тысячами.
    static func formatInput(_ text: String) -> String {
        var intPart = "", frac = ""
        var hasSeparator = false
        for ch in text {
            if ch.isASCII && ch.isNumber {
                if hasSeparator { if frac.count < 2 { frac.append(ch) } } else { intPart.append(ch) }
            } else if (ch == "," || ch == ".") && !hasSeparator {
                hasSeparator = true
            }
        }
        while intPart.count > 1 && intPart.hasPrefix("0") { intPart.removeFirst() }
        var grouped = ""
        for (i, ch) in intPart.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { grouped.append(" ") }
            grouped.append(ch)
        }
        grouped = String(grouped.reversed())
        if hasSeparator { return (grouped.isEmpty ? "0" : grouped) + "," + frac }
        return grouped
    }

    /// Строка для поля ввода: «18500» или «18500,5»
    static func editString(_ kop: Int64) -> String {
        if kop == 0 { return "" }
        if kop % 100 == 0 { return String(kop / 100) }
        return String(format: "%.2f", Double(kop) / 100).replacingOccurrences(of: ".", with: ",")
    }
}

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "dd.MM.yyyy"; return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "dd.MM.yyyy HH:mm"; return f
    }()
    /// «8 ноября 2026» — заголовки дней в списке покупок
    static let dayHeader: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy"; return f
    }()
    static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM"; return f
    }()
    static func number(_ n: Int32) -> String { String(format: "№%03d", Int(n)) }
    static func fileSafe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Отчёт" : cleaned
    }
}

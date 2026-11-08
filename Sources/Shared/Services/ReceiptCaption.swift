import Foundation

/// Заголовок чека для PDF и Excel: номер · дата · магазин · наименование(я) · сумма чека.
/// Наименования берутся из товарных позиций чека; пустые не выводятся, ничего не выдумывается, сумма — общая по чеку.
enum ReceiptCaption {
    /// До скольких наименований перечисляем полностью; если позиций больше — первые несколько и «и ещё N позиций».
    static let fullListLimit = 3
    static let shownWhenTruncated = 3

    static func names(_ rec: ReportSnapshot.Receipt) -> [String] {
        rec.items.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// «Сумка, контейнеры» или «a, b, c, d и ещё 3 позиции»; пустая строка, если названий нет.
    static func nameList(_ rec: ReportSnapshot.Receipt) -> String {
        let all = names(rec)
        if all.count <= fullListLimit { return all.joined(separator: ", ") }
        let rest = all.count - shownWhenTruncated
        return all.prefix(shownWhenTruncated).joined(separator: ", ") + " и ещё \(rest) \(plural(rest))"
    }

    static func plural(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "позиция" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "позиции" }
        return "позиций"
    }

    /// Одна строка, если наименование одно (или нет), две — если позиций несколько: сначала «Чек · дата · магазин», затем «названия · сумма».
    static func lines(_ rec: ReportSnapshot.Receipt, photoIndex: Int? = nil, photoCount: Int = 1) -> [String] {
        let store = rec.store.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = ["Чек №\(String(format: "%03d", rec.number))", Fmt.date.string(from: rec.date), store.isEmpty ? "магазин не указан" : store]
        let sum = Money.format(rec.total)
        var out: [String]
        if names(rec).count > 1 {
            out = [head.joined(separator: " · "), [nameList(rec), sum].joined(separator: " · ")]
        } else {
            out = [(head + names(rec) + [sum]).joined(separator: " · ")]
        }
        if let i = photoIndex, photoCount > 1 { out[out.count - 1] += " · фото \(i + 1) из \(photoCount)" }
        return out
    }

    /// Перенос длинной строки по словам для ячеек Excel (ширина в символах).
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = [], current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty { current = String(word) }
            else if current.count + 1 + word.count <= width { current += " " + word }
            else { lines.append(current); current = String(word) }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }
}

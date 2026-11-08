import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// PDF-версия отчёта (A4, альбомная ориентация): сводка, 1) выдачи денег, 2) покупки, 3) возвраты, 4) финансовый итог,
/// реестр чеков и фотографии чеков. Нумерация страниц «стр. X из Y», дата формирования в колонтитуле.
final class PDFBuilder {
    private let pageW: CGFloat = 842, pageH: CGFloat = 595
    private let margin: CGFloat = 36
    private let data = NSMutableData()
    private var ctx: CGContext!
    private var y: CGFloat = 0   // от верхнего края страницы
    private var pageNo = 0
    private let snapshot: ReportSnapshot
    private var totalPages = 0      // известно после пробного прохода
    private var dry = false         // пробный проход: считаем страницы, не рисуя фотографии

    private let ink = CGColor(red: 0.17, green: 0.18, blue: 0.21, alpha: 1)
    private let gray = CGColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)
    private let headerFill = CGColor(red: 0.23, green: 0.25, blue: 0.28, alpha: 1)
    private let lightFill = CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    private let line = CGColor(red: 0.82, green: 0.83, blue: 0.85, alpha: 1)
    private let red = CGColor(red: 0.75, green: 0.22, blue: 0.17, alpha: 1)

    init(snapshot: ReportSnapshot) { self.snapshot = snapshot }

    /// Два прохода: первый считает число страниц (для «стр. X из Y»), второй рисует документ.
    static func build(_ s: ReportSnapshot) -> Data {
        let probe = PDFBuilder(snapshot: s)
        probe.dry = true
        _ = probe.render()
        let real = PDFBuilder(snapshot: s)
        real.totalPages = probe.pageNo
        return real.render()
    }

    // MARK: - Текст

    private func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    private func attributed(_ text: String, size: CGFloat, bold: Bool = false, color: CGColor? = nil, align: CTTextAlignment = .left) -> NSAttributedString {
        var alignment = align
        let paragraph = withUnsafePointer(to: &alignment) { ptr -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr)
            return CTParagraphStyleCreate(&setting, 1)
        }
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color ?? ink,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
    }

    private func textHeight(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        let fs = CTFramesetterCreateWithAttributedString(s)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height)
    }

    /// Рисует текст в прямоугольнике, заданном от верхнего края страницы.
    private func draw(_ s: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) {
        let rect = CGRect(x: x, y: pageH - top - height, width: width, height: height)
        let path = CGPath(rect: rect, transform: nil)
        let fs = CTFramesetterCreateWithAttributedString(s)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
    }

    private func fillRect(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: x, y: pageH - top - h, width: w, height: h))
    }
    private func hLine(top: CGFloat, x1: CGFloat, x2: CGFloat) {
        ctx.setStrokeColor(line); ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: x1, y: pageH - top)); ctx.addLine(to: CGPoint(x: x2, y: pageH - top)); ctx.strokePath()
    }

    // MARK: - Страницы

    private func newPage() {
        if pageNo > 0 { footer(); ctx.endPDFPage() }
        pageNo += 1
        ctx.beginPDFPage(nil)
        y = margin
    }

    private func footer() {
        let pages = totalPages > 0 ? " из \(totalPages)" : ""
        let s = attributed("Реквизит · \(snapshot.projectName) · сформирован \(Fmt.dateTime.string(from: snapshot.generatedAt)) · стр. \(pageNo)\(pages)", size: 8, color: gray)
        draw(s, x: margin, top: pageH - 26, width: pageW - margin * 2, height: 12)
    }

    private func ensure(_ h: CGFloat) { if y + h > pageH - 40 { newPage() } }

    private func render() -> Data {
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Финансовый отчёт — \(snapshot.projectName)", kCGPDFContextCreator: "Реквизит"]
        guard let consumer = CGDataConsumer(data: data), let c = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        ctx = c
        newPage()
        summaryPage()
        issuesSection()
        purchasesSection()
        returnsSection()
        totalsSection()
        registry()
        photoPages()
        footer()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private func summaryPage() {
        let w = pageW - margin * 2
        let title = attributed("ФИНАНСОВЫЙ ОТЧЁТ ПО ПОДОТЧЁТНЫМ СРЕДСТВАМ", size: 18, bold: true)
        draw(title, x: margin, top: y, width: w, height: 26); y += 34
        func pair(_ l: String, _ v: String) {
            draw(attributed(l, size: 11, color: gray), x: margin, top: y, width: 190, height: 16)
            draw(attributed(v, size: 11, bold: true), x: margin + 190, top: y, width: w - 190, height: 16); y += 20
        }
        pair("Проект / фильм", snapshot.projectName)
        pair("Подотчётное лицо", snapshot.holder.isEmpty ? "—" : snapshot.holder)
        pair("Период", snapshot.periodText)
        pair("Сформирован", Fmt.dateTime.string(from: snapshot.generatedAt))
        y += 10

        // карточки
        let cards: [(String, String, CGColor?)] = [
            ("Выдано", Money.format(snapshot.issued), nil), ("Потрачено", Money.format(snapshot.spent), nil),
            ("Возвращено", Money.format(snapshot.returned), nil),
            (snapshot.balance < 0 ? "Перерасход" : "Остаток", Money.format(snapshot.balance), snapshot.balance < 0 ? red : nil)
        ]
        let cw = (w - 3 * 12) / 4
        for (i, cd) in cards.enumerated() {
            let x = margin + CGFloat(i) * (cw + 12)
            fillRect(x: x, top: y, w: cw, h: 62, color: lightFill)
            draw(attributed(cd.0, size: 10, color: gray), x: x + 12, top: y + 10, width: cw - 24, height: 14)
            draw(attributed(cd.1, size: 17, bold: true, color: cd.2), x: x + 12, top: y + 30, width: cw - 24, height: 24)
        }
        y += 78
        draw(attributed("Покупок: \(snapshot.purchaseCount)   ·   Чеков: \(snapshot.receiptCount)   ·   Покупок без чека: \(snapshot.noReceiptCount)", size: 11),
             x: margin, top: y, width: w, height: 16)
        y += 30
        if !snapshot.categories.isEmpty {
            draw(attributed("Расходы по категориям", size: 12, bold: true), x: margin, top: y, width: w, height: 18); y += 22
            for c in snapshot.categories.prefix(14) {
                ensure(18)
                draw(attributed(c.name, size: 10), x: margin, top: y, width: 300, height: 14)
                draw(attributed(Money.format(c.amount), size: 10, align: .right), x: margin + 300, top: y, width: 120, height: 14)
                hLine(top: y + 15, x1: margin, x2: margin + 420)
                y += 18
            }
        }
    }

    private func table(title: String, columns: [(String, CGFloat, CTTextAlignment)], rows: [[String]], totalRow: [String]? = nil, startOnNewPage: Bool = true) {
        if startOnNewPage { newPage() } else {
            y += 14
            ensure(90)   // заголовок раздела, шапка и хотя бы одна строка — на одной странице
        }
        draw(attributed(title, size: 14, bold: true), x: margin, top: y, width: pageW - margin * 2, height: 20); y += 28
        let total = columns.reduce(0) { $0 + $1.1 }
        let scale = (pageW - margin * 2) / total
        let widths = columns.map { $0.1 * scale }
        func header() {
            fillRect(x: margin, top: y, w: pageW - margin * 2, h: 22, color: headerFill)
            var x = margin
            for (i, c) in columns.enumerated() {
                draw(attributed(c.0, size: 9, bold: true, color: CGColor(gray: 1, alpha: 1), align: c.2), x: x + 4, top: y + 6, width: widths[i] - 8, height: 12)
                x += widths[i]
            }
            y += 22
        }
        header()
        func drawRow(_ cells: [String], bold: Bool, fill: CGColor?) {
            let attrs = cells.enumerated().map { attributed($1, size: 9, bold: bold, align: columns[$0].2) }
            var h: CGFloat = 16
            for (i, a) in attrs.enumerated() { h = max(h, textHeight(a, width: widths[i] - 8) + 8) }
            if y + h > pageH - 40 { newPage(); header() }
            if let f = fill { fillRect(x: margin, top: y, w: pageW - margin * 2, h: h, color: f) }
            var x = margin
            for (i, a) in attrs.enumerated() { draw(a, x: x + 4, top: y + 4, width: widths[i] - 8, height: h - 4); x += widths[i] }
            hLine(top: y + h, x1: margin, x2: pageW - margin)
            y += h
        }
        for r in rows { drawRow(r, bold: false, fill: nil) }
        if let t = totalRow { drawRow(t, bold: true, fill: lightFill) }
    }

    // MARK: Разделы выписки

    private func issuesSection() {
        let issues = snapshot.advances.filter { $0.kind == 0 }.sorted { $0.date < $1.date }
        let rows = issues.enumerated().map { i, a in
            ["\(i + 1)", Fmt.date.string(from: a.date), Money.format(a.amount), a.note.isEmpty ? "—" : a.note]
        }
        let total = issues.reduce(Int64(0)) { $0 + $1.amount }
        table(title: "1. Выдача денег",
              columns: [("№", 30, .center), ("Дата", 80, .left), ("Сумма", 110, .right), ("Назначение", 420, .left)],
              rows: rows.isEmpty ? [["—", "—", "—", "Выдач за период нет"]] : rows,
              totalRow: ["", "ИТОГО", Money.format(total), ""], startOnNewPage: false)
    }

    private func purchasesSection() {
        var flat: [(rec: ReportSnapshot.Receipt, item: ReportSnapshot.Item)] = []
        for rec in snapshot.receipts.sorted(by: { ($0.date, $0.number) < ($1.date, $1.number) }) {
            for it in rec.items { flat.append((rec, it)) }
        }
        let rows = flat.map { f in
            [String(format: "%03d", f.rec.number), Fmt.date.string(from: f.rec.date), f.rec.store.isEmpty ? "—" : f.rec.store,
             f.item.title.isEmpty ? "—" : f.item.title, f.item.category, f.item.scenes.isEmpty ? "—" : f.item.scenes, Money.format(f.item.amount)]
        }
        let total = flat.reduce(Int64(0)) { $0 + $1.item.amount }
        table(title: "2. Покупки",
              columns: [("№", 36, .center), ("Дата", 62, .left), ("Магазин", 120, .left), ("Наименование", 210, .left),
                        ("Категория", 110, .left), ("Сцена", 60, .left), ("Сумма", 80, .right)],
              rows: rows.isEmpty ? [["—", "—", "—", "Покупок за период нет", "", "", ""]] : rows,
              totalRow: ["", "", "", "ИТОГО", "", "", Money.format(total)], startOnNewPage: false)
    }

    private func returnsSection() {
        let returns = snapshot.advances.filter { $0.kind == 1 }.sorted { $0.date < $1.date }
        let rows = returns.enumerated().map { i, a in
            ["\(i + 1)", Fmt.date.string(from: a.date), Money.format(a.amount), a.note.isEmpty ? "—" : a.note]
        }
        let total = returns.reduce(Int64(0)) { $0 + $1.amount }
        table(title: "3. Возвраты",
              columns: [("№", 30, .center), ("Дата", 80, .left), ("Сумма", 110, .right), ("Комментарий", 420, .left)],
              rows: rows.isEmpty ? [["—", "—", "—", "Возвратов не было"]] : rows,
              totalRow: ["", "ИТОГО", Money.format(total), ""], startOnNewPage: false)
    }

    private func totalsSection() {
        let balanceTitle = snapshot.balance < 0 ? "Перерасход (потрачено больше, чем выдано)" : "Остаток (выдано − потрачено − возвращено)"
        let rows: [[String]] = [
            ["Всего выдано", Money.format(snapshot.issued)],
            ["Всего потрачено", Money.format(snapshot.spent)],
            ["Всего возвращено", Money.format(snapshot.returned)],
            [balanceTitle, Money.format(snapshot.balance)],
            ["Количество чеков", "\(snapshot.receiptCount)"],
            ["Количество покупок без чека", "\(snapshot.noReceiptCount)"],
            ["Количество покупок (позиций)", "\(snapshot.purchaseCount)"]
        ]
        table(title: "4. Финансовый итог",
              columns: [("Показатель", 420, .left), ("Значение", 200, .right)], rows: rows, startOnNewPage: false)
    }

    private func registry() {
        let rows = snapshot.receipts.map { r in
            [String(format: "%03d", r.number), Fmt.date.string(from: r.date), r.store.isEmpty ? "—" : r.store,
             Money.format(r.total), "\(r.items.count)", r.noReceipt ? "Без чека" : (r.photos.isEmpty ? "Нет" : "Да")]
        }
        table(title: "Реестр чеков",
              columns: [("№ чека", 50, .center), ("Дата", 70, .left), ("Магазин", 280, .left), ("Сумма", 90, .right), ("Позиций", 60, .center), ("Оригинал", 80, .center)],
              rows: rows, totalRow: ["", "", "ИТОГО", Money.format(snapshot.spent), "\(snapshot.purchaseCount)", ""])
    }

    private func photoPages() {
        for rec in snapshot.receipts {
            for (i, im) in rec.photos.enumerated() {
                newPage()
                // заголовок чека: номер · дата · магазин · наименование(я) · сумма; длинное переносится, размер шрифта не уменьшается
                for line in ReceiptCaption.lines(rec, photoIndex: i, photoCount: rec.photos.count) {
                    let text = attributed(line, size: 11, bold: true)
                    let h = textHeight(text, width: pageW - margin * 2)
                    draw(text, x: margin, top: y, width: pageW - margin * 2, height: h + 2)
                    y += h + 3
                }
                y += 8
                if dry { continue }
                guard let src = CGImageSourceCreateWithData(im.data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let availW = pageW - margin * 2, availH = pageH - y - 44
                let scale = min(availW / CGFloat(cg.width), availH / CGFloat(cg.height))
                let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
                ctx.draw(cg, in: CGRect(x: (pageW - w) / 2, y: pageH - y - h, width: w, height: h))
            }
        }
    }
}

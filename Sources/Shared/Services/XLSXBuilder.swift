import Foundation

/// Собирает настоящий .xlsx (Office Open XML) с фотографиями, физически вложенными в файл (xl/media/*).
/// Открывается в Excel, Numbers, LibreOffice. Внешних библиотек не требуется.
enum XLSXBuilder {
    // Индексы стилей (см. styles())
    private enum S {
        static let normal = 0, title = 1, header = 2, text = 3, money = 4, date = 5, label = 6, moneyBold = 7, center = 8
        static let totalText = 9, totalMoney = 10, int = 11, subtitle = 12, moneyPlain = 13, overspend = 14, plainWrap = 15
        static let sectionHeader = 16, dateBordered = 5
    }

    // MARK: - Вспомогательные типы

    private final class Sheet {
        struct Row { var height: Double?; var cells: [Int: String] = [:] }
        var rows: [Int: Row] = [:]
        var merges: [String] = []
        var widths: [Double] = []
        var freezeAfterRow: Int?
        var hasDrawing = false
        var landscape = true

        static func col(_ i: Int) -> String {
            var n = i, s = ""
            while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
            return s
        }
        func ref(_ r: Int, _ c: Int) -> String { "\(Sheet.col(c))\(r)" }
        func put(_ r: Int, _ c: Int, _ xml: String) { rows[r, default: Row()].cells[c] = xml }
        func text(_ r: Int, _ c: Int, _ s: String, _ style: Int) {
            put(r, c, "<c r=\"\(ref(r, c))\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(s))</t></is></c>")
        }
        func number(_ r: Int, _ c: Int, _ v: Double, _ style: Int) {
            put(r, c, "<c r=\"\(ref(r, c))\" s=\"\(style)\"><v>\(fmt(v))</v></c>")
        }
        func formula(_ r: Int, _ c: Int, _ f: String, cached: Double, _ style: Int) {
            put(r, c, "<c r=\"\(ref(r, c))\" s=\"\(style)\"><f>\(esc(f))</f><v>\(fmt(cached))</v></c>")
        }
        func blank(_ r: Int, _ c: Int, _ style: Int) { put(r, c, "<c r=\"\(ref(r, c))\" s=\"\(style)\"/>") }
        func height(_ r: Int, _ pt: Double) { rows[r, default: Row()].height = min(pt, 409) }
        func merge(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) { merges.append("\(ref(r1, c1)):\(ref(r2, c2))") }

        func xml() -> String {
            var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            x += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            x += "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr>"
            let maxRow = rows.keys.max() ?? 1
            let maxCol = max(widths.count, rows.values.flatMap { $0.cells.keys }.max() ?? 1)
            x += "<dimension ref=\"A1:\(ref(maxRow, maxCol))\"/>"
            x += "<sheetViews><sheetView workbookViewId=\"0\" showGridLines=\"0\">"
            if let f = freezeAfterRow {
                x += "<pane ySplit=\"\(f)\" topLeftCell=\"A\(f + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/><selection pane=\"bottomLeft\"/>"
            }
            x += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"18\"/>"
            if !widths.isEmpty {
                x += "<cols>"
                for (i, w) in widths.enumerated() { x += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(fmt(w))\" customWidth=\"1\"/>" }
                x += "</cols>"
            }
            x += "<sheetData>"
            for r in rows.keys.sorted() {
                let row = rows[r]!
                x += "<row r=\"\(r)\""
                if let h = row.height { x += " ht=\"\(fmt(h))\" customHeight=\"1\"" }
                x += ">"
                for c in row.cells.keys.sorted() { x += row.cells[c]! }
                x += "</row>"
            }
            x += "</sheetData>"
            if !merges.isEmpty {
                x += "<mergeCells count=\"\(merges.count)\">" + merges.map { "<mergeCell ref=\"\($0)\"/>" }.joined() + "</mergeCells>"
            }
            x += "<pageMargins left=\"0.4\" right=\"0.4\" top=\"0.5\" bottom=\"0.5\" header=\"0.3\" footer=\"0.3\"/>"
            x += "<pageSetup paperSize=\"9\" orientation=\"\(landscape ? "landscape" : "portrait")\" fitToWidth=\"1\" fitToHeight=\"0\"/>"
            if hasDrawing { x += "<drawing r:id=\"rId1\"/>" }
            x += "</worksheet>"
            return x
        }
    }

    private struct Picture {
        var mediaIndex: Int
        var col0: Int          // 0-based
        var row0: Int          // 0-based
        var colOff: Int        // EMU
        var rowOff: Int        // EMU
        var cx: Int
        var cy: Int
        var name: String
    }

    // MARK: - Публичный API

    static func build(_ s: ReportSnapshot) -> Data {
        var zip = ZipWriter()
        var media: [Data] = []

        let summary = Sheet()
        buildSummary(summary, s)

        let detail = Sheet()
        var detailPics: [Picture] = []
        buildDetail(detail, s, &detailPics, &media)
        detail.hasDrawing = !detailPics.isEmpty

        let registry = Sheet()
        buildRegistry(registry, s)

        let photos = Sheet()
        var photoPics: [Picture] = []
        buildPhotos(photos, s, &photoPics, &media)
        photos.hasDrawing = !photoPics.isEmpty

        let sheets: [(String, Sheet, [Picture])] = [
            ("Сводный отчёт", summary, []),
            ("Детализация расходов", detail, detailPics),
            ("Реестр чеков", registry, []),
            ("Фотографии чеков", photos, photoPics)
        ]

        // [Content_Types].xml
        var ct = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        ct += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        ct += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        ct += "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>"
        ct += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        ct += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in 1...sheets.count {
            ct += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        var drawingNo = 0
        var drawingForSheet: [Int: Int] = [:]
        for (i, sh) in sheets.enumerated() where !sh.2.isEmpty {
            drawingNo += 1
            drawingForSheet[i] = drawingNo
            ct += "<Override PartName=\"/xl/drawings/drawing\(drawingNo).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"
        }
        ct += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        ct += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        ct += "</Types>"
        zip.add(name: "[Content_Types].xml", string: ct)

        zip.add(name: "_rels/.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)

        let iso = ISO8601DateFormatter().string(from: s.generatedAt)
        zip.add(name: "docProps/core.xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>\(esc("Финансовый отчёт — " + s.projectName))</dc:title><dc:creator>\(esc(s.holder.isEmpty ? "Реквизит" : s.holder))</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">\(iso)</dcterms:created></cp:coreProperties>")
        zip.add(name: "docProps/app.xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>Реквизит</Application></Properties>")

        var wb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><bookViews><workbookView xWindow=\"0\" yWindow=\"0\" windowWidth=\"24000\" windowHeight=\"14000\"/></bookViews><sheets>"
        for (i, sh) in sheets.enumerated() { wb += "<sheet name=\"\(esc(sh.0))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>" }
        wb += "</sheets></workbook>"
        zip.add(name: "xl/workbook.xml", string: wb)

        var wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...sheets.count {
            wbRels += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        wbRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
        zip.add(name: "xl/_rels/workbook.xml.rels", string: wbRels)
        zip.add(name: "xl/styles.xml", string: styles())

        for (i, sh) in sheets.enumerated() {
            zip.add(name: "xl/worksheets/sheet\(i + 1).xml", string: sh.1.xml())
            if let d = drawingForSheet[i] {
                zip.add(name: "xl/worksheets/_rels/sheet\(i + 1).xml.rels", string: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing\" Target=\"../drawings/drawing\(d).xml\"/></Relationships>")
                let pics = sh.2
                var dx = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
                var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                for (k, p) in pics.enumerated() {
                    let rid = "rId\(k + 1)"
                    rels += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/image\(p.mediaIndex).jpeg\"/>"
                    dx += "<xdr:oneCellAnchor><xdr:from><xdr:col>\(p.col0)</xdr:col><xdr:colOff>\(p.colOff)</xdr:colOff><xdr:row>\(p.row0)</xdr:row><xdr:rowOff>\(p.rowOff)</xdr:rowOff></xdr:from><xdr:ext cx=\"\(p.cx)\" cy=\"\(p.cy)\"/>"
                    dx += "<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"\(k + 2)\" name=\"\(esc(p.name))\" descr=\"\(esc(p.name))\"/><xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr></xdr:nvPicPr>"
                    dx += "<xdr:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>"
                    dx += "<xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(p.cx)\" cy=\"\(p.cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>"
                }
                dx += "</xdr:wsDr>"
                rels += "</Relationships>"
                zip.add(name: "xl/drawings/drawing\(d).xml", string: dx)
                zip.add(name: "xl/drawings/_rels/drawing\(d).xml.rels", string: rels)
            }
        }
        for (i, m) in media.enumerated() { zip.add(name: "xl/media/image\(i + 1).jpeg", data: m) }
        return zip.finish()
    }

    // MARK: - Лист 1. Сводный отчёт

    private static func buildSummary(_ sh: Sheet, _ s: ReportSnapshot) {
        sh.widths = [36, 24, 20, 44]
        sh.landscape = false
        sh.text(1, 1, "ФИНАНСОВЫЙ ОТЧЁТ ПО ПОДОТЧЁТНЫМ СРЕДСТВАМ", S.title); sh.merge(1, 1, 1, 4); sh.height(1, 30)
        var r = 3
        func pair(_ label: String, _ value: String) {
            sh.text(r, 1, label, S.label); sh.text(r, 2, value, S.plainWrap); sh.merge(r, 2, r, 4); r += 1
        }
        pair("Проект / фильм", s.projectName)
        pair("Подотчётное лицо", s.holder.isEmpty ? "—" : s.holder)
        pair("Период отчёта", s.periodText)
        pair("Дата формирования", Fmt.dateTime.string(from: s.generatedAt))
        r += 1
        sh.text(r, 1, "ДВИЖЕНИЕ ДЕНЕЖНЫХ СРЕДСТВ", S.sectionHeader); sh.blank(r, 2, S.sectionHeader); r += 1
        func money(_ label: String, _ kop: Int64, style: Int = S.money) {
            sh.text(r, 1, label, S.text); sh.number(r, 2, Money.double(kop), style); r += 1
        }
        money("Получено подотчётных средств", s.issued)
        money("Возвращено неиспользованных средств", s.returned)
        money("Общая сумма расходов", s.spent)
        let balanceLabel = s.balance < 0 ? "ПЕРЕРАСХОД (остаток отрицательный)" : "ОСТАТОК"
        sh.text(r, 1, balanceLabel, S.totalText); sh.number(r, 2, Money.double(s.balance), s.balance < 0 ? S.overspend : S.totalMoney); r += 1
        r += 1
        sh.text(r, 1, "Количество покупок", S.text); sh.number(r, 2, Double(s.purchaseCount), S.int); r += 1
        sh.text(r, 1, "Количество чеков", S.text); sh.number(r, 2, Double(s.receiptCount), S.int); r += 1
        sh.text(r, 1, "Покупок без чека", S.text); sh.number(r, 2, Double(s.noReceiptCount), S.int); r += 2

        if !s.categories.isEmpty {
            sh.text(r, 1, "РАСХОДЫ ПО КАТЕГОРИЯМ", S.sectionHeader); sh.blank(r, 2, S.sectionHeader); r += 1
            let first = r
            for c in s.categories { sh.text(r, 1, c.name, S.text); sh.number(r, 2, Money.double(c.amount), S.money); r += 1 }
            sh.text(r, 1, "Итого", S.totalText)
            sh.formula(r, 2, "SUM(B\(first):B\(r - 1))", cached: Money.double(s.categories.reduce(0) { $0 + $1.amount }), S.totalMoney)
            r += 2
        }
        if !s.advances.isEmpty {
            sh.text(r, 1, "ВЫДАЧИ И ВОЗВРАТЫ", S.sectionHeader)
            for c in 2...4 { sh.blank(r, c, S.sectionHeader) }
            r += 1
            for (i, h) in ["Дата", "Операция", "Сумма", "Примечание"].enumerated() { sh.text(r, i + 1, h, S.header) }
            r += 1
            for a in s.advances {
                sh.number(r, 1, serial(a.date), S.date)
                sh.text(r, 2, a.kind == 0 ? "Выдача" : "Возврат", S.text)
                sh.number(r, 3, Money.double(a.amount), S.money)
                sh.text(r, 4, a.note, S.text)
                r += 1
            }
            r += 1
        }
        r += 1
        sh.text(r, 1, "Подотчётное лицо: ______________________ / \(s.holder)", S.normal); r += 2
        sh.text(r, 1, "Отчёт принял: ______________________ / ______________", S.normal)
    }

    // MARK: - Лист 2. Детализация расходов

    private static let detailPhotoBoxW = 240.0   // px, ширина колонки «Фото чека»

    private static func buildDetail(_ sh: Sheet, _ s: ReportSnapshot, _ pics: inout [Picture], _ media: inout [Data]) {
        sh.widths = [6, 12, 36, 20, 14, 24, 15, 9, 36, 42]
        sh.text(1, 1, "ДЕТАЛИЗАЦИЯ РАСХОДОВ — \(s.projectName)", S.title); sh.merge(1, 1, 1, 10); sh.height(1, 28)
        sh.text(2, 1, "Подотчётное лицо: \(s.holder.isEmpty ? "—" : s.holder)  ·  Период: \(s.periodText)", S.subtitle); sh.merge(2, 1, 2, 10)
        let headers = ["№", "Дата", "Наименование", "Категория", "Сцена", "Магазин", "Сумма", "№ чека", "Фото чека", "Комментарий"]
        for (i, h) in headers.enumerated() { sh.text(4, i + 1, h, S.header) }
        sh.height(4, 30)
        sh.freezeAfterRow = 4

        var r = 5
        var n = 1
        let firstDataRow = r
        for rec in s.receipts {
            let count = max(rec.items.count, 1)
            let startRow = r
            var img: ImageTools.ReportImage? = rec.photos.first
            var boxW = detailPhotoBoxW, boxH = 0.0
            if let im = img {
                let maxH = min(520.0, Double(count) * 409.0 / 0.75 - 10)
                let scale = min(boxW / Double(im.width), maxH / Double(im.height), 1.0 * 4)
                boxW = Double(im.width) * scale; boxH = Double(im.height) * scale
            } else { img = nil }
            let photoHeightPt = boxH * 0.75 + 8
            let items = rec.items.isEmpty ? [ReportSnapshot.Item(title: "(без позиций)", category: "—", scenes: "", amount: 0, quantity: 1, purpose: "")] : rec.items
            for it in items {
                sh.number(r, 1, Double(n), S.int)
                sh.number(r, 2, serial(rec.date), S.date)
                sh.text(r, 3, it.quantity != 1 && it.quantity > 0 ? "\(it.title) (× \(trimQty(it.quantity)))" : it.title, S.text)
                sh.text(r, 4, it.category, S.text)
                sh.text(r, 5, it.scenes, S.text)
                sh.text(r, 6, rec.store, S.text)
                sh.number(r, 7, Money.double(it.amount), S.money)
                sh.number(r, 8, Double(rec.number), S.int)
                let comment = [it.purpose, rec.comment].filter { !$0.isEmpty }.joined(separator: "\n")
                sh.text(r, 10, comment, S.text)
                let lines = max(lineCount(it.title, width: 34), lineCount(comment, width: 40), lineCount(rec.store, width: 22), lineCount(it.category, width: 18))
                let textH = max(32.0, Double(lines) * 16.0 + 6)
                let photoShare = img != nil ? ceil(photoHeightPt / Double(items.count)) : 0
                sh.height(r, max(textH, photoShare))
                n += 1
                r += 1
            }
            // колонка «Фото чека»
            for rr in startRow..<r { sh.blank(rr, 9, S.center) }
            if let im = img {
                sh.merge(startRow, 9, r - 1, 9)
                media.append(im.data)
                pics.append(Picture(mediaIndex: media.count, col0: 8, row0: startRow - 1,
                                    colOff: Int(((detailPhotoBoxW - boxW) / 2 + 4) * 9525), rowOff: 4 * 9525,
                                    cx: Int(boxW * 9525), cy: Int(boxH * 9525), name: "Чек №\(rec.number)"))
                if rec.photos.count > 1 { sh.text(startRow, 9, "", S.center) }
            } else {
                sh.text(startRow, 9, rec.noReceipt ? "Без чека" : "Фото нет", S.center)
                if r - startRow > 1 { sh.merge(startRow, 9, r - 1, 9) }
            }
        }
        // итог
        let totalRow = r
        for c in 1...10 { sh.blank(totalRow, c, S.totalText) }
        sh.text(totalRow, 1, "ИТОГО", S.totalText); sh.merge(totalRow, 1, totalRow, 6)
        if r > firstDataRow {
            sh.formula(totalRow, 7, "SUM(G\(firstDataRow):G\(totalRow - 1))", cached: Money.double(s.spent), S.totalMoney)
        } else {
            sh.number(totalRow, 7, 0, S.totalMoney)
        }
        sh.height(totalRow, 26)
    }

    // MARK: - Лист 3. Реестр чеков

    private static func buildRegistry(_ sh: Sheet, _ s: ReportSnapshot) {
        sh.widths = [10, 12, 30, 16, 16, 11, 20, 12]
        sh.text(1, 1, "РЕЕСТР ЧЕКОВ — \(s.projectName)", S.title); sh.merge(1, 1, 1, 8); sh.height(1, 28)
        let headers = ["№ чека", "Дата", "Магазин", "ИНН", "Сумма чека", "Позиций", "Оригинал чека", "Фото, шт."]
        for (i, h) in headers.enumerated() { sh.text(3, i + 1, h, S.header) }
        sh.height(3, 28)
        sh.freezeAfterRow = 3
        var r = 4
        for rec in s.receipts {
            sh.number(r, 1, Double(rec.number), S.int)
            sh.number(r, 2, serial(rec.date), S.date)
            sh.text(r, 3, rec.store.isEmpty ? "—" : rec.store, S.text)
            sh.text(r, 4, rec.inn.isEmpty ? "—" : rec.inn, S.center)
            sh.number(r, 5, Money.double(rec.total), S.money)
            sh.number(r, 6, Double(rec.items.count), S.int)
            sh.text(r, 7, rec.noReceipt ? "Без чека" : (rec.photos.isEmpty ? "Нет" : "Да"), S.center)
            sh.number(r, 8, Double(rec.photos.count), S.int)
            sh.height(r, 22)
            r += 1
        }
        for c in 1...8 { sh.blank(r, c, S.totalText) }
        sh.text(r, 1, "ИТОГО", S.totalText); sh.merge(r, 1, r, 4)
        if r > 4 {
            sh.formula(r, 5, "SUM(E4:E\(r - 1))", cached: Money.double(s.spent), S.totalMoney)
            sh.formula(r, 6, "SUM(F4:F\(r - 1))", cached: Double(s.purchaseCount), S.int)
        }
        sh.height(r, 24)
    }

    // MARK: - Лист 4. Фотографии чеков

    private static func buildPhotos(_ sh: Sheet, _ s: ReportSnapshot, _ pics: inout [Picture], _ media: inout [Data]) {
        sh.widths = [2, 90]
        sh.landscape = false
        sh.text(1, 2, "ФОТОГРАФИИ ЧЕКОВ — \(s.projectName)", S.title); sh.height(1, 28)
        var r = 3
        let maxW = 640.0, maxH = 540.0
        for rec in s.receipts {
            for (i, im) in rec.photos.enumerated() {
                let scale = min(maxW / Double(im.width), maxH / Double(im.height), 4)
                let w = Double(im.width) * scale, h = Double(im.height) * scale
                sh.height(r, h * 0.75 + 8)
                media.append(im.data)
                pics.append(Picture(mediaIndex: media.count, col0: 1, row0: r - 1, colOff: 4 * 9525, rowOff: 4 * 9525,
                                    cx: Int(w * 9525), cy: Int(h * 9525), name: "Чек №\(rec.number), фото \(i + 1)"))
                r += 1
                var caption = "Чек №\(String(format: "%03d", rec.number))  ·  \(Fmt.date.string(from: rec.date))  ·  \(rec.store.isEmpty ? "магазин не указан" : rec.store)  ·  \(Money.format(rec.total))"
                if rec.photos.count > 1 { caption += "  ·  фото \(i + 1) из \(rec.photos.count)" }
                sh.text(r, 2, caption, S.label)
                sh.height(r, 22)
                r += 2
            }
        }
        if pics.isEmpty { sh.text(3, 2, "В отчёте нет прикреплённых фотографий чеков.", S.normal) }
    }

    // MARK: - Утилиты

    private static func lineCount(_ text: String, width: Int) -> Int {
        if text.isEmpty { return 1 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / Double(width)))) }
    }
    private static func trimQty(_ q: Double) -> String { q == q.rounded() ? String(Int(q)) : String(format: "%.3g", q) }

    static func serial(_ date: Date) -> Double {
        let local = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let d = utc.date(from: DateComponents(year: local.year, month: local.month, day: local.day))!
        let base = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        return (d.timeIntervalSince(base) / 86400).rounded()
    }

    private static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.2f", v)
    }

    private static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\u{9}", "\u{A}", "\u{D}": out.unicodeScalars.append(u)
            default:
                if u.value >= 0x20 && u.value != 0xFFFE && u.value != 0xFFFF && !(0xD800...0xDFFF).contains(u.value) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    private static func styles() -> String {
        func xf(_ numFmt: Int = 0, font: Int = 0, fill: Int = 0, border: Int = 0, h: String? = nil, wrap: Bool = false) -> String {
            var a = "<alignment vertical=\"center\""
            if let h = h { a += " horizontal=\"\(h)\"" }
            if wrap { a += " wrapText=\"1\"" }
            a += "/>"
            return "<xf numFmtId=\"\(numFmt)\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"\(border)\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\">\(a)</xf>"
        }
        let xfs = [
            xf(),                                                         // 0 normal
            xf(font: 2),                                                  // 1 title
            xf(font: 3, fill: 2, border: 1, h: "center", wrap: true),     // 2 header
            xf(border: 1, wrap: true),                                    // 3 text
            xf(164, border: 1, h: "right"),                               // 4 money
            xf(165, border: 1, h: "center"),                              // 5 date
            xf(font: 1),                                                  // 6 label
            xf(164, font: 1, h: "right"),                                 // 7 money bold plain
            xf(border: 1, h: "center", wrap: true),                       // 8 center
            xf(font: 1, fill: 3, border: 1, wrap: true),                  // 9 total text
            xf(164, font: 1, fill: 3, border: 1, h: "right"),             // 10 total money
            xf(1, border: 1, h: "center"),                                // 11 int
            xf(font: 4),                                                  // 12 subtitle
            xf(164, h: "right"),                                          // 13 money plain
            xf(164, font: 5, fill: 3, border: 1, h: "right"),             // 14 overspend
            xf(wrap: true),                                               // 15 plain wrap
            xf(font: 3, fill: 2, border: 1)                               // 16 section header
        ]
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        x += "<numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"#,##0.00&quot; ₽&quot;\"/><numFmt numFmtId=\"165\" formatCode=\"dd\\.mm\\.yyyy\"/></numFmts>"
        x += "<fonts count=\"6\">"
        x += "<font><sz val=\"11\"/><color rgb=\"FF2B2F36\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        x += "<font><b/><sz val=\"11\"/><color rgb=\"FF2B2F36\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        x += "<font><b/><sz val=\"18\"/><color rgb=\"FF2B2F36\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        x += "<font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        x += "<font><sz val=\"10\"/><color rgb=\"FF6B7280\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        x += "<font><b/><sz val=\"11\"/><color rgb=\"FFC0392B\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        x += "</fonts>"
        x += "<fills count=\"4\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
        x += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF3A3F47\"/><bgColor indexed=\"64\"/></patternFill></fill>"
        x += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFF1F2F4\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>"
        x += "<borders count=\"2\"><border><left/><right/><top/><bottom/><diagonal/></border>"
        x += "<border><left style=\"thin\"><color rgb=\"FFD0D3D9\"/></left><right style=\"thin\"><color rgb=\"FFD0D3D9\"/></right><top style=\"thin\"><color rgb=\"FFD0D3D9\"/></top><bottom style=\"thin\"><color rgb=\"FFD0D3D9\"/></bottom><diagonal/></border></borders>"
        x += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        x += "<cellXfs count=\"\(xfs.count)\">" + xfs.joined() + "</cellXfs>"
        x += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        return x
    }
}

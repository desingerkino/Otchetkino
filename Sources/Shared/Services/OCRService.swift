import Foundation
import CoreGraphics
import Vision
import CoreData
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Распознавание текста чека через Apple Vision (работает на устройстве, без интернета).
enum OCRService {
    private struct Fragment { var yTop: Double; var xLeft: Double; var height: Double; var text: String }

    /// Распознанный текст по строкам (лучший из вариантов обработки фото).
    static func recognizeLines(from data: Data) async -> [String] {
        await Task.detached(priority: .userInitiated) { recognizeSync(data) }.value
    }

    /// Строки и разбор чека — для заполнения полей покупки.
    static func recognizeFull(from data: Data) async -> (lines: [String], parsed: ParsedReceipt) {
        await Task.detached(priority: .userInitiated) { recognizeBest(data) }.value
    }

    static func recognizeSync(_ data: Data) -> [String] { recognizeBest(data).lines }

    /// Пробует несколько вариантов: исходное фото, улучшенное (выравнивание по документу, контраст, шум),
    /// повёрнутое на 90° — и выбирает тот, где разбор чека получился наиболее уверенным.
    static func recognizeBest(_ data: Data) -> (lines: [String], parsed: ParsedReceipt) {
        guard let original = ImageTools.cgImage(from: data, maxPixel: 9000) else { return ([], ParsedReceipt()) }
        var best: (lines: [String], parsed: ParsedReceipt, score: Double)?
        func consider(_ image: CGImage) {
            let lines = recognizeLines(in: image)
            let parsed = ReceiptParser.parse(lines: lines)
            let score = parsed.score + Double(min(lines.count, 40)) * 0.02
            if best == nil || score > best!.score { best = (lines, parsed, score) }
        }
        func isGood() -> Bool { (best?.parsed.dateConfident ?? false) && (best?.parsed.totalConfident ?? false) }

        consider(original)
        if !isGood() {
            let medium = ImageTools.cgImage(from: data, maxPixel: 4500) ?? original
            if let enhanced = ReceiptImagePrep.enhanced(medium) { consider(enhanced) }
            if !isGood() {
                // фото могли снять боком
                for orientation in [CGImagePropertyOrientation.right, .left] where !isGood() {
                    if let turned = ReceiptImagePrep.rotated(medium, orientation) { consider(turned) }
                }
            }
        }
        return (best?.lines ?? [], best?.parsed ?? ParsedReceipt())
    }

    /// Текст одной картинки: длинные чеки режутся на перекрывающиеся полосы.
    static func recognizeLines(in cg: CGImage) -> [String] {
        let w = cg.width, h = cg.height
        var fragments: [Fragment] = []

        if Double(h) / Double(max(w, 1)) > 2.4 {
            // Длинный термочек: режем на перекрывающиеся полосы, чтобы Vision не терял мелкий текст.
            let tile = Int(Double(w) * 1.8)
            let margin = Int(Double(w) * 0.12)
            var start = 0
            while start < h {
                let ownedTop = start
                let ownedBottom = min(h, start + tile)
                let cropTop = max(0, ownedTop - margin)
                let cropBottom = min(h, ownedBottom + margin)
                if let crop = cg.cropping(to: CGRect(x: 0, y: cropTop, width: w, height: cropBottom - cropTop)) {
                    let frags = recognize(crop, offsetY: Double(cropTop))
                    fragments += frags.filter { f in
                        let mid = f.yTop + f.height / 2
                        return mid >= Double(ownedTop) && (mid < Double(ownedBottom) || ownedBottom == h)
                    }
                }
                start += tile
            }
        } else {
            fragments = recognize(cg, offsetY: 0)
        }
        return group(fragments)
    }

    private static func recognize(_ image: CGImage, offsetY: Double) -> [Fragment] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["ru-RU", "en-US"].filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let h = Double(image.height), w = Double(image.width)
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let box = obs.boundingBox
            return Fragment(yTop: offsetY + (1 - Double(box.maxY)) * h, xLeft: Double(box.minX) * w, height: Double(box.height) * h, text: text)
        }
    }

    /// Склеивает фрагменты, лежащие на одной высоте, в строки («Название ..... 123,00»).
    private static func group(_ fragments: [Fragment]) -> [String] {
        let sorted = fragments.sorted { $0.yTop < $1.yTop }
        var lines: [[Fragment]] = []
        for f in sorted {
            if var last = lines.last, let ref = last.first,
               abs((f.yTop + f.height / 2) - (ref.yTop + ref.height / 2)) < max(ref.height, f.height) * 0.6 {
                last.append(f)
                lines[lines.count - 1] = last
            } else {
                lines.append([f])
            }
        }
        return lines.map { $0.sorted { $0.xLeft < $1.xLeft }.map { $0.text }.joined(separator: " ") }
    }
}

/// Запускает распознавание для чека и заполняет поля покупки. Ничего не придумывает: что распознано неуверенно —
/// помечается для проверки (`review`). Изменения сохраняются автоматически вместе с остальными.
@MainActor
final class OCRCoordinator: ObservableObject {
    static let shared = OCRCoordinator()
    @Published private(set) var running: Set<NSManagedObjectID> = []
    @Published private(set) var failed: Set<NSManagedObjectID> = []
    /// Поля, которые распознавание определило неуверенно: «дата», «сумма», «магазин».
    @Published private(set) var review: [NSManagedObjectID: [String]] = [:]

    func recognize(_ receipt: RReceipt, force: Bool = false) {
        guard let photo = receipt.photoList.first, let data = photo.data else { return }
        let id = receipt.objectID
        guard !running.contains(id) else { return }
        running.insert(id)
        failed.remove(id)
        review[id] = nil
        Task { [weak receipt] in
            let result = await OCRService.recognizeFull(from: data)
            self.running.remove(id)
            guard let receipt = receipt, !receipt.isDeleted, let ctx = receipt.managedObjectContext else { return }
            if result.parsed.isEmpty && result.lines.isEmpty {
                self.failed.insert(id)
            } else {
                Self.apply(result.parsed, lines: result.lines, to: receipt, ctx: ctx, overwrite: force)
                if result.parsed.totalKop == nil && result.parsed.items.isEmpty { self.failed.insert(id) }
                let fields = result.parsed.reviewFields
                if !fields.isEmpty { self.review[id] = fields }
            }
        }
    }

    /// Заполняет покупку из разбора. Уже введённое вручную не затирается (кроме явного «Распознать заново» для пустых позиций).
    static func apply(_ parsed: ParsedReceipt, lines: [String], to r: RReceipt, ctx: NSManagedObjectContext, overwrite: Bool = false) {
        let firstRun = r.rawText.isEmpty
        r.rawText = lines.joined(separator: "\n")
        if let d = parsed.date, firstRun || overwrite { r.date = d }
        if r.store.isEmpty, let s = parsed.store { r.store = s }
        // позиции: заполняем, только если пользователь их ещё не вводил (пустые позиции заменяются)
        let replaceable = r.purchaseList.allSatisfy { $0.isBlank || ($0.title == "Покупка" && $0.purpose.isEmpty && overwrite) }
        if replaceable {
            var newItems: [(title: String, amount: Int64, quantity: Double)] = []
            if parsed.itemsConsistent {
                newItems = parsed.items.map { ($0.title, $0.sumKop, $0.quantity) }
            } else if let total = parsed.totalKop {
                let title = parsed.items.count == 1 ? parsed.items[0].title : "Покупка"
                newItems = [(title, total, 1)]
            }
            if !newItems.isEmpty {
                for old in r.purchaseList { ctx.delete(old) }
                for it in newItems {
                    let p = DataOps.addItem(ctx, to: r, title: it.title, amount: it.amount)
                    p.quantity = it.quantity
                }
            }
        }
        r.touch()
    }
}

// MARK: - Предобработка фото чека

/// Улучшение фото перед распознаванием: выравнивание по границам документа, контраст, подавление шума, чёткость.
enum ReceiptImagePrep {
    private static let context = CIContext()

    static func rotated(_ cg: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        let ci = CIImage(cgImage: cg).oriented(orientation)
        return context.createCGImage(ci, from: ci.extent)
    }

    static func enhanced(_ cg: CGImage) -> CGImage? {
        var image = CIImage(cgImage: cg)
        if let flat = flattenDocument(cg, image) { image = flat }

        // выравнивание освещения: поднять тени и приглушить блики
        let light = CIFilter.highlightShadowAdjust()
        light.inputImage = image
        light.shadowAmount = 0.7
        light.highlightAmount = 0.9
        image = light.outputImage ?? image

        // чёрно-белый контрастный вариант
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = 0
        controls.contrast = 1.35
        controls.brightness = 0.03
        image = controls.outputImage ?? image

        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = image
        denoise.noiseLevel = 0.02
        denoise.sharpness = 0.5
        image = denoise.outputImage ?? image

        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = image
        sharpen.radius = 2.0
        sharpen.intensity = 0.7
        image = sharpen.outputImage ?? image

        return context.createCGImage(image, from: image.extent)
    }

    /// Находит лист чека на фото и «выпрямляет» его (коррекция перспективы + обрезка). Если лист не найден надёжно — не трогает.
    private static func flattenDocument(_ cg: CGImage, _ image: CIImage) -> CIImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first, obs.confidence > 0.6 else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        func point(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * w, y: n.y * h) }
        let tl = point(obs.topLeft), tr = point(obs.topRight), br = point(obs.bottomRight), bl = point(obs.bottomLeft)
        // площадь четырёхугольника (формула Гаусса) — лист должен занимать заметную часть кадра
        let pts = [tl, tr, br, bl]
        var area: CGFloat = 0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            area += a.x * b.y - b.x * a.y
        }
        area = abs(area) / 2
        guard area > 0.25 * w * h else { return nil }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = tl
        filter.topRight = tr
        filter.bottomRight = br
        filter.bottomLeft = bl
        return filter.outputImage
    }
}

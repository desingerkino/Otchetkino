import Foundation
import CoreGraphics
import Vision
import CoreData

/// Распознавание текста чека через Apple Vision (работает на устройстве, без интернета).
enum OCRService {
    private struct Fragment { var yTop: Double; var xLeft: Double; var height: Double; var text: String }

    static func recognizeLines(from data: Data) async -> [String] {
        await Task.detached(priority: .userInitiated) { recognizeSync(data) }.value
    }

    static func recognizeSync(_ data: Data) -> [String] {
        guard let cg = ImageTools.cgImage(from: data, maxPixel: 9000) else { return [] }
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

/// Запускает распознавание для чека и аккуратно заполняет черновик. Ничего не проводит без подтверждения пользователя.
@MainActor
final class OCRCoordinator: ObservableObject {
    static let shared = OCRCoordinator()
    @Published private(set) var running: Set<NSManagedObjectID> = []
    @Published private(set) var failed: Set<NSManagedObjectID> = []

    func recognize(_ receipt: RReceipt) {
        guard let photo = receipt.photoList.first, let data = photo.data else { return }
        let id = receipt.objectID
        guard !running.contains(id) else { return }
        running.insert(id)
        failed.remove(id)
        Task { [weak receipt] in
            let lines = await OCRService.recognizeLines(from: data)
            let parsed = ReceiptParser.parse(lines: lines)
            self.running.remove(id)
            guard let receipt = receipt, !receipt.isDeleted, let ctx = receipt.managedObjectContext else { return }
            if parsed.isEmpty && lines.isEmpty {
                self.failed.insert(id)
            } else {
                Self.apply(parsed, lines: lines, to: receipt, ctx: ctx)
                if parsed.totalKop == nil && parsed.items.isEmpty { self.failed.insert(id) }
            }
        }
    }

    static func apply(_ parsed: ParsedReceipt, lines: [String], to r: RReceipt, ctx: NSManagedObjectContext) {
        r.rawText = lines.joined(separator: "\n")
        if let d = parsed.date { r.date = d }
        if r.store.isEmpty, let s = parsed.store { r.store = s }
        if r.inn.isEmpty, let i = parsed.inn { r.inn = i }
        if r.purchaseList.isEmpty {
            if parsed.itemsConsistent {
                for it in parsed.items {
                    let p = DataOps.addItem(ctx, to: r, title: it.title, amount: it.sumKop)
                    p.quantity = it.quantity
                }
            } else if let total = parsed.totalKop {
                let title = parsed.items.count == 1 ? parsed.items[0].title : "Покупка"
                DataOps.addItem(ctx, to: r, title: title, amount: total)
            }
        }
        r.touch()
        try? ctx.save()
    }
}

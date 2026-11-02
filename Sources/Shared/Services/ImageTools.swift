import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageTools {
    /// Декодирует изображение с учётом EXIF-ориентации, ограничивая длинную сторону.
    static func cgImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Миниатюра для списков (хранится рядом с оригиналом).
    static func thumbnailJPEG(from data: Data) -> Data? {
        guard let cg = cgImage(from: data, maxPixel: 900) else { return nil }
        return jpegData(from: cg, quality: 0.8)
    }

    static func fileExtension(for data: Data) -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src),
              let ut = UTType(type as String) else { return "jpg" }
        if ut.conforms(to: .heic) || ut.identifier == "public.heif" { return "heic" }
        if ut.conforms(to: .png) { return "png" }
        if ut.conforms(to: .jpeg) { return "jpg" }
        return ut.preferredFilenameExtension ?? "jpg"
    }

    struct ReportImage {
        let data: Data       // JPEG
        let width: Int
        let height: Int
    }

    /// Версия фото для вставки в Excel/PDF: JPEG, длинная сторона до maxPixel, пропорции сохраняются.
    static func reportImage(from data: Data, maxPixel: Int = 3200, quality: Double = 0.82) -> ReportImage? {
        guard let cg = cgImage(from: data, maxPixel: maxPixel), let jpg = jpegData(from: cg, quality: quality) else { return nil }
        return ReportImage(data: jpg, width: cg.width, height: cg.height)
    }
}

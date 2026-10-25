import CoreGraphics
import Foundation
import ImageIO

/// Reads every photo through ImageIO, oriented, with the same decoder for the preview,
/// the tracking and the export, so that a point placed on the preview lands at the same
/// spot on the full-size image (RAW files included).
enum ImageLoader {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
        "dng", "arw", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "erf", "rwl",
    ]

    /// Long edge of the image shown on screen and used for tracking.
    static let previewLongEdge = 2048

    static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    private static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Size of the oriented photo as stored in its metadata.
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = source(url),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Small image for the filmstrip. May come from the embedded thumbnail, so it is never used for geometry.
    static func thumbnail(_ url: URL, maxPixel: Int = 240) -> CGImage? {
        guard let src = source(url) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// Image decoded from the full photo, then reduced to `maxPixel` on its long edge.
    static func decoded(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = source(url) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    static func isRaw(_ url: URL) -> Bool { !developedExtensions.contains(url.pathExtension.lowercased()) }

    static func preview(_ url: URL) -> CGImage? {
        // ImageIO's reduced RAW decoding can take minutes (measured: 17 min on a Sony ARW),
        // while the full decoding takes about a second: decode in full, then reduce.
        guard isRaw(url) else { return decoded(url, maxPixel: previewLongEdge) }
        guard let full = full(url) else { return nil }
        return reduced(full, longEdge: previewLongEdge)
    }

    static func reduced(_ image: CGImage, longEdge: Int) -> CGImage? {
        let s = Double(longEdge) / Double(max(image.width, image.height))
        guard s < 1 else { return image }
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static let developedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp"]

    /// Quick image for the playback: a RAW file's large embedded JPEG when it has one, as decoding
    /// the RAW itself would take too long for a whole series. Only used to judge the motion.
    static func playback(_ url: URL, maxPixel: Int) -> CGImage? {
        if isRaw(url), let src = source(url),
           let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixel,
           ] as CFDictionary), max(img.width, img.height) >= maxPixel / 2 {
            return img
        }
        return decoded(url, maxPixel: maxPixel)
    }

    /// Full-resolution image for the export.
    static func full(_ url: URL) -> CGImage? {
        let size = pixelSize(url) ?? CGSize(width: 16000, height: 16000)
        return decoded(url, maxPixel: Int(max(size.width, size.height)))
    }
}

final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Decoded previews kept in memory (RAW decoding is slow), evicted when memory is short.
final class PreviewCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, CGImageBox>()
    private let condition = NSCondition()
    private var decoding: Set<URL> = []

    init() { cache.totalCostLimit = 1_500_000_000 }

    func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL)?.image }

    func image(for url: URL) -> CGImage? {
        // One decoding per photo: a caller asking for a photo already being decoded waits for it.
        condition.lock()
        while decoding.contains(url) { condition.wait() }
        if let img = cached(url) { condition.unlock(); return img }
        decoding.insert(url)
        condition.unlock()

        let img = ImageLoader.preview(url)
        if let img { cache.setObject(CGImageBox(img), forKey: url as NSURL, cost: img.width * img.height * 4) }

        condition.lock()
        decoding.remove(url)
        condition.broadcast()
        condition.unlock()
        return img
    }

    func removeAll() { cache.removeAllObjects() }
}

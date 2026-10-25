import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OutputPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, uhd, dci4k, hd, vertical4k, vertical, portrait
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Taille de la photo de référence"
        case .uhd: "4K UHD 3840 × 2160"
        case .dci4k: "4K DCI 4096 × 2160"
        case .hd: "HD 1920 × 1080"
        case .vertical4k: "Vertical 9:16 2160 × 3840"
        case .vertical: "Vertical 9:16 1080 × 1920"
        case .portrait: "Portrait 4:5 1080 × 1350"
        }
    }
    /// nil = size of the reference photo.
    var size: CGSize? {
        switch self {
        case .original: nil
        case .uhd: CGSize(width: 3840, height: 2160)
        case .dci4k: CGSize(width: 4096, height: 2160)
        case .hd: CGSize(width: 1920, height: 1080)
        case .vertical4k: CGSize(width: 2160, height: 3840)
        case .vertical: CGSize(width: 1080, height: 1920)
        case .portrait: CGSize(width: 1080, height: 1350)
        }
    }
}

enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case fps23976, fps24, fps25, fps2997, fps30, fps50, fps60
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fps23976: "23,976 i/s"
        case .fps24: "24 i/s"
        case .fps25: "25 i/s"
        case .fps2997: "29,97 i/s"
        case .fps30: "30 i/s"
        case .fps50: "50 i/s"
        case .fps60: "60 i/s"
        }
    }
    /// Duration of one frame.
    var frameDuration: CMTime {
        switch self {
        case .fps23976: CMTime(value: 1001, timescale: 24000)
        case .fps24: CMTime(value: 25, timescale: 600)
        case .fps25: CMTime(value: 24, timescale: 600)
        case .fps2997: CMTime(value: 1001, timescale: 30000)
        case .fps30: CMTime(value: 20, timescale: 600)
        case .fps50: CMTime(value: 12, timescale: 600)
        case .fps60: CMTime(value: 10, timescale: 600)
        }
    }
    var value: Double { 1 / frameDuration.seconds }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case proRes422HQ, proRes4444, h264, hevc, tiff, jpeg
    var id: String { rawValue }
    var label: String {
        switch self {
        case .proRes422HQ: "ProRes 422 HQ (.mov)"
        case .proRes4444: "ProRes 4444 (.mov)"
        case .h264: "H.264 (.mp4)"
        case .hevc: "HEVC H.265 (.mov)"
        case .tiff: "Séquence TIFF 16 bits"
        case .jpeg: "Séquence JPEG"
        }
    }
    var isSequence: Bool { self == .tiff || self == .jpeg }
    var fileExtension: String {
        switch self {
        case .h264: "mp4"
        case .tiff: "tif"
        case .jpeg: "jpg"
        default: "mov"
        }
    }
}

enum Renderer {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Places `image` (the oriented photo, any resolution) on a canvas of `canvas` pixels.
    /// `frameToRef` and `refToCanvas` come from the AlignmentPlan.
    static func render(_ image: CIImage, frameToRef: Mat3, refToCanvas: Mat3, canvas: CGSize) -> CIImage {
        var img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let h = Double(img.extent.height)
        // Core Image pixels (origin bottom-left) -> frame space -> canvas -> Core Image pixels again.
        let fromPixels = Mat3([1 / h, 0, 0, 0, -1 / h, 1, 0, 0, 1])
        let toPixels = Mat3([1, 0, 0, 0, -1, Double(canvas.height), 0, 0, 1])
        var m = toPixels * refToCanvas * frameToRef * fromPixels

        // Big reductions (a 60 MP photo into HD) are prepared with a Lanczos filter to avoid aliasing.
        let center = CGPoint(x: img.extent.midX, y: img.extent.midY)
        let s = m.localScale(at: center)
        if s < 0.75 {
            img = img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1.0])
            m = m * Mat3.scale(1 / s, 1 / s)
        }

        let warped: CIImage
        if m.isAffine {
            warped = img.transformed(by: m.affine)
        } else {
            let e = img.extent
            func corner(_ x: CGFloat, _ y: CGFloat) -> CIVector {
                let p = m.apply(CGPoint(x: x, y: y))
                return CIVector(x: p.x, y: p.y)
            }
            warped = img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": corner(e.minX, e.maxY), "inputTopRight": corner(e.maxX, e.maxY),
                "inputBottomRight": corner(e.maxX, e.minY), "inputBottomLeft": corner(e.minX, e.minY),
            ])
        }
        let rect = CGRect(origin: .zero, size: canvas)
        return warped.composited(over: CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
    }

    static func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8,
                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// One photo to write, with its alignment already computed.
struct ExportItem: Sendable {
    let url: URL
    let frameToRef: Mat3
}

enum ExportError: LocalizedError {
    case unreadable(String)
    case writer(String)
    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Impossible de lire « \(name) »."
        case .writer(let msg): "Écriture impossible : \(msg)"
        }
    }
}

enum Exporter {
    /// Writes the aligned series. For a video, `destination` is the file; for a sequence, a folder.
    static func run(items: [ExportItem], refToCanvas: Mat3, canvas: CGSize, format: ExportFormat, fps: FrameRate,
                    destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if format.isSequence {
            try await writeSequence(items, refToCanvas, canvas, format, destination, progress)
        } else {
            try await writeVideo(items, refToCanvas, canvas, format, fps, destination, progress)
        }
    }

    private static func frame(_ item: ExportItem, _ refToCanvas: Mat3, _ canvas: CGSize) throws -> CIImage {
        guard let cg = ImageLoader.full(item.url) else { throw ExportError.unreadable(item.url.lastPathComponent) }
        return Renderer.render(CIImage(cgImage: cg), frameToRef: item.frameToRef, refToCanvas: refToCanvas, canvas: canvas)
    }

    private static func writeSequence(_ items: [ExportItem], _ refToCanvas: Mat3, _ canvas: CGSize, _ format: ExportFormat,
                                      _ folder: URL, _ progress: @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = folder.lastPathComponent
        let digits = max(4, String(items.count).count)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let img = try frame(item, refToCanvas, canvas)
                let name = "\(base)_\(String(format: "%0\(digits)d", i + 1)).\(format.fileExtension)"
                let url = folder.appendingPathComponent(name)
                let type = (format == .tiff ? UTType.tiff : UTType.jpeg).identifier as CFString
                guard let cg = Renderer.context.createCGImage(img, from: img.extent, format: format == .tiff ? .RGBA16 : .RGBA8,
                                                              colorSpace: space),
                      let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
                else { throw ExportError.writer(name) }
                let props: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ExportError.writer(name) }
            }
            progress(Double(i + 1) / Double(items.count))
        }
    }

    private static func writeVideo(_ items: [ExportItem], _ refToCanvas: Mat3, _ canvas: CGSize, _ format: ExportFormat,
                                   _ fps: FrameRate, _ url: URL, _ progress: @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: format == .h264 ? .mp4 : .mov)
        let w = Int(canvas.width), h = Int(canvas.height)
        var settings: [String: Any] = [
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch format {
        case .proRes4444: settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        case .h264, .hevc:
            settings[AVVideoCodecKey] = format == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc
            let bitsPerPixel = format == .h264 ? 0.2 : 0.12
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(Double(w * h) * fps.value * bitsPerPixel),
            ]
        default: settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "?") }
        writer.startSession(atSourceTime: .zero)
        let space = CGColorSpace(name: CGColorSpace.itur_709)!

        do {
            for (i, item) in items.enumerated() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                try autoreleasepool {
                    let img = try frame(item, refToCanvas, canvas)
                    var buffer: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool,
                          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pb = buffer
                    else { throw ExportError.writer("tampon vidéo indisponible") }
                    Renderer.context.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: space)
                    let time = CMTimeMultiply(fps.frameDuration, multiplier: Int32(i))
                    guard adaptor.append(pb, withPresentationTime: time) else {
                        throw ExportError.writer(writer.error?.localizedDescription ?? "image \(i + 1)")
                    }
                }
                progress(Double(i + 1) / Double(items.count))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(fps.frameDuration, multiplier: Int32(items.count)))
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "échec") }
    }
}

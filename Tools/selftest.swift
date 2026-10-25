// Engine self-test: builds a fake hyperlapse whose camera motion is known, tracks it, renders it and exports it.
//   ./Tools/selftest.sh
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct SelfTest {
    @MainActor static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent("hyperlapse-selftest")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. A large textured "scene" and 30 photos of it taken by a moving, rolling, approaching camera.
        let sceneW = 9000, sceneH = 6500
        let guideA = CGPoint(x: 3800, y: 2900), guideB = CGPoint(x: 5300, y: 2960)  // a straight edge that must stay level
        let scene = makeScene(sceneW, sceneH, edge: (guideA, guideB))
        let W = 6000, H = 4000, count = 30
        let target = CGPoint(x: 4300, y: 3100)    // anchor 1 (scene coordinates, origin bottom-left)
        let target2 = CGPoint(x: 5600, y: 3350)   // anchor 2 (for the line)
        var truth: [[CGPoint]] = []
        var guideTruth: [[CGPoint]] = []
        var urls: [URL] = []
        var rng = Seeded(seed: 7)
        for k in 0..<count {
            let t = Double(k) / Double(count - 1)
            let zoom = 1.0 + 0.25 * t                              // walking towards the subject
            let roll = (Double.random(in: -2.5...2.5, using: &rng)) * .pi / 180
            let cx = 4500 + 900 * sin(t * 3) + Double.random(in: -250...250, using: &rng)
            let cy = 3250 + 500 * t + Double.random(in: -200...200, using: &rng)
            // Scene -> photo: photo centre looks at (cx, cy).
            let a = CGAffineTransform(translationX: CGFloat(W / 2), y: CGFloat(H / 2))
                .rotated(by: roll).scaledBy(x: zoom, y: zoom).translatedBy(x: -cx, y: -cy)
            let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.interpolationQuality = .high
            ctx.concatenate(a)
            ctx.draw(scene, in: CGRect(x: 0, y: 0, width: sceneW, height: sceneH))
            let url = dir.appendingPathComponent(String(format: "IMG_%04d.jpg", k + 1))
            write(ctx.makeImage()!, url, type: .jpeg)
            urls.append(url)
            // Truth in frame space (origin top-left, units of photo height).
            func toFrame(_ p: CGPoint) -> CGPoint {
                let q = p.applying(a)
                return CGPoint(x: q.x / CGFloat(H), y: (CGFloat(H) - q.y) / CGFloat(H))
            }
            truth.append([target, target2].map(toFrame))
            guideTruth.append([guideA, guideB].map(toFrame))
        }
        print("30 photos 6000x4000 écrites dans \(dir.path)")

        // 2. Loader: preview and full size must have the same geometry.
        let full = ImageLoader.full(urls[0])!
        let prev = ImageLoader.preview(urls[0])!
        print("Pleine taille \(full.width)x\(full.height), aperçu \(prev.width)x\(prev.height), taille lue \(ImageLoader.pixelSize(urls[0])!)")

        // 3. Tracking from photo 1 (anchors placed exactly) to photo 30, through the app's own tracking loop
        //    (skipped and estimated photos included).
        let project = Project()
        project.settings.kind = .line
        project.importURLs(urls)
        project.setPoints(truth[0], at: 0)
        let clock = Date()
        project.trackForward()
        while project.isTracking { try await Task.sleep(nanoseconds: 100_000_000) }
        let tracked = project.frames.map { $0.points ?? truth[0] }
        var maxErr = 0.0, sumErr = 0.0
        for k in 1..<count {
            for (p, q) in zip(tracked[k], truth[k]) {
                let e = hypot(Double(p.x - q.x), Double(p.y - q.y)) * Double(H)  // pixels at full size
                maxErr = max(maxErr, e); sumErr += e
            }
        }
        let statuses = Dictionary(grouping: project.frames.dropFirst(), by: \.status).mapValues(\.count)
        print(String(format: "Suivi : erreur moyenne %.2f px, max %.2f px (sur 6000 px), %.2f s/photo, ", sumErr / Double(2 * (count - 1)),
                     maxErr, Date().timeIntervalSince(clock) / Double(count - 1)) + "états \(statuses)" + " · \(project.notice ?? "")")

        // 3b. Orientation: the point holds the position, a horizontal line followed over the series sets the rotation.
        project.settings.kind = .point
        project.setPoints([truth[0][0]], at: 0)
        project.current = 0
        project.trackForward()
        while project.isTracking { try await Task.sleep(nanoseconds: 100_000_000) }
        project.current = 0
        project.editTarget = .horizontal
        project.setPoints(guideTruth[0], at: 0)
        let clock2 = Date()
        project.trackGuides()
        while project.isTracking { try await Task.sleep(nanoseconds: 100_000_000) }
        func rotationError() -> (mean: Double, max: Double) {
            var sum = 0.0, worst = 0.0
            for k in 0..<count {
                let want = GuideKind.horizontal.correction(guideTruth[k][0], guideTruth[k][1])
                let e = abs(project.rotations[k] - want) * 180 / .pi
                sum += e; worst = max(worst, e)
            }
            return (sum / Double(count), worst)
        }
        let gStatus = Dictionary(grouping: project.frames.dropFirst(), by: { $0.guide(.horizontal)?.status ?? .none }).mapValues(\.count)
        let re = rotationError()
        print(String(format: "Orientation suivie : erreur de rotation moyenne %.3f°, max %.3f° (roulis réel ±2,5°), %.2f s/photo, ",
                     re.mean, re.max, Date().timeIntervalSince(clock2) / Double(count - 1)) + "états \(gStatus) · \(project.notice ?? "")")
        // Keyframes only: exact on the keys, interpolated between.
        project.settings.rotation = .keys
        for k in [10, 20, 29] { project.current = k; project.setPoints(guideTruth[k], at: k) }
        let keyErr = [0, 10, 20, 29].map { k in
            abs(project.rotations[k] - GuideKind.horizontal.correction(guideTruth[k][0], guideTruth[k][1])) * 180 / .pi
        }.max()!
        print(String(format: "Images clés : erreur sur les clés %.4f°, photo 15 tournée de %.2f° (entre %.2f° et %.2f°)", keyErr,
                     project.rotations[14] * 180 / .pi, project.rotations[10] * 180 / .pi, project.rotations[20] * 180 / .pi))
        project.settings.rotation = .follow
        project.settings.smoothing = .light
        let sm = rotationError()
        print(String(format: "Lissage léger : erreur moyenne %.3f° (le roulis du test est aléatoire, le lissage ne peut que l'augmenter)", sm.mean))
        // Rendered: the line must come out level on the canvas.
        project.settings.smoothing = .none
        project.settings.output = .hd
        if let plan = project.plan {
            let gc = plan.refToCanvas(CGSize(width: 1920, height: 1080))
            var tilt = 0.0, pointDrift = 0.0
            for k in 0..<count {
                let m = gc * project.frameToRef(k, plan: plan)
                let a = m.apply(guideTruth[k][0]), b = m.apply(guideTruth[k][1])
                tilt = max(tilt, abs(atan2(Double(b.y - a.y), Double(b.x - a.x))) * 180 / .pi)
                let p = m.apply(truth[k][0]), p0 = gc.apply(truth[0][0])
                pointDrift = max(pointDrift, hypot(Double(p.x - p0.x), Double(p.y - p0.y)))
            }
            print(String(format: "Sortie : inclinaison max de la ligne %.3f°, dérive max du point %.2f px (HD)", tilt, pointDrift))
        }
        // 3c. Stabilization: point only (no lines), the background still turns (±2.5°) and grows (+25 %).
        project.settings.rotation = .off
        project.settings.zoom = 1
        func wobble() -> (angle: Double, scale: Double, jitter: Double) {
            // How the line target -> target2 moves on the output: spread of its angle, of its length, and frame-to-frame jumps.
            guard let plan = project.plan else { return (0, 0, 0) }
            let gc = plan.refToCanvas(CGSize(width: 1920, height: 1080))
            var angles: [Double] = [], lengths: [Double] = []
            for k in 0..<count {
                let m = gc * project.frameToRef(k, plan: plan)
                let a = m.apply(truth[k][0]), b = m.apply(truth[k][1])
                angles.append(atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi)
                lengths.append(hypot(Double(b.x - a.x), Double(b.y - a.y)))
            }
            func sd(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(v.count); return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)) }
            let jumps = zip(angles.dropFirst(), angles).map { abs($0 - $1) }
            return (sd(angles), sd(lengths) / (lengths.reduce(0, +) / Double(count)) * 100, jumps.reduce(0, +) / Double(jumps.count))
        }
        let before = wobble()
        let clock3 = Date()
        project.analyzeStabilization()
        while project.isTracking { try await Task.sleep(nanoseconds: 100_000_000) }
        print(String(format: "Stabilisation : analyse %.2f s/photo, %d/%d passages mesurés", Date().timeIntervalSince(clock3) / Double(count),
                     project.stabMeasured, count - 1))
        project.settings.stabResult = .locked
        let locked = wobble()
        project.settings.stabResult = .smooth
        project.settings.stabSmoothness = 50
        let smooth = wobble()
        print(String(format: "  sans stabilisation : rotation ±%.2f°, taille ±%.1f %%, à-coups %.2f°/photo", before.angle, before.scale, before.jitter))
        print(String(format: "  sans mouvement     : rotation ±%.2f°, taille ±%.1f %%, à-coups %.2f°/photo", locked.angle, locked.scale, locked.jitter))
        print(String(format: "  lissé 50 %%         : rotation ±%.2f°, taille ±%.1f %%, à-coups %.2f°/photo", smooth.angle, smooth.scale, smooth.jitter))
        if let plan = project.plan {
            let gc = plan.refToCanvas(CGSize(width: 1920, height: 1080))
            let drift = (0..<count).map { k -> Double in
                let p = (gc * project.frameToRef(k, plan: plan)).apply(truth[k][0]), p0 = gc.apply(truth[0][0])
                return hypot(Double(p.x - p0.x), Double(p.y - p0.y))
            }.max()!
            print(String(format: "  point gardé fixe : dérive max %.2f px (HD)", drift))
        }
        project.settings.stabEnabled = false
        project.settings.kind = .line
        project.editTarget = .anchor

        // 4. Alignment: where the anchors land on the canvas, photo by photo (should not move).
        var settings = AlignSettings()
        settings.kind = .line
        settings.correctScale = true
        settings.level = .horizontal
        settings.output = .hd
        let plan = AlignmentPlan(refPoints: tracked[0], refAspect: Double(W) / Double(H), settings: settings)
        let canvas = CGSize(width: 1920, height: 1080)
        let g = plan.refToCanvas(canvas)
        var drift = 0.0
        for k in 0..<count {
            let m = g * plan.frameToRef(tracked[k])
            for (i, p) in truth[k].enumerated() {
                let a = m.apply(p), b = g.apply(truth[0][i])
                drift = max(drift, hypot(Double(a.x - b.x), Double(a.y - b.y)))
            }
        }
        let lvl = g.apply(truth[0][1]).y - g.apply(truth[0][0]).y
        print(String(format: "Alignement : dérive max des repères %.2f px sur la sortie HD, écart vertical de la règle %.3f px", drift, lvl))

        // 5. Render check: aligned photos must look alike around the anchors.
        let refOut = Renderer.render(CIImage(cgImage: ImageLoader.full(urls[0])!), frameToRef: .identity, refToCanvas: g, canvas: canvas)
        let lastOut = Renderer.render(CIImage(cgImage: ImageLoader.full(urls[count - 1])!), frameToRef: plan.frameToRef(tracked[count - 1]),
                                      refToCanvas: g, canvas: canvas)
        let refCG = Renderer.cgImage(refOut)!, lastCG = Renderer.cgImage(lastOut)!
        write(refCG, dir.appendingPathComponent("rendu_ref.png"), type: .png)
        write(lastCG, dir.appendingPathComponent("rendu_derniere.png"), type: .png)
        let gr = GrayImage(refCG, longEdge: 1920)!, gl = GrayImage(lastCG, longEdge: 1920)!
        let c = g.apply(truth[0][0])
        let patch = Patch(gr, x: Double(c.x), y: Double(c.y), half: 40)!
        let match = patch.search(in: gl, x: Double(c.x), y: Double(c.y), radius: 15)
        print(String(format: "Rendu : repère retrouvé à (%.2f, %.2f) px de sa place sur la dernière photo, ressemblance %.3f",
                     match.x - Double(c.x), match.y - Double(c.y), match.score))

        // 6. Perspective frame (4 points) through the homography path of the renderer.
        var s2 = settings; s2.kind = .frame; s2.perspective = true; s2.level = .off
        let quad = [CGPoint(x: 0.9, y: 0.4), CGPoint(x: 1.1, y: 0.42), CGPoint(x: 1.08, y: 0.6), CGPoint(x: 0.92, y: 0.58)]
        let moved = quad.map { CGPoint(x: $0.x * 1.1 + 0.03 + $0.y * 0.05, y: $0.y * 0.95 - 0.02) }
        let plan2 = AlignmentPlan(refPoints: quad, refAspect: 1.5, settings: s2)
        let hm = plan2.frameToRef(moved)
        let herr = zip(moved, quad).map { hypot(Double(hm.apply($0).x - $1.x), Double(hm.apply($0).y - $1.y)) }.max()!
        print(String(format: "Perspective : erreur de l'homographie %.2e", herr))

        // 7. Video export.
        let items = (0..<count).map { ExportItem(url: urls[$0], frameToRef: plan.frameToRef(tracked[$0])) }
        let movie = dir.appendingPathComponent("hyperlapse.mov")
        let t0 = Date()
        try await Exporter.run(items: items, refToCanvas: g, canvas: canvas, format: .proRes422HQ, fps: .fps25,
                               destination: movie, progress: { _ in })
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let frames = try await track.load(.nominalFrameRate)
        print(String(format: "Export ProRes : %.0fx%.0f, %.2f s, %.0f i/s, %.1f s de calcul", size.width, size.height,
                     duration.seconds, frames, Date().timeIntervalSince(t0)))
        let seq = dir.appendingPathComponent("sequence")
        try await Exporter.run(items: Array(items.prefix(3)), refToCanvas: g, canvas: canvas, format: .tiff, fps: .fps25,
                               destination: seq, progress: { _ in })
        print("Séquence TIFF : \(try FileManager.default.contentsOfDirectory(atPath: seq.path).sorted())")
    }

    static func makeScene(_ w: Int, _ h: Int, edge: (CGPoint, CGPoint)) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = Seeded(seed: 1)
        ctx.setFillColor(red: 0.35, green: 0.4, blue: 0.45, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for _ in 0..<9000 {
            ctx.setFillColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                             blue: .random(in: 0...1, using: &rng), alpha: .random(in: 0.5...1, using: &rng))
            let r = CGFloat.random(in: 8...90, using: &rng)
            let rect = CGRect(x: .random(in: 0...CGFloat(w), using: &rng), y: .random(in: 0...CGFloat(h), using: &rng),
                              width: r, height: r * .random(in: 0.4...1.6, using: &rng))
            if Bool.random(using: &rng) { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        // A dark band under a straight edge (a roof line), longer than the part used as the guide.
        let (a, b) = edge
        let dx = (b.x - a.x) * 0.3, dy = (b.y - a.y) * 0.3
        ctx.setFillColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 1)
        ctx.addLines(between: [CGPoint(x: a.x - dx, y: a.y - dy), CGPoint(x: b.x + dx, y: b.y + dy),
                               CGPoint(x: b.x + dx, y: b.y + dy - 260), CGPoint(x: a.x - dx, y: a.y - dy - 260)])
        ctx.fillPath()
        return ctx.makeImage()!
    }

    static func write(_ img: CGImage, _ url: URL, type: UTType) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(d)
    }
}

struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

import CoreGraphics
import Foundation
import Vision

/// Grayscale copy of a photo used for template matching.
struct GrayImage: Sendable {
    let width: Int
    let height: Int
    var data: [Float]

    init(width: Int, height: Int, data: [Float]) {
        self.width = width; self.height = height; self.data = data
    }

    /// Draws `image` in gray so that its long edge is `longEdge` pixels.
    init?(_ image: CGImage, longEdge: Int) {
        let s = Double(longEdge) / Double(max(image.width, image.height))
        let w = max(8, Int((Double(image.width) * s).rounded())), h = max(8, Int((Double(image.height) * s).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, data: bytes.map { Float($0) })
    }

    /// Bilinear value at a sub-pixel position (edges repeated).
    func sample(_ x: Double, _ y: Double) -> Float {
        let xc = min(max(x, 0), Double(width - 1)), yc = min(max(y, 0), Double(height - 1))
        let x0 = min(Int(xc), width - 2), y0 = min(Int(yc), height - 2)
        let fx = Float(xc - Double(x0)), fy = Float(yc - Double(y0))
        let i = y0 * width + x0
        let top = data[i] + (data[i + 1] - data[i]) * fx
        let bottom = data[i + width] + (data[i + width + 1] - data[i + width]) * fx
        return top + (bottom - top) * fy
    }

    /// Box-filtered reduction by an integer factor.
    func reduced(by f: Int) -> GrayImage {
        let w = width / f, h = height / f
        var out = [Float](repeating: 0, count: w * h)
        let norm = 1 / Float(f * f)
        data.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w {
                    var s: Float = 0
                    for dy in 0..<f {
                        let row = (y * f + dy) * width + x * f
                        for dx in 0..<f { s += src[row + dx] }
                    }
                    out[y * w + x] = s * norm
                }
            }
        }
        return GrayImage(width: w, height: h, data: out)
    }
}

/// A zero-mean square patch cut around a point.
struct Patch {
    let half: Int
    let values: [Float]
    let norm: Float  // sqrt of the sum of squares

    /// Cuts the patch centred exactly on (x, y). `warp` (a, b, c, d) maps an offset of the patch to an
    /// offset in `img`, so a patch taken on a rotated or zoomed photo can be put back upright.
    init?(_ img: GrayImage, x: Double, y: Double, half: Int, warp: (Double, Double, Double, Double) = (1, 0, 0, 1)) {
        let size = 2 * half + 1
        var v = [Float](repeating: 0, count: size * size)
        var sum: Float = 0
        for dy in -half...half {
            for dx in -half...half {
                let ox = warp.0 * Double(dx) + warp.1 * Double(dy), oy = warp.2 * Double(dx) + warp.3 * Double(dy)
                let p = img.sample(x + ox, y + oy)
                v[(dy + half) * size + dx + half] = p
                sum += p
            }
        }
        let mean = sum / Float(v.count)
        var sq: Float = 0
        for i in v.indices { v[i] -= mean; sq += v[i] * v[i] }
        // A flat patch (sky, wall) cannot be followed.
        guard sq / Float(v.count) > 4 else { return nil }
        self.half = half; self.values = v; self.norm = sq.squareRoot()
    }

    /// Best normalized cross-correlation of the patch around (x, y) within `radius` pixels.
    /// Returns the sub-pixel position of the best match and its score (1 = identical).
    func search(in img: GrayImage, x: Double, y: Double, radius: Int) -> (x: Double, y: Double, score: Double) {
        let cx = Int(x.rounded()), cy = Int(y.rounded())
        let size = 2 * half + 1, n = Double(size * size)
        let side = 2 * radius + 1
        var scores = [Float](repeating: -1, count: side * side)
        let w = img.width, h = img.height
        img.data.withUnsafeBufferPointer { src in
            values.withUnsafeBufferPointer { t in
                for oy in -radius...radius {
                    for ox in -radius...radius {
                        let px = cx + ox, py = cy + oy
                        let inside = px - half >= 0 && py - half >= 0 && px + half < w && py + half < h
                        // Double sums: in single precision the variance of a nearly flat window cancels out
                        // and the score shoots above 1, so a plain area looked like a perfect match.
                        var s = 0.0, s2 = 0.0, st = 0.0
                        var ti = 0
                        for dy in -half...half {
                            let yy = inside ? py + dy : min(max(py + dy, 0), h - 1)
                            let row = yy * w
                            for dx in -half...half {
                                let xx = inside ? px + dx : min(max(px + dx, 0), w - 1)
                                let p = Double(src[row + xx])
                                s += p; s2 += p * p; st += Double(t[ti]) * p
                                ti += 1
                            }
                        }
                        let varI = s2 - s * s / n
                        // A window flatter than the patch can carry no match (same floor as Patch).
                        if varI / n > 4 {
                            scores[(oy + radius) * side + ox + radius] = Float(min(1, st / (Double(norm) * varI.squareRoot())))
                        }
                    }
                }
            }
        }
        var best = 0
        for i in scores.indices where scores[i] > scores[best] { best = i }
        let bx = best % side, by = best / side
        // Parabola through the neighbours for sub-pixel precision.
        func refine(_ a: Float, _ b: Float, _ c: Float) -> Double {
            let d = a - 2 * b + c
            return d < 0 ? Double(max(-0.5, min(0.5, 0.5 * (a - c) / d))) : 0
        }
        var fx = 0.0, fy = 0.0
        if bx > 0, bx < side - 1 { fx = refine(scores[best - 1], scores[best], scores[best + 1]) }
        if by > 0, by < side - 1 { fy = refine(scores[best - side], scores[best], scores[best + side]) }
        return (Double(cx + bx - radius) + fx, Double(cy + by - radius) + fy, Double(scores[best]))
    }
}

/// Follows the anchor points from one photo to the next.
final class TrackingEngine: @unchecked Sendable {
    struct Levels {
        let fine: GrayImage    // ~2048 px on the long edge
        let coarse: GrayImage  // 4 times smaller, for big jumps between photos
    }

    static let fineLongEdge = 2048
    static let coarseFactor = 4

    private let previews: PreviewCache
    private var levelCache: [URL: Levels] = [:]
    private var cacheOrder: [URL] = []

    init(previews: PreviewCache) { self.previews = previews }

    private func levels(_ url: URL, _ image: CGImage) -> Levels? {
        if let l = levelCache[url] { return l }
        guard let fine = GrayImage(image, longEdge: Self.fineLongEdge) else { return nil }
        let l = Levels(fine: fine, coarse: fine.reduced(by: Self.coarseFactor))
        levelCache[url] = l
        cacheOrder.append(url)
        if cacheOrder.count > 4 { levelCache[cacheOrder.removeFirst()] = nil }
        return l
    }

    /// Global camera shift between two photos, in frame space (units of the photo's height).
    static func predictedShift(from prev: CGImage, to next: CGImage) -> CGPoint? {
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: next, options: [:])
        do { try VNImageRequestHandler(cgImage: prev, options: [:]).perform([req]) } catch { return nil }
        guard let t = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform else { return nil }
        // Vision maps the next photo onto the previous one, with the origin at the bottom-left.
        let h = Double(prev.height)
        return CGPoint(x: -Double(t.tx) / h, y: Double(t.ty) / h)
    }

    struct Result {
        var points: [CGPoint]
        var score: Double      // worst point
        var scales: [Double]   // size of each point's surroundings on `next`, relative to `key`
    }

    /// Zoom changes tried between two consecutive photos: a photographer walking towards the subject
    /// can make it grow by a third from one photo to the next.
    static let zoomSteps: [Double] = [1, 0.92, 1.09, 0.84, 1.19, 0.76, 1.3, 1.42, 0.7]

    /// Finds `prevPoints` (placed on `prev`) on `next`. `motion` is how each point moved at the step
    /// before (camera speed). `key` is the last photo placed by hand, matched as well so that small
    /// errors do not pile up over the series; `keyScales` is how much bigger each point's surroundings
    /// are on `prev` than on `key` (from the previous steps).
    func track(prev: URL, prevPoints: [CGPoint], motion: [CGPoint]?, key: URL, keyPoints: [CGPoint],
               keyScales: [Double]? = nil, next: URL) -> Result? {
        guard let pImg = previews.image(for: prev), let nImg = previews.image(for: next),
              let kImg = previews.image(for: key),
              let p = levels(prev, pImg), let n = levels(next, nImg), let k = levels(key, kImg)
        else { return nil }

        var shift = Self.predictedShift(from: pImg, to: nImg)
        if let s = shift, abs(s.x) > 0.6 || abs(s.y) > 0.6 { shift = nil }

        let ph = Double(p.fine.height), nh = Double(n.fine.height), kh = Double(k.fine.height)
        let f = Double(Self.coarseFactor)
        let r = kh / ph
        // Rotation and zoom between the hand-placed photo and the previous one: from the anchor itself when
        // it has 2 points or more, from the previous steps otherwise. The hand-placed patch is put back to
        // the previous photo's scale with it.
        var multiWarp: (Double, Double, Double, Double)?
        if prevPoints.count >= 2, keyPoints.count == prevPoints.count {
            let sim = fitTransform(from: prevPoints, to: keyPoints, model: .similarity)
            multiWarp = (sim.m[0] * r, sim.m[1] * r, sim.m[3] * r, sim.m[4] * r)
        }

        var out: [CGPoint] = []
        var scales: [Double] = []
        var worst = 1.0
        for (i, pt) in prevPoints.enumerated() {
            let px = Double(pt.x) * ph, py = Double(pt.y) * ph
            let kp = keyPoints.indices.contains(i) ? keyPoints[i] : pt
            let keyScale = keyScales.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? 1
            let base = multiWarp ?? (r / keyScale, 0, 0, r / keyScale)

            // Where to look: where the point was, where the camera speed sends it, where Vision sends it.
            // In a hyperlapse the subject stays at about the same place in the frame: the previous place and the
            // hand-placed one come first.
            var guesses = [CGPoint(x: pt.x, y: pt.y)]
            if hypot(Double(kp.x - pt.x), Double(kp.y - pt.y)) > 0.01 { guesses.append(kp) }
            if let m = motion, m.indices.contains(i) { guesses.append(CGPoint(x: pt.x + m[i].x, y: pt.y + m[i].y)) }
            if let s = shift { guesses.append(CGPoint(x: pt.x + s.x, y: pt.y + s.y)) }

            // Coarse pass: every zoom step around every guess; keep the five best distinct places.
            var coarse: [(c: CGPoint, zoom: Double, score: Double)] = []
            for z in Self.zoomSteps {
                guard let cp = Patch(p.coarse, x: px / f, y: py / f, half: 10, warp: (1 / z, 0, 0, 1 / z)) else { continue }
                for g in guesses {
                    let m = cp.search(in: n.coarse, x: Double(g.x) * nh / f, y: Double(g.y) * nh / f, radius: 48)
                    coarse.append((CGPoint(x: m.x * f, y: m.y * f), z, m.score))
                }
            }
            coarse.sort { $0.score > $1.score }
            var picked: [(c: CGPoint, zooms: [Double], radius: Int)] = []
            for c in coarse where !picked.contains(where: { hypot(Double($0.c.x - c.c.x), Double($0.c.y - c.c.y)) < 8 }) {
                picked.append((c.c, [c.zoom, c.zoom * 0.95, c.zoom * 1.05], 8))
                if picked.count == 5 { break }
            }
            // The predicted places themselves are always examined closely, at the usual zooms.
            for (gi, g) in guesses.enumerated() {
                picked.append((CGPoint(x: Double(g.x) * nh, y: Double(g.y) * nh), [1, 0.92, 1.09, 0.84, 1.19], gi == 0 ? 32 : 14))
            }

            // Fine pass. The hand-placed patch wins unless the previous photo matches clearly better (it drifts
            // less; the previous one copes better with big changes of view). A far jump from every predicted place
            // or a big change of size has to look clearly better to win: on their own, they are how false matches
            // happen (a blob enlarged looks like another blob).
            func penalty(_ x: Double, _ y: Double, _ z: Double) -> Double {
                let d = guesses.map { hypot(x / nh - Double($0.x), y / nh - Double($0.y)) }.min() ?? 0
                return 1.5 * max(0, d - 0.01) + 0.15 * abs(log(z))
            }
            var best = (x: px / ph * nh, y: py / ph * nh, score: -1.0, zoom: 1.0, value: -9.0)
            var found: [(x: Double, y: Double, value: Double)] = []  // best match around each place examined
            for cand in picked {
                var local = (x: 0.0, y: 0.0, value: -9.0)
                for z in cand.zooms {
                    let prevPatch = Patch(p.fine, x: px, y: py, half: 24, warp: (1 / z, 0, 0, 1 / z))
                    let keyPatch = Patch(k.fine, x: Double(kp.x) * kh, y: Double(kp.y) * kh, half: 24,
                                         warp: (base.0 / z, base.1 / z, base.2 / z, base.3 / z))
                    let kr = keyPatch?.search(in: n.fine, x: Double(cand.c.x), y: Double(cand.c.y), radius: cand.radius)
                    let pr = prevPatch?.search(in: n.fine, x: Double(cand.c.x), y: Double(cand.c.y), radius: cand.radius)
                    var m: (x: Double, y: Double, score: Double)?
                    if let kr, kr.score >= 0.7, kr.score >= (pr?.score ?? -1) - 0.1 { m = kr } else { m = pr ?? kr }
                    guard let m else { continue }
                    let value = m.score - penalty(m.x, m.y, z)
                    if value > best.value { best = (m.x, m.y, m.score, z, value) }
                    if value > local.value { local = (m.x, m.y, value) }
                }
                found.append(local)
            }
            // Two different places that look almost the same once the framing is taken into account (a tyre and
            // a halo, two identical logos): the tracking cannot tell, so it says so instead of picking one.
            var bestScore = best.score
            let rival = found.filter { hypot($0.x - best.x, $0.y - best.y) > 12 }.map(\.value).max() ?? -9
            if bestScore < 0.95, rival > best.value - 0.04 { bestScore = min(bestScore, 0.49) }
            out.append(CGPoint(x: best.x / nh, y: best.y / nh))
            scales.append(keyScale * best.zoom)
            worst = min(worst, bestScore)
        }
        return Result(points: out, score: worst, scales: scales)
    }

    // MARK: - Straight edges (lines that keep the photo level)

    /// Sign of the contrast across the line a -> b on `url` (+1 or -1): which side is the darker one. A line is
    /// then only matched by an edge with the same contrast, not by a parallel edge of the opposite kind.
    func edgePolarity(_ url: URL, _ pts: [CGPoint]) -> Float {
        guard pts.count == 2, let img = previews.image(for: url), let l = levels(url, img) else { return 0 }
        let h = Double(l.fine.height)
        let a = (Double(pts[0].x) * h, Double(pts[0].y) * h), b = (Double(pts[1].x) * h, Double(pts[1].y) * h)
        let len = max(hypot(b.0 - a.0, b.1 - a.1), 1)
        let n = (-(b.1 - a.1) / len, (b.0 - a.0) / len)
        var sum: Float = 0
        for i in 0..<40 {
            let t = (Double(i) + 0.5) / 40
            let x = a.0 + (b.0 - a.0) * t, y = a.1 + (b.1 - a.1) * t
            sum += l.fine.sample(x + 2 * n.0, y + 2 * n.1) - l.fine.sample(x - 2 * n.0, y - 2 * n.1)
        }
        return sum >= 0 ? 1 : -1
    }

    struct EdgeFit {
        var points: [CGPoint]
        var support: Double  // share of the line where the edge is actually seen (0...1)
    }

    /// Finds the straight edge nearest to `predicted` on `url`: edge points are looked for across the predicted
    /// line, then the straight line carried by most of them is kept (RANSAC), with the same contrast as on the
    /// keyframe and an angle at most `maxTurn` away. People passing in front only hide part of it.
    func findEdge(_ url: URL, predicted: [CGPoint], polarity: Float, maxTurn: Double, radius: Double = 0.025) -> EdgeFit? {
        guard predicted.count == 2, let img = previews.image(for: url), let l = levels(url, img) else { return nil }
        let g = l.fine
        let h = Double(g.height)
        let a = (Double(predicted[0].x) * h, Double(predicted[0].y) * h), b = (Double(predicted[1].x) * h, Double(predicted[1].y) * h)
        let len = hypot(b.0 - a.0, b.1 - a.1)
        guard len > 20 else { return nil }
        let d = ((b.0 - a.0) / len, (b.1 - a.1) / len), n = (-d.1, d.0)
        let r = max(12, Int(radius * h))
        let samples = 48
        var cands: [(s: Int, x: Double, y: Double)] = []
        for i in 0..<samples {
            let t = (Double(i) + 0.5) / Double(samples)
            let cx = a.0 + (b.0 - a.0) * t, cy = a.1 + (b.1 - a.1) * t
            // Contrast across the line, every pixel along the normal.
            var prof = [Float](repeating: 0, count: 2 * r + 1)
            for u in -r...r {
                let x = cx + Double(u) * n.0, y = cy + Double(u) * n.1
                prof[u + r] = polarity * (g.sample(x + n.0, y + n.1) - g.sample(x - n.0, y - n.1)) / 2
            }
            var peaks: [(u: Int, v: Float)] = []
            for u in 1..<(2 * r) where prof[u] > 6 && prof[u] >= prof[u - 1] && prof[u] >= prof[u + 1] {
                peaks.append((u - r, prof[u]))
            }
            for pk in peaks.sorted(by: { $0.v > $1.v }).prefix(3) {
                // Sub-pixel place of the edge.
                let u = pk.u + r
                let den = prof[u - 1] - 2 * prof[u] + prof[u + 1]
                let off = den < 0 ? Double(0.5 * (prof[u - 1] - prof[u + 1]) / den) : 0
                let du = Double(pk.u) + max(-0.5, min(0.5, off))
                cands.append((i, cx + du * n.0, cy + du * n.1))
            }
        }
        guard cands.count >= 6 else { return nil }

        // Straight line carried by the most samples; between equals, the one closest to the prediction.
        var rng = SplitMix(seed: UInt64(cands.count) &* 2654435761)
        var best: (score: Double, inliers: [Int])?
        let cosMax = cos(maxTurn)
        for _ in 0..<400 {
            let i = Int(rng.next() % UInt64(cands.count)), j = Int(rng.next() % UInt64(cands.count))
            let p = cands[i], q = cands[j]
            guard abs(p.s - q.s) >= 6 else { continue }
            let ll = hypot(q.x - p.x, q.y - p.y)
            var dir = ((q.x - p.x) / ll, (q.y - p.y) / ll)
            if dir.0 * d.0 + dir.1 * d.1 < 0 { dir = (-dir.0, -dir.1) }
            guard dir.0 * d.0 + dir.1 * d.1 >= cosMax else { continue }
            let nn = (-dir.1, dir.0)
            var seen = Set<Int>(), inl: [Int] = []
            for (k, c) in cands.enumerated() where abs((c.x - p.x) * nn.0 + (c.y - p.y) * nn.1) < 1.5 {
                inl.append(k); seen.insert(c.s)
            }
            let offset = abs((p.x - a.0) * n.0 + (p.y - a.1) * n.1) / Double(r)
            let score = Double(seen.count) * (1 - 0.3 * min(offset, 1))
            if score > best?.score ?? -1 { best = (score, inl) }
        }
        guard let best else { return nil }
        let inl = best.inliers.map { cands[$0] }
        let support = Double(Set(inl.map(\.s)).count) / Double(samples)
        // Least-squares line through the inliers (principal direction).
        let mx = inl.map(\.x).reduce(0, +) / Double(inl.count), my = inl.map(\.y).reduce(0, +) / Double(inl.count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for c in inl { sxx += (c.x - mx) * (c.x - mx); syy += (c.y - my) * (c.y - my); sxy += (c.x - mx) * (c.y - my) }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        var dir = (cos(theta), sin(theta))
        if dir.0 * d.0 + dir.1 * d.1 < 0 { dir = (-dir.0, -dir.1) }
        // Same ends as predicted, laid on the edge found.
        func project(_ p: (Double, Double)) -> CGPoint {
            let t = (p.0 - mx) * dir.0 + (p.1 - my) * dir.1
            return CGPoint(x: (mx + t * dir.0) / h, y: (my + t * dir.1) / h)
        }
        return EdgeFit(points: [project(a), project(b)], support: support)
    }
}

/// Small deterministic random generator (the same photos always give the same result).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

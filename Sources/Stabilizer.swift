import CoreGraphics
import Foundation

// Stabilization of an aligned hyperlapse, in the spirit of After Effects' Warp Stabilizer (not its code, which is
// Adobe's). Once the anchor is aligned, the rest of the picture can still move from one photo to the next: it turns,
// it grows as the photographer walks, it slides. "Analyser" measures that motion between consecutive aligned photos;
// the motion is then smoothed (or removed) and each photo gets the small correction that puts it on the smooth path.
// Everything is expressed in the reference photo's space, so it does not depend on the output size.

enum StabResult: String, Codable, CaseIterable, Identifiable, Sendable {
    case smooth, locked
    var id: String { rawValue }
    var label: String { self == .smooth ? "Mouvement lissé" : "Sans mouvement" }
}

enum Stabilizer {
    /// Motion of the picture from one aligned photo to the next, in reference space (a similarity), measured on two
    /// gray renders of the aligned photos. `canvasToRef` maps render pixels to reference space. With `pivot`, the
    /// motion is a rotation and a scale around it only (the anchor stays where it is). Nil when too few places match.
    static func measure(prev: GrayImage, next: GrayImage, canvasToRef: Mat3, pivot: CGPoint?) -> (motion: Mat3, inliers: Int)? {
        let w = prev.width, h = prev.height
        var src: [CGPoint] = [], dst: [CGPoint] = []
        let cols = 10, rows = 8, half = 14, radius = 30
        func clear(_ img: GrayImage, _ x: Double, _ y: Double, _ r: Double) -> Bool {
            // A window that touches the black outside of the photo would follow the edge of the photo, not the scene.
            for (dx, dy) in [(-r, -r), (r, -r), (-r, r), (r, r), (0, 0), (-r, 0), (r, 0), (0, -r), (0, r)] where img.sample(x + dx, y + dy) < 1.5 {
                return false
            }
            return true
        }
        for j in 0..<rows {
            for i in 0..<cols {
                let x = Double(w) * (0.08 + 0.84 * (Double(i) + 0.5) / Double(cols))
                let y = Double(h) * (0.08 + 0.84 * (Double(j) + 0.5) / Double(rows))
                guard clear(prev, x, y, Double(half + 2)) else { continue }
                // A few sizes: walking towards the subject makes the background grow between photos.
                var best: (x: Double, y: Double, score: Double)?
                for z in [1.0, 0.92, 1.09, 0.85, 1.18] {
                    guard let patch = Patch(prev, x: x, y: y, half: half, warp: (1 / z, 0, 0, 1 / z)) else { continue }
                    let m = patch.search(in: next, x: x, y: y, radius: radius)
                    if m.score > best?.score ?? -1 { best = m }
                }
                guard let b = best, b.score >= 0.82, clear(next, b.x, b.y, Double(half + 2)) else { continue }
                src.append(canvasToRef.apply(CGPoint(x: x, y: y)))
                dst.append(canvasToRef.apply(CGPoint(x: b.x, y: b.y)))
            }
        }
        let need = pivot == nil ? 6 : 4
        guard src.count >= need else { return nil }
        // Tolerance: 1.5 render pixels, in reference units.
        let unit = hypot(Double(canvasToRef.m[0]), Double(canvasToRef.m[3]))
        let tol = 1.5 * unit
        func fit(_ idx: [Int]) -> Mat3 {
            let a = idx.map { src[$0] }, b = idx.map { dst[$0] }
            guard let p = pivot else { return fitTransform(from: a, to: b, model: .similarity) }
            // Rotation and scale around the pivot, no shift.
            var re = 0.0, im = 0.0, den = 0.0
            for (u, v) in zip(a, b) {
                let ax = Double(u.x - p.x), ay = Double(u.y - p.y), bx = Double(v.x - p.x), by = Double(v.y - p.y)
                re += ax * bx + ay * by; im += ax * by - ay * bx; den += ax * ax + ay * ay
            }
            guard den > 1e-12 else { return .identity }
            let zr = re / den, zi = im / den
            return .translation(Double(p.x), Double(p.y)) * Mat3([zr, -zi, 0, zi, zr, 0, 0, 0, 1]) * .translation(-Double(p.x), -Double(p.y))
        }
        func inliers(_ m: Mat3) -> [Int] {
            src.indices.filter { let q = m.apply(src[$0]); return hypot(Double(q.x - dst[$0].x), Double(q.y - dst[$0].y)) < tol }
        }
        // RANSAC: the motion most places agree on (people walking by and parallax disagree).
        var rng = SplitMix(seed: UInt64(src.count) &* 0x9E3779B97F4A7C15)
        var best: [Int] = []
        let sample = pivot == nil ? 2 : 1
        for _ in 0..<300 {
            var idx: [Int] = []
            while idx.count < sample { let i = Int(rng.next() % UInt64(src.count)); if !idx.contains(i) { idx.append(i) } }
            let inl = inliers(fit(idx))
            if inl.count > best.count { best = inl }
        }
        guard best.count >= need else { return nil }
        let refined = fit(best)
        let final = inliers(refined)
        return (fit(final.count >= best.count ? final : best), max(final.count, best.count))
    }

    /// Correction of each photo (reference space): puts the measured path of the picture onto its smoothed version.
    /// `motion[k]` goes from photo k-1 to photo k (`motion[0]` is ignored). Unmeasured steps count as no motion.
    static func corrections(motion: [Mat3?], pivot: CGPoint, result: StabResult, smoothness: Double,
                            rotation: Bool, scale: Bool, keepPoint: Bool, reference: Int) -> [Mat3] {
        let n = motion.count
        guard n > 1 else { return [Mat3](repeating: .identity, count: n) }
        // Path of the picture since photo 1, as (shift x, shift y, log scale, angle) around the pivot.
        var path: [Mat3] = [.identity]
        for k in 1..<n { path.append((motion[k] ?? .identity) * path[k - 1]) }
        func params(_ m: Mat3) -> [Double] {
            // m(x) = P + a (x - P) + t
            let a = Double(m.m[0]), b = Double(m.m[3])
            let q = m.apply(pivot)
            return [Double(q.x - pivot.x), Double(q.y - pivot.y), log(max(hypot(a, b), 1e-9)), atan2(b, a)]
        }
        var p = path.map(params)
        for k in 1..<n {  // angles without jumps of 2 pi
            while p[k][3] - p[k - 1][3] > .pi { p[k][3] -= 2 * .pi }
            while p[k][3] - p[k - 1][3] < -.pi { p[k][3] += 2 * .pi }
        }
        var target = p
        let ref = min(max(reference, 0), n - 1)
        for c in 0..<4 {
            let series = p.map { $0[c] }
            let smooth: [Double]
            switch result {
            case .locked: smooth = [Double](repeating: series[ref], count: n)
            case .smooth: smooth = gaussian(series, sigma: 0.2 + smoothness / 100 * 8)
            }
            for k in 0..<n { target[k][c] = smooth[k] }
        }
        func matrix(_ v: [Double]) -> Mat3 {
            let s = exp(v[2]), c = cos(v[3]) * s, d = sin(v[3]) * s
            return .translation(Double(pivot.x) + v[0], Double(pivot.y) + v[1]) * Mat3([c, -d, 0, d, c, 0, 0, 0, 1])
                * .translation(-Double(pivot.x), -Double(pivot.y))
        }
        return (0..<n).map { k in
            var t = target[k]
            if !rotation { t[3] = p[k][3] }
            if !scale { t[2] = p[k][2] }
            if keepPoint { t[0] = p[k][0]; t[1] = p[k][1] }
            guard let inv = matrix(p[k]).inverse else { return .identity }
            return matrix(t) * inv
        }
    }

    static func gaussian(_ v: [Double], sigma: Double) -> [Double] {
        let r = Int((3 * sigma).rounded(.up))
        return v.indices.map { k in
            var s = 0.0, w = 0.0
            for j in max(0, k - r)...min(v.count - 1, k + r) {
                let wj = exp(-Double((j - k) * (j - k)) / (2 * sigma * sigma))
                s += v[j] * wj; w += wj
            }
            return s / w
        }
    }

    /// Short stable fingerprint of a text (Swift's own hashing changes at every launch).
    static func fingerprint(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

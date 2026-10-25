import Accelerate
import CoreGraphics
import Foundation

// Match cut: the same element (a logo, a shape, a word, an object) photographed in different places, sizes and
// angles. Unlike the hyperlapse tracking, nothing links one photo to the next: the element of the reference is
// looked for in the whole photo, at every size and tilt, then its four corners are fitted to the pixel.
//
// Photos are compared through their contours, not their colours: a red logo on a grey, green or blue car has
// different colours every time, but the same edges.

/// A photo as three float planes (0...255), sampled anywhere.
struct ColorImage: @unchecked Sendable {
    let width: Int
    let height: Int
    var r: [Float], g: [Float], b: [Float]

    init(width: Int, height: Int, r: [Float], g: [Float], b: [Float]) {
        self.width = width; self.height = height; self.r = r; self.g = g; self.b = b
    }

    init?(_ image: CGImage, longEdge: Int) {
        let s = Double(longEdge) / Double(max(image.width, image.height))
        let w = max(8, Int((Double(image.width) * s).rounded())), h = max(8, Int((Double(image.height) * s).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        for i in 0..<(w * h) {
            r[i] = Float(bytes[4 * i]); g[i] = Float(bytes[4 * i + 1]); b[i] = Float(bytes[4 * i + 2])
        }
        self.init(width: w, height: h, r: r, g: g, b: b)
    }

    func sample(_ x: Double, _ y: Double) -> (Float, Float, Float) {
        let xc = min(max(x, 0), Double(width - 1)), yc = min(max(y, 0), Double(height - 1))
        let x0 = min(Int(xc), width - 2), y0 = min(Int(yc), height - 2)
        let fx = Float(xc - Double(x0)), fy = Float(yc - Double(y0))
        let i = y0 * width + x0
        func bil(_ p: [Float]) -> Float {
            let top = p[i] + (p[i + 1] - p[i]) * fx
            let bottom = p[i + width] + (p[i + width + 1] - p[i + width]) * fx
            return top + (bottom - top) * fy
        }
        return (bil(r), bil(g), bil(b))
    }

    /// The same photo resized to `w` x `h` (area averaging when reducing).
    func resized(_ w: Int, _ h: Int) -> ColorImage {
        func plane(_ p: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: w * h)
            var src = p
            src.withUnsafeMutableBufferPointer { sp in
                out.withUnsafeMutableBufferPointer { dp in
                    var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                          rowBytes: width * 4)
                    var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    vImageScale_PlanarF(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
            return out
        }
        return ColorImage(width: w, height: h, r: plane(r), g: plane(g), b: plane(b))
    }
}

/// Contour strength of a colour grid: the strongest gradient of the three channels, square-rooted so that faint
/// edges count too. It does not care which colour is on which side.
func contours(_ w: Int, _ h: Int, _ r: [Float], _ g: [Float], _ b: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: w * h)
    guard w > 2, h > 2 else { return out }
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            var best: Float = 0
            for p in [r, g, b] {
                let gx = (p[i - w + 1] + 2 * p[i + 1] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - 1] + p[i + w - 1])
                let gy = (p[i + w - 1] + 2 * p[i + w] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - w] + p[i - w + 1])
                best = max(best, gx * gx + gy * gy)
            }
            out[i] = sqrt(sqrt(best))
        }
    }
    // Borders copy their neighbours.
    for x in 0..<w { out[x] = out[w + x]; out[(h - 1) * w + x] = out[(h - 2) * w + x] }
    for y in 0..<h { out[y * w] = out[y * w + 1]; out[y * w + w - 1] = out[y * w + w - 2] }
    return out
}

func contours(_ img: ColorImage) -> [Float] { contours(img.width, img.height, img.r, img.g, img.b) }

/// Normalized correlation of two grids of the same size (1 = identical).
func correlation(_ a: [Float], _ b: [Float]) -> Double {
    let n = Double(a.count)
    var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
    for i in a.indices {
        let x = Double(a[i]), y = Double(b[i])
        sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
    }
    let va = saa - sa * sa / n, vb = sbb - sb * sb / n
    guard va > 1e-6, vb > 1e-6 else { return -1 }
    return (sab - sa * sb / n) / sqrt(va * vb)
}

final class MatchCutEngine: @unchecked Sendable {
    /// Long edge of the photos for the fine fitting, and for the search over the whole photo.
    static let fineLongEdge = 1400
    static let searchLongEdge = 800
    /// Room around the element taken into the comparison (share of its size on each side).
    static let margin = 0.08

    struct Reference {
        let image: ColorImage          // reference photo at fineLongEdge
        let quad: [CGPoint]            // corners of the element on it (pixels), TL TR BR BL
        let aspect: Double             // width / height of the element, flattened
        let unitToRef: Mat3            // unit square (element plane) -> reference pixels
        let template: [Float]          // contours of the flattened element (fine grid)
        let cols: Int, rows: Int
    }

    struct Found {
        var quad: [CGPoint]   // frame space (units of the photo's height)
        var score: Double
    }

    private let previews: PreviewCache
    init(previews: PreviewCache) { self.previews = previews }

    private static let unitSquare = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]

    /// Grid size for an element of this aspect: `long` cells on its long side.
    private static func grid(aspect: Double, long: Int) -> (cols: Int, rows: Int) {
        let span = 1 + 2 * margin
        if aspect >= 1 {
            return (long, max(9, Int((Double(long) / aspect).rounded())))
        }
        _ = span
        return (max(9, Int((Double(long) * aspect).rounded())), long)
    }

    /// Contours of the element flattened onto a cols x rows grid, through `unitTo` (element plane -> image pixels).
    private static func flatten(_ img: ColorImage, _ unitTo: Mat3, cols: Int, rows: Int) -> [Float] {
        var r = [Float](repeating: 0, count: cols * rows), g = r, b = r
        let m = margin
        for j in 0..<rows {
            let v = -m + (1 + 2 * m) * (Double(j) + 0.5) / Double(rows)
            for i in 0..<cols {
                let u = -m + (1 + 2 * m) * (Double(i) + 0.5) / Double(cols)
                let p = unitTo.apply(CGPoint(x: u, y: v))
                let c = img.sample(Double(p.x), Double(p.y))
                let k = j * cols + i
                r[k] = c.0; g[k] = c.1; b[k] = c.2
            }
        }
        return Self.capped(contours(cols, rows, r, g, b))
    }

    /// Strong contours are cut down (mean + 1 standard deviation): a violent reflection or a car's shut line then
    /// weighs no more than the outline of the element.
    static func capped(_ c: [Float]) -> [Float] {
        guard c.count > 10 else { return c }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(c, 1, nil, 1, &mean, &sd, vDSP_Length(c.count))
        let cap = mean + sd
        guard cap > 0 else { return c }
        return c.map { min($0, cap) }
    }

    /// Prepares the element framed on the reference photo (`quad` in frame space).
    func reference(url: URL, quad: [CGPoint]) -> Reference? {
        guard quad.count == 4, let cg = previews.image(for: url), let img = ColorImage(cg, longEdge: Self.fineLongEdge) else { return nil }
        let h = CGFloat(img.height)
        let px = quad.map { CGPoint(x: $0.x * h, y: $0.y * h) }
        func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }
        let w = (dist(px[0], px[1]) + dist(px[3], px[2])) / 2, ht = (dist(px[0], px[3]) + dist(px[1], px[2])) / 2
        guard w > 4, ht > 4 else { return nil }
        let aspect = w / ht
        let unitTo = fitTransform(from: Self.unitSquare, to: px, model: .homography)
        let (cols, rows) = Self.grid(aspect: aspect, long: 96)
        return Reference(image: img, quad: px, aspect: aspect, unitToRef: unitTo,
                         template: Self.flatten(img, unitTo, cols: cols, rows: rows), cols: cols, rows: rows)
    }

    // MARK: - Search over the whole photo

    private struct Candidate { var center: CGPoint; var width: Double; var angle: Double; var squash: Double; var score: Double }

    /// Every place, size and tilt where the element may be, best first (search image pixels).
    private func search(_ ref: Reference, in img: ColorImage) -> [Candidate] {
        let W = img.width, H = img.height
        let angles: [Double] = [-24, -16, -8, 0, 8, 16, 24].map { $0 * .pi / 180 }
        let squashes: [Double] = [1, 0.72, 1.38]
        let logoCells = 25.0  // width of the element in the template, in cells
        var all: [Candidate] = []
        for angle in angles {
            for squash in squashes {
                // Template: the element as it would look turned by `angle` and narrowed by `squash`, on an upright grid.
                let lw = logoCells * squash, lh = logoCells / ref.aspect
                let c = cos(angle), s = sin(angle)
                let bw = abs(lw * c) + abs(lh * s), bh = abs(lw * s) + abs(lh * c)
                let pad = 1 + 2 * Self.margin * 0.6
                var kw = Int((bw * pad).rounded()) | 1, kh = Int((bh * pad).rounded()) | 1
                kw = max(kw, 7); kh = max(kh, 7)
                guard kw <= 71, kh <= 71 else { continue }
                var r = [Float](repeating: 0, count: kw * kh), g = r, b = r
                for j in 0..<kh {
                    for i in 0..<kw {
                        // Grid cell -> element plane (u, v in 0...1) -> reference photo.
                        let dx = Double(i) - Double(kw - 1) / 2, dy = Double(j) - Double(kh - 1) / 2
                        let ex = (dx * c + dy * s) / lw, ey = (-dx * s + dy * c) / lh
                        let p = ref.unitToRef.apply(CGPoint(x: ex + 0.5, y: ey + 0.5))
                        let col = ref.image.sample(Double(p.x), Double(p.y))
                        let k = j * kw + i
                        r[k] = col.0; g[k] = col.1; b[k] = col.2
                    }
                }
                var t = contours(kw, kh, r, g, b)
                let mean = t.reduce(0, +) / Float(t.count)
                var tn: Float = 0
                for i in t.indices { t[i] -= mean; tn += t[i] * t[i] }
                guard tn > 1 else { continue }
                tn = tn.squareRoot()

                // Sizes: the element from 5 % to 95 % of the photo's short side.
                var width = 0.05 * Double(min(W, H))
                while width <= 0.95 * Double(max(W, H)) * squash {
                    defer { width *= 1.14 }
                    let f = lw / (width * squash)   // search image -> template scale
                    let sw = Int(Double(W) * f), sh = Int(Double(H) * f)
                    guard sw > kw + 2, sh > kh + 2 else { continue }
                    let small = f < 0.999 ? img.resized(sw, sh) : img
                    let e = contours(small)
                    for cand in Self.correlate(e, sw, sh, t, tn, kw, kh) {
                        all.append(Candidate(center: CGPoint(x: Double(cand.x) / f, y: Double(cand.y) / f),
                                             width: width, angle: angle, squash: squash, score: cand.score))
                    }
                }
            }
        }
        all.sort { $0.score > $1.score }
        var kept: [Candidate] = []
        for c in all where !kept.contains(where: { hypot(Double($0.center.x - c.center.x), Double($0.center.y - c.center.y)) < 0.25 * min($0.width, c.width) }) {
            kept.append(c)
            if kept.count == 16 { break }
        }
        return kept
    }

    /// Normalized correlation of the zero-mean template over the whole contour image; the best few peaks.
    private static func correlate(_ e: [Float], _ w: Int, _ h: Int, _ t: [Float], _ tn: Float, _ kw: Int, _ kh: Int)
        -> [(x: Int, y: Int, score: Double)] {
        var num = [Float](repeating: 0, count: w * h)
        var src = e, kernel = t
        src.withUnsafeMutableBufferPointer { sp in
            num.withUnsafeMutableBufferPointer { dp in
                kernel.withUnsafeMutableBufferPointer { kp in
                    var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    vImageConvolve_PlanarF(&s, &d, nil, 0, 0, kp.baseAddress!, UInt32(kh), UInt32(kw), 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        // Window sums through integral images, for the local variance.
        let iw = w + 1
        var s1 = [Double](repeating: 0, count: iw * (h + 1)), s2 = s1
        for y in 0..<h {
            var r1 = 0.0, r2 = 0.0
            for x in 0..<w {
                let v = Double(e[y * w + x])
                r1 += v; r2 += v * v
                s1[(y + 1) * iw + x + 1] = s1[y * iw + x + 1] + r1
                s2[(y + 1) * iw + x + 1] = s2[y * iw + x + 1] + r2
            }
        }
        let hx = kw / 2, hy = kh / 2, n = Double(kw * kh)
        var scores = [Float](repeating: -1, count: w * h)
        for y in hy..<(h - hy) {
            for x in hx..<(w - hx) {
                let x0 = x - hx, y0 = y - hy, x1 = x + hx + 1, y1 = y + hy + 1
                let a = s1[y1 * iw + x1] - s1[y0 * iw + x1] - s1[y1 * iw + x0] + s1[y0 * iw + x0]
                let b = s2[y1 * iw + x1] - s2[y0 * iw + x1] - s2[y1 * iw + x0] + s2[y0 * iw + x0]
                let v = b - a * a / n
                guard v > n * 0.5 else { continue }
                scores[y * w + x] = num[y * w + x] / (tn * Float(v.squareRoot()))
            }
        }
        var peaks: [(x: Int, y: Int, score: Double)] = []
        for _ in 0..<3 {
            var best = -1, bv: Float = 0.2
            for i in scores.indices where scores[i] > bv { bv = scores[i]; best = i }
            guard best >= 0 else { break }
            let bx = best % w, by = best / w
            peaks.append((bx, by, Double(bv)))
            for y in max(0, by - kh / 2)...min(h - 1, by + kh / 2) {
                for x in max(0, bx - kw / 2)...min(w - 1, bx + kw / 2) { scores[y * w + x] = -1 }
            }
        }
        return peaks
    }

    // MARK: - Fitting the four corners

    /// Moves the four corners (pixels of `img`) until the flattened element looks most like the reference.
    /// A frame that can be an element: convex, turning the same way as drawn, not collapsed, inside the photo's
    /// surroundings, and not stretched more than 3 to 1 against its starting shape.
    static func plausible(_ q: [CGPoint], start: [CGPoint], bounds: CGSize) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let cross = Double((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
            if abs(cross) < 1e-9 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        func area(_ p: [CGPoint]) -> Double {
            0.5 * abs((0..<4).reduce(0.0) { $0 + Double(p[$1].x * p[($1 + 1) % 4].y - p[($1 + 1) % 4].x * p[$1].y) })
        }
        let a = area(q), a0 = area(start)
        guard a > 64, a0 > 0, a / a0 < 9, a0 / a < 9 else { return false }
        for i in 0..<4 {
            let side = hypot(Double(q[(i + 1) % 4].x - q[i].x), Double(q[(i + 1) % 4].y - q[i].y))
            let side0 = hypot(Double(start[(i + 1) % 4].x - start[i].x), Double(start[(i + 1) % 4].y - start[i].y))
            if side < 4 || side / max(side0, 1e-6) > 3 * sqrt(a / a0) || side0 / side > 3 * sqrt(a0 / a) { return false }
        }
        let w = Double(bounds.width), h = Double(bounds.height)
        return q.allSatisfy { Double($0.x) > -0.5 * w && Double($0.x) < 1.5 * w && Double($0.y) > -0.5 * h && Double($0.y) < 1.5 * h }
    }

    func fit(_ ref: Reference, in img: ColorImage, start: [CGPoint]) -> (quad: [CGPoint], score: Double) {
        var quad = start
        let bounds = CGSize(width: img.width, height: img.height)
        func value(_ q: [CGPoint]) -> Double {
            guard Self.plausible(q, start: start, bounds: bounds) else { return -2 }
            let unitTo = fitTransform(from: Self.unitSquare, to: q, model: .homography)
            return correlation(Self.flatten(img, unitTo, cols: ref.cols, rows: ref.rows), ref.template)
        }
        var best = value(quad)
        let size = max(hypot(Double(quad[1].x - quad[0].x), Double(quad[1].y - quad[0].y)),
                       hypot(Double(quad[3].x - quad[0].x), Double(quad[3].y - quad[0].y)))
        var step = 0.05
        var evals = 0
        while step * size > 0.15, evals < 900 {
            var improved = false
            let c = centroid(quad)
            var moves: [[CGPoint]] = []
            let d = CGFloat(step * size)
            // The whole element: moved, enlarged, turned; then each corner (perspective).
            for (dx, dy) in [(d, 0), (-d, 0), (0, d), (0, -d)] { moves.append(quad.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }) }
            for k in [1 + step, 1 / (1 + step)] {
                moves.append(quad.map { CGPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) })
            }
            for a in [step, -step] {
                let r = Mat3.translation(Double(c.x), Double(c.y)) * .rotation(a * 0.6) * .translation(-Double(c.x), -Double(c.y))
                moves.append(quad.map(r.apply))
            }
            for i in 0..<4 {
                for (dx, dy) in [(d, 0), (-d, 0), (0, d), (0, -d)] {
                    var q = quad
                    q[i] = CGPoint(x: q[i].x + dx * 0.6, y: q[i].y + dy * 0.6)
                    moves.append(q)
                }
            }
            for q in moves {
                evals += 1
                let v = value(q)
                if v > best + 1e-5 { best = v; quad = q; improved = true }
            }
            if !improved { step *= 0.5 }
        }
        return (quad, best)
    }

    /// Search candidate -> rough corners on the fine photo (`k`: search image / fine photo).
    private static func corners(_ c: Candidate, aspect: Double, k: Double) -> [CGPoint] {
        let w = c.width * c.squash / k, ht = c.width / aspect / k
        let ca = cos(c.angle), sa = sin(c.angle)
        let cx = Double(c.center.x) / k, cy = Double(c.center.y) / k
        return [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { u, v in
            let x = u * w, y = v * ht
            return CGPoint(x: cx + x * ca - y * sa, y: cy + x * sa + y * ca)
        }
    }

    /// Finds the element of `ref` on the photo `url`. With `near` (a rough frame drawn by hand, frame space), only
    /// fits around it; otherwise looks over the whole photo.
    func find(_ ref: Reference, url: URL, near: [CGPoint]? = nil, hints: [[CGPoint]] = []) -> Found? {
        guard let cg = previews.image(for: url), let fine = ColorImage(cg, longEdge: Self.fineLongEdge) else { return nil }
        let h = CGFloat(fine.height)
        var starts: [[CGPoint]] = []
        let k = Double(Self.searchLongEdge) / Double(max(fine.width, fine.height))
        let small = fine.resized(Int(Double(fine.width) * k), Int(Double(fine.height) * k))
        if let near, near.count == 4 {
            // A frame drawn roughly: the drawn frame at a few sizes, and what the search finds inside it.
            let q = near.map { CGPoint(x: $0.x * h, y: $0.y * h) }
            let c = centroid(q)
            for s in [1, 0.85, 0.7, 1.15] {
                starts.append(q.map { CGPoint(x: c.x + ($0.x - c.x) * s, y: c.y + ($0.y - c.y) * s) })
            }
            let xs = q.map { Double($0.x) * k }, ys = q.map { Double($0.y) * k }
            let mx = (xs.max()! - xs.min()!) * 0.2, my = (ys.max()! - ys.min()!) * 0.2
            for cand in search(ref, in: small) where Double(cand.center.x) > xs.min()! - mx && Double(cand.center.x) < xs.max()! + mx
                && Double(cand.center.y) > ys.min()! - my && Double(cand.center.y) < ys.max()! + my && cand.width < (xs.max()! - xs.min()!) * 1.6 {
                starts.append(Self.corners(cand, aspect: ref.aspect, k: k))
            }
        } else {
            // In a match cut the element is usually framed at about the same place: start from where it is on the
            // reference and on the other photos already done, at several sizes.
            for hint in hints where hint.count == 4 {
                let q = hint.map { CGPoint(x: $0.x * h, y: $0.y * h) }
                let c = centroid(q)
                for k in [0.4, 0.55, 0.75, 1, 1.35, 1.8, 2.5] {
                    starts.append(q.map { CGPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) })
                }
            }
            for c in search(ref, in: small).prefix(16) { starts.append(Self.corners(c, aspect: ref.aspect, k: k)) }
        }
        var best: Found?
        for s in starts {
            let r = fit(ref, in: fine, start: s)
            if r.score > best?.score ?? -2 { best = Found(quad: r.quad.map { CGPoint(x: $0.x / h, y: $0.y / h) }, score: r.score) }
        }
        return best
    }
}

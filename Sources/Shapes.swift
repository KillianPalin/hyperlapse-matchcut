import CoreGraphics
import Foundation

// Match cut: the shape of the element inside its frame. A logo fills its frame, but a star, a round sign or an object
// with an odd outline leaves corners of background in it, and that background changes from one photo to the next.
// The shape keeps only the element (and a thin ring around its outline) in the comparison.
//
// The shape lives in the frame's own square (u, v from 0 to 1): the frame's four corners carry its position, size,
// turn and perspective, as for any element.

enum ShapeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, rect, ellipse, star, pen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .rect: "Cadre"
        case .ellipse: "Rond / ovale"
        case .star: "Étoile"
        case .pen: "Plume"
        }
    }
}

struct ElementShape: Codable, Equatable, Sendable {
    var kind: ShapeKind          // rect, ellipse, star or pen (never auto)
    /// Star: radius of the inner corners against the points (0.3 to 0.7).
    var inner: Double = 0.45
    /// Pen: outline drawn by hand, in the frame's square.
    var points: [CGPoint] = []

    static let star = ElementShape(kind: .star)

    /// Outline in the frame's square, closed (the last point joins the first).
    func outline(detail: Int = 64) -> [CGPoint] {
        switch kind {
        case .auto, .rect: return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        case .ellipse:
            return (0..<detail).map { i in
                let a = Double(i) / Double(detail) * 2 * .pi
                return CGPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a))
            }
        case .star:
            // First point straight up, then inner and outer corners in turn.
            return (0..<10).map { i in
                let a = -Double.pi / 2 + Double(i) * .pi / 5, r = i % 2 == 0 ? 0.5 : 0.5 * inner
                return CGPoint(x: 0.5 + r * cos(a), y: 0.5 + r * sin(a))
            }
        case .pen: return points
        }
    }

    /// Turns that give the same shape again (a star looks the same every fifth of a turn), nil for none.
    /// A round shape (`aspect` near 1) looks the same at every turn: 0.
    func symmetry(aspect: Double) -> Double? {
        switch kind {
        case .star: return 2 * .pi / 5
        case .ellipse: return abs(aspect - 1) < 0.15 ? 0 : .pi
        default: return nil
        }
    }

    /// Weight of a point of the frame's square in the comparison: 1 on the element and on a ring of `ring` around its
    /// outline (where its edges are), 0 further out.
    func weight(_ u: Double, _ v: Double, ring: Double) -> Float {
        switch kind {
        case .auto, .rect: return 1
        case .ellipse:
            // The oval fills the frame's square as a circle; the frame's corners stretch it.
            return hypot(u - 0.5, v - 0.5) <= 0.5 + ring ? 1 : 0
        case .star, .pen:
            let poly = outline()
            guard poly.count >= 3 else { return 1 }
            let p = CGPoint(x: u, y: v)
            if Self.contains(poly, p) { return 1 }
            return Self.distance(poly, p) <= ring ? 1 : 0
        }
    }

    static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func distance(_ poly: [CGPoint], _ p: CGPoint) -> Double {
        var best = Double.infinity
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(max((Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / len2, 0), 1) : 0
            best = min(best, hypot(Double(a.x) + t * dx - Double(p.x), Double(a.y) + t * dy - Double(p.y)))
        }
        return best
    }

    /// Pen: an outline drawn on the photo (frame space) becomes a frame around it and the outline inside that frame.
    /// The frame is the smallest upright box around the outline.
    static func pen(_ drawn: [CGPoint]) -> (quad: [CGPoint], shape: ElementShape)? {
        guard drawn.count >= 3 else { return nil }
        let xs = drawn.map(\.x), ys = drawn.map(\.y)
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        guard x1 - x0 > 1e-4, y1 - y0 > 1e-4 else { return nil }
        let pts = drawn.map { CGPoint(x: ($0.x - x0) / (x1 - x0), y: ($0.y - y0) / (y1 - y0)) }
        return ([CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)],
                ElementShape(kind: .pen, points: pts))
    }
}

// MARK: - Recognizing the shape

/// Looks inside a frame drawn roughly around the element for a star, a round or oval shape, and lays that shape
/// exactly on the element's outline. Each model is moved, sized and turned until its outline runs along the edges
/// of the photo (an edge crossing the outline does not count), and the model that follows the edges best wins.
enum ShapeDetector {
    struct Result {
        var kind: ShapeKind
        var quad: [CGPoint]     // pixels of the photo given
        var shape: ElementShape
        var score: Double
    }

    /// Gradient of the colours (the strongest channel at each pixel) of a crop of the photo.
    private struct Field {
        let w: Int, h: Int
        var gx: [Float], gy: [Float]
        var mean: Float
        func at(_ x: Double, _ y: Double) -> (Float, Float) {
            guard x >= 0, y >= 0, x < Double(w - 1), y < Double(h - 1) else { return (0, 0) }
            let x0 = Int(x), y0 = Int(y), fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            let i = y0 * w + x0
            func bil(_ p: [Float]) -> Float {
                let t = p[i] + (p[i + 1] - p[i]) * fx, b = p[i + w] + (p[i + w + 1] - p[i + w]) * fx
                return t + (b - t) * fy
            }
            return (bil(gx), bil(gy))
        }
    }

    /// Crop of `img` around `quad` (and a quarter more), long side 240 px: its gradient, and how to go back to the
    /// photo's pixels.
    private static func field(_ img: ColorImage, around quad: [CGPoint]) -> (field: Field, ox: Double, oy: Double, s: Double)? {
        let xs = quad.map { Double($0.x) }, ys = quad.map { Double($0.y) }
        let bw = xs.max()! - xs.min()!, bh = ys.max()! - ys.min()!
        guard bw > 6, bh > 6 else { return nil }
        let pad = 0.25 * max(bw, bh)
        let ox = xs.min()! - pad, oy = ys.min()! - pad
        let s = 240 / (max(bw, bh) + 2 * pad)
        let w = Int((bw + 2 * pad) * s), h = Int((bh + 2 * pad) * s)
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        for j in 0..<h {
            for i in 0..<w {
                let c = img.sample(ox + (Double(i) + 0.5) / s, oy + (Double(j) + 0.5) / s)
                r[j * w + i] = c.0; g[j * w + i] = c.1; b[j * w + i] = c.2
            }
        }
        var gx = [Float](repeating: 0, count: w * h), gy = gx
        var total: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                var best: Float = -1, bx: Float = 0, by: Float = 0
                for p in [r, g, b] {
                    let dx = (p[i - w + 1] + 2 * p[i + 1] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - 1] + p[i + w - 1])
                    let dy = (p[i + w - 1] + 2 * p[i + w] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - w] + p[i - w + 1])
                    let m = dx * dx + dy * dy
                    if m > best { best = m; bx = dx; by = dy }
                }
                // Square root of the strength (as for the contours): faint edges count, strong ones do not dominate.
                let m = sqrt(best), k = m > 0 ? sqrt(m) / m : 0
                gx[i] = bx * k; gy[i] = by * k
                total += sqrt(m)
            }
        }
        return (Field(w: w, h: h, gx: gx, gy: gy, mean: max(total / Float(w * h), 1e-3)), ox, oy, s)
    }

    /// How well the outline of `shape` in the frame `quad` (pixels of `img`) runs along edges of the photo: about 1
    /// or more on a clear outline, near 0 on texture.
    static func agreement(in img: ColorImage, quad: [CGPoint], shape: ElementShape) -> Double {
        guard let (field, ox, oy, s) = field(img, around: quad) else { return 0 }
        let m = fitTransform(from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)],
                             to: quad.map { CGPoint(x: (Double($0.x) - ox) * s, y: (Double($0.y) - oy) * s) }, model: .homography)
        return follow(field, shape.outline().map(m.apply))
    }

    /// `quad`: the frame drawn, in pixels of `img`. `only`: look for this shape only.
    static func detect(in img: ColorImage, quad: [CGPoint], only: ShapeKind? = nil) -> Result? {
        guard let (field, ox, oy, s) = field(img, around: quad) else { return nil }
        let xs = quad.map { Double($0.x) }, ys = quad.map { Double($0.y) }
        let bw = xs.max()! - xs.min()!, bh = ys.max()! - ys.min()!

        // The drawn frame in the crop.
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        let center = CGPoint(x: (cx - ox) * s, y: (cy - oy) * s)
        let size = max(bw, bh) * s

        var results: [Result] = []
        func back(_ q: [CGPoint]) -> [CGPoint] { q.map { CGPoint(x: Double($0.x) / s + ox, y: Double($0.y) / s + oy) } }
        if only == nil || only == .star, let (p, sc) = fitStar(field, center: center, size: size) {
            let (c, R, rho, phi) = (CGPoint(x: p[0], y: p[1]), p[2], p[3], p[4])
            results.append(Result(kind: .star, quad: back(square(c, half: R, turn: phi + .pi / 2)),
                                  shape: ElementShape(kind: .star, inner: rho), score: sc))
        }
        if only == nil || only == .ellipse, let (p, sc) = fitEllipse(field, center: center, size: size) {
            let c = CGPoint(x: p[0], y: p[1])
            results.append(Result(kind: .ellipse, quad: back(box(c, a: p[2], b: p[3], turn: p[4])),
                                  shape: ElementShape(kind: .ellipse), score: sc))
        }
        if only == nil, let (p, sc) = fitRect(field, center: center, size: size) {
            let c = CGPoint(x: p[0], y: p[1])
            results.append(Result(kind: .rect, quad: back(box(c, a: p[2], b: p[3], turn: p[4])),
                                  shape: ElementShape(kind: .rect), score: sc))
        }
        guard !results.isEmpty else { return nil }
        if only != nil { return results.max { $0.score < $1.score } }
        // A star has more ways to fit by chance than an oval, and an oval than a box: each must do clearly better.
        let rect = results.first { $0.kind == .rect }?.score ?? 0
        let ell = results.first { $0.kind == .ellipse }?.score ?? 0
        let star = results.first { $0.kind == .star }?.score ?? 0
        if star > 0.9, star > 1.12 * max(ell, rect) { return results.first { $0.kind == .star } }
        if ell > 0.9, ell > 1.08 * rect { return results.first { $0.kind == .ellipse } }
        return results.first { $0.kind == .rect }
    }

    // MARK: Models

    private static func square(_ c: CGPoint, half: Double, turn: Double) -> [CGPoint] { box(c, a: half, b: half, turn: turn) }

    /// Corners TL TR BR BL of a box of half sides `a` (along `turn`) and `b`.
    private static func box(_ c: CGPoint, a: Double, b: Double, turn: Double) -> [CGPoint] {
        let ca = cos(turn), sa = sin(turn)
        return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { u, v in
            let x = u * a, y = v * b
            return CGPoint(x: Double(c.x) + x * ca - y * sa, y: Double(c.y) + x * sa + y * ca)
        }
    }

    /// How well a closed outline runs along the edges: the part of the gradient across the outline, minus half the
    /// part along it (an edge that only crosses the outline), against the average edge of the crop.
    private static func follow(_ field: Field, _ poly: [CGPoint]) -> Double {
        var sum = 0.0, n = 0.0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y), len = hypot(dx, dy)
            guard len > 1e-6 else { continue }
            let nx = -dy / len, ny = dx / len
            let steps = max(1, Int(len / 1.5))
            for k in 0..<steps {
                let t = (Double(k) + 0.5) / Double(steps)
                let (gx, gy) = field.at(Double(a.x) + t * dx, Double(a.y) + t * dy)
                let across = abs(Double(gx) * nx + Double(gy) * ny), along = abs(Double(gx) * ny - Double(gy) * nx)
                sum += across - 0.5 * along
                n += 1
            }
        }
        return n > 0 ? sum / n / Double(field.mean) : 0
    }

    private static func starOutline(_ p: [Double]) -> [CGPoint] {
        (0..<10).map { i in
            let a = p[4] + Double(i) * .pi / 5, r = i % 2 == 0 ? p[2] : p[2] * p[3]
            return CGPoint(x: p[0] + r * cos(a), y: p[1] + r * sin(a))
        }
    }

    private static func ellipseOutline(_ p: [Double]) -> [CGPoint] {
        let ca = cos(p[4]), sa = sin(p[4])
        return (0..<72).map { i in
            let t = Double(i) / 72 * 2 * .pi, x = p[2] * cos(t), y = p[3] * sin(t)
            return CGPoint(x: p[0] + x * ca - y * sa, y: p[1] + x * sa + y * ca)
        }
    }

    private static func rectOutline(_ p: [Double]) -> [CGPoint] { box(CGPoint(x: p[0], y: p[1]), a: p[2], b: p[3], turn: p[4]) }

    /// Coarse grid over the parameters, then the best few refined step by step.
    private static func optimize(_ field: Field, grid: [[Double]], steps: [Double], limits: [ClosedRange<Double>],
                                 outline: ([Double]) -> [CGPoint]) -> ([Double], Double)? {
        func value(_ p: [Double]) -> Double {
            for (x, l) in zip(p, limits) where !l.contains(x) { return -9 }
            return follow(field, outline(p))
        }
        var scored: [([Double], Double)] = []
        func walk(_ i: Int, _ p: [Double]) {
            if i == grid.count { scored.append((p, value(p))); return }
            for x in grid[i] { walk(i + 1, p + [x]) }
        }
        walk(0, [])
        scored.sort { $0.1 > $1.1 }
        var best: ([Double], Double)?
        for (start, v0) in scored.prefix(6) {
            var p = start, v = v0, step = steps
            for _ in 0..<200 {
                var improved = false
                for i in p.indices {
                    for d in [step[i], -step[i]] {
                        var q = p; q[i] += d
                        let w = value(q)
                        if w > v { v = w; p = q; improved = true }
                    }
                }
                if !improved {
                    step = step.map { $0 / 2 }
                    if step[2] < 0.25 { break }
                }
            }
            if v > best?.1 ?? -9 { best = (p, v) }
        }
        return best
    }

    private static func around(_ c: Double, _ span: Double, _ n: Int) -> [Double] {
        (0..<n).map { c - span + 2 * span * Double($0) / Double(n - 1) }
    }

    private static func fitStar(_ f: Field, center c: CGPoint, size: Double) -> ([Double], Double)? {
        let cx = Double(c.x), cy = Double(c.y)
        let grid = [around(cx, 0.15 * size, 5), around(cy, 0.15 * size, 5), around(0.42 * size, 0.16 * size, 6),
                    [0.36, 0.44, 0.52, 0.6], (0..<18).map { -Double.pi / 2 + Double($0) * 4 * .pi / 180 }]
        let limits = [(cx - 0.4 * size)...(cx + 0.4 * size), (cy - 0.4 * size)...(cy + 0.4 * size),
                      (0.18 * size)...(0.75 * size), 0.3...0.7, -10.0...10.0]
        return optimize(f, grid: grid, steps: [0.03 * size, 0.03 * size, 0.03 * size, 0.04, 0.05], limits: limits,
                        outline: starOutline)
    }

    private static func fitEllipse(_ f: Field, center c: CGPoint, size: Double) -> ([Double], Double)? {
        let cx = Double(c.x), cy = Double(c.y)
        let grid = [around(cx, 0.15 * size, 5), around(cy, 0.15 * size, 5), around(0.38 * size, 0.16 * size, 5),
                    around(0.38 * size, 0.16 * size, 5), (0..<6).map { Double($0) * .pi / 6 }]
        let limits = [(cx - 0.4 * size)...(cx + 0.4 * size), (cy - 0.4 * size)...(cy + 0.4 * size),
                      (0.12 * size)...(0.75 * size), (0.12 * size)...(0.75 * size), -10.0...10.0]
        return optimize(f, grid: grid, steps: [0.03 * size, 0.03 * size, 0.03 * size, 0.03 * size, 0.06], limits: limits,
                        outline: ellipseOutline)
    }

    private static func fitRect(_ f: Field, center c: CGPoint, size: Double) -> ([Double], Double)? {
        let cx = Double(c.x), cy = Double(c.y)
        let grid = [around(cx, 0.15 * size, 5), around(cy, 0.15 * size, 5), around(0.38 * size, 0.16 * size, 5),
                    around(0.38 * size, 0.16 * size, 5), around(0, 0.35, 5)]
        let limits = [(cx - 0.4 * size)...(cx + 0.4 * size), (cy - 0.4 * size)...(cy + 0.4 * size),
                      (0.12 * size)...(0.75 * size), (0.12 * size)...(0.75 * size), -0.8...0.8]
        return optimize(f, grid: grid, steps: [0.03 * size, 0.03 * size, 0.03 * size, 0.03 * size, 0.04], limits: limits,
                        outline: rectOutline)
    }
}

import CoreGraphics
import Foundation

// Coordinates used everywhere for anchors ("frame space"): origin at the top-left of the
// oriented photo, y pointing down, measured in units of the photo's height.
// A photo of aspect a spans x in [0, a] and y in [0, 1], whatever its resolution,
// so the preview, the tracking image and the full-size export share the same numbers.

struct Mat3: Codable, Equatable, Sendable {
    var m: [Double]  // row-major

    init(_ m: [Double]) { self.m = m }

    static let identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1])
    static func translation(_ x: Double, _ y: Double) -> Mat3 { Mat3([1, 0, x, 0, 1, y, 0, 0, 1]) }
    static func scale(_ sx: Double, _ sy: Double) -> Mat3 { Mat3([sx, 0, 0, 0, sy, 0, 0, 0, 1]) }
    static func rotation(_ a: Double) -> Mat3 {
        let c = cos(a), s = sin(a)
        return Mat3([c, -s, 0, s, c, 0, 0, 0, 1])
    }

    static func * (a: Mat3, b: Mat3) -> Mat3 {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                r[i * 3 + j] = a.m[i * 3] * b.m[j] + a.m[i * 3 + 1] * b.m[3 + j] + a.m[i * 3 + 2] * b.m[6 + j]
            }
        }
        return Mat3(r)
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    var inverse: Mat3? {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7], c01 = a[5] * a[6] - a[3] * a[8], c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-15 else { return nil }
        let inv = [
            c00, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            c01, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            c02, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
        ]
        return Mat3(inv.map { $0 / det })
    }

    var isAffine: Bool { abs(m[6]) < 1e-14 && abs(m[7]) < 1e-14 && abs(m[8] - 1) < 1e-12 }

    var affine: CGAffineTransform {
        CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
    }

    /// How much the transform enlarges things around `p` (1 = same size).
    func localScale(at p: CGPoint) -> Double {
        let o = apply(p)
        let dx = apply(CGPoint(x: p.x + 1, y: p.y)), dy = apply(CGPoint(x: p.x, y: p.y + 1))
        let ax = Double(dx.x - o.x), ay = Double(dx.y - o.y), bx = Double(dy.x - o.x), by = Double(dy.y - o.y)
        return sqrt(abs(ax * by - ay * bx))
    }
}

func centroid(_ pts: [CGPoint]) -> CGPoint {
    guard !pts.isEmpty else { return .zero }
    let sx = pts.reduce(0.0) { $0 + Double($1.x) }, sy = pts.reduce(0.0) { $0 + Double($1.y) }
    return CGPoint(x: sx / Double(pts.count), y: sy / Double(pts.count))
}

enum FitModel: Sendable {
    case translation   // position only
    case rigid         // position + rotation
    case similarity    // position + rotation + scale
    case homography    // full perspective (needs 4 points)
}

/// Transform that sends `src` onto `dst` as closely as the model allows.
func fitTransform(from src: [CGPoint], to dst: [CGPoint], model: FitModel) -> Mat3 {
    let n = src.count
    guard n > 0, n == dst.count else { return .identity }
    let cs = centroid(src), cd = centroid(dst)
    let shift = Mat3.translation(Double(cd.x - cs.x), Double(cd.y - cs.y))
    if model == .translation || n < 2 { return shift }
    if model == .homography, n == 4, let h = homography(src, dst) { return h }

    // Least-squares similarity, written with complex numbers: z = sum(conj(a) * b) / sum(|a|^2).
    var re = 0.0, im = 0.0, den = 0.0
    for i in 0..<n {
        let ax = Double(src[i].x - cs.x), ay = Double(src[i].y - cs.y)
        let bx = Double(dst[i].x - cd.x), by = Double(dst[i].y - cd.y)
        re += ax * bx + ay * by
        im += ax * by - ay * bx
        den += ax * ax + ay * ay
    }
    guard den > 1e-12 else { return shift }
    var zr = re / den, zi = im / den
    if model == .rigid {
        let mag = hypot(zr, zi)
        guard mag > 1e-12 else { return shift }
        zr /= mag; zi /= mag
    }
    let tx = Double(cd.x) - (zr * Double(cs.x) - zi * Double(cs.y))
    let ty = Double(cd.y) - (zi * Double(cs.x) + zr * Double(cs.y))
    return Mat3([zr, -zi, tx, zi, zr, ty, 0, 0, 1])
}

/// Exact perspective transform through four point pairs (nil when three of them are aligned).
private func homography(_ src: [CGPoint], _ dst: [CGPoint]) -> Mat3? {
    var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for i in 0..<4 {
        let x = Double(src[i].x), y = Double(src[i].y), u = Double(dst[i].x), v = Double(dst[i].y)
        a[2 * i] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
        a[2 * i + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
    }
    // Gaussian elimination with partial pivoting on the 8x8 system (last column = right-hand side).
    for col in 0..<8 {
        var pivot = col
        for r in col..<8 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
        guard abs(a[pivot][col]) > 1e-12 else { return nil }
        a.swapAt(col, pivot)
        for r in 0..<8 where r != col {
            let f = a[r][col] / a[col][col]
            if f == 0 { continue }
            for c in col..<9 { a[r][c] -= f * a[col][c] }
        }
    }
    var h = (0..<8).map { a[$0][8] / a[$0][$0] }
    h.append(1)
    return Mat3(h)
}

// MARK: - Anchors and settings

enum AnchorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case point, line, frame
    var id: String { rawValue }
    var label: String {
        switch self {
        case .point: "Point"
        case .line: "Règle"
        case .frame: "Cadre"
        }
    }
    var pointCount: Int {
        switch self {
        case .point: 1
        case .line: 2
        case .frame: 4  // top-left, top-right, bottom-right, bottom-left
        }
    }
}

enum LevelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, horizontal, vertical
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Non"
        case .horizontal: "Horizontale"
        case .vertical: "Verticale"
        }
    }
}

/// Lines that must stay straight on every photo (horizon, a pillar). They only set the rotation:
/// the photo turns around the point to keep them level.
/// The two symmetric lines (mirrorA, mirrorB) lean by the same amount on each side of an axis (the two edges
/// of a door seen from below, two pillars): it is their common axis that is made straight, so perspective cancels.
enum GuideKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case horizontal, vertical, mirrorA, mirrorB
    var id: String { rawValue }
    var label: String {
        switch self {
        case .horizontal: "Horizontale"
        case .vertical: "Verticale"
        case .mirrorA: "Symétrie 1"
        case .mirrorB: "Symétrie 2"
        }
    }
    var isMirror: Bool { self == .mirrorA || self == .mirrorB }

    /// Rotation (radians, y down) that makes the line a -> b exactly horizontal or vertical.
    func correction(_ a: CGPoint, _ b: CGPoint, axis: GuideKind = .vertical) -> Double {
        let level = self == .horizontal || (isMirror && axis == .horizontal)
        let angle = atan2(Double(b.y - a.y), Double(b.x - a.x))
        var d = (level ? 0 : Double.pi / 2) - angle
        d -= (d / .pi).rounded() * .pi
        return d
    }
}

/// Where the rotation of each photo comes from, once the point holds the position.
enum RotationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, follow, keys
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Non"
        case .follow: "Suivies"
        case .keys: "Clés seulement"
        }
    }
}

enum Smoothing: Int, Codable, CaseIterable, Identifiable, Sendable {
    case none = 0, light = 1, strong = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .none: "Non"
        case .light: "Léger"
        case .strong: "Fort"
        }
    }
    /// Width of the gaussian, in photos.
    var sigma: Double { Double(rawValue) }
}

/// What fills the canvas where the aligned photo does not reach: black, or the photo repeated around itself like
/// After Effects' Motion Tile (mirrored or not).
enum EdgeMode: String, Codable, Sendable {
    case black, tile, mirror
}

/// Match cut: size of the element on the output.
enum SizeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case same, progressive
    var id: String { rawValue }
    var label: String { self == .same ? "Identique" : "Zoom progressif" }
}

struct AlignSettings: Codable, Equatable, Sendable {
    var kind: AnchorKind = .point
    var level: LevelMode = .off
    var correctScale = false
    var perspective = true
    var centerAnchor = false
    var advanceOnClick = false
    var zoom: Double = 1.0
    var output: OutputPreset = .uhd
    var fps: FrameRate = .fps25
    var format: ExportFormat = .proRes422HQ
    var rotation: RotationMode = .follow
    var smoothing: Smoothing = .none
    /// Axis of the symmetric lines: .vertical (they lean left and right) or .horizontal.
    var symmetryAxis: GuideKind = .vertical
    /// Match cut: a frame drawn by hand is fitted onto the element of the reference.
    var snapFrames = true
    var sizeMode: SizeMode = .same
    /// Match cut: after the search, the photos are put in order of the element's size, smallest first.
    var autoSort = true
    /// Match cut: how many frames of the video each photo lasts (1, 2 or 3).
    var holdFrames = 1
    /// Match cut: shape of the element (Auto recognizes a star or a round shape in the frame drawn on the reference),
    /// and the shape found or drawn there (nil: the whole frame).
    var shapeKind: ShapeKind = .auto
    var elementShape: ElementShape?
    /// Motion Tile around the photo instead of black edges, and with Mirror the tiles are flipped so seams vanish.
    var motionTile = false
    var tileMirror = true

    var edgeMode: EdgeMode { motionTile ? (tileMirror ? .mirror : .tile) : .black }
    /// Hyperlapse stabilization (after the alignment), see Stabilizer.
    var stabEnabled = false
    var stabResult: StabResult = .smooth
    var stabSmoothness = 50.0
    var stabKeepPoint = true
    var stabRotation = true
    var stabScale = true

    init() {}

    // Written by hand so that a session saved by an older version (without the newer settings) still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlignSettings()
        kind = try c.decodeIfPresent(AnchorKind.self, forKey: .kind) ?? d.kind
        level = try c.decodeIfPresent(LevelMode.self, forKey: .level) ?? d.level
        correctScale = try c.decodeIfPresent(Bool.self, forKey: .correctScale) ?? d.correctScale
        perspective = try c.decodeIfPresent(Bool.self, forKey: .perspective) ?? d.perspective
        centerAnchor = try c.decodeIfPresent(Bool.self, forKey: .centerAnchor) ?? d.centerAnchor
        advanceOnClick = try c.decodeIfPresent(Bool.self, forKey: .advanceOnClick) ?? d.advanceOnClick
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? d.zoom
        output = try c.decodeIfPresent(OutputPreset.self, forKey: .output) ?? d.output
        fps = try c.decodeIfPresent(FrameRate.self, forKey: .fps) ?? d.fps
        format = try c.decodeIfPresent(ExportFormat.self, forKey: .format) ?? d.format
        rotation = try c.decodeIfPresent(RotationMode.self, forKey: .rotation) ?? d.rotation
        smoothing = try c.decodeIfPresent(Smoothing.self, forKey: .smoothing) ?? d.smoothing
        symmetryAxis = try c.decodeIfPresent(GuideKind.self, forKey: .symmetryAxis) ?? d.symmetryAxis
        snapFrames = try c.decodeIfPresent(Bool.self, forKey: .snapFrames) ?? d.snapFrames
        sizeMode = try c.decodeIfPresent(SizeMode.self, forKey: .sizeMode) ?? d.sizeMode
        autoSort = try c.decodeIfPresent(Bool.self, forKey: .autoSort) ?? d.autoSort
        holdFrames = min(max(try c.decodeIfPresent(Int.self, forKey: .holdFrames) ?? d.holdFrames, 1), 3)
        shapeKind = try c.decodeIfPresent(ShapeKind.self, forKey: .shapeKind) ?? d.shapeKind
        elementShape = try c.decodeIfPresent(ElementShape.self, forKey: .elementShape)
        motionTile = try c.decodeIfPresent(Bool.self, forKey: .motionTile) ?? d.motionTile
        tileMirror = try c.decodeIfPresent(Bool.self, forKey: .tileMirror) ?? d.tileMirror
        stabEnabled = try c.decodeIfPresent(Bool.self, forKey: .stabEnabled) ?? d.stabEnabled
        stabResult = try c.decodeIfPresent(StabResult.self, forKey: .stabResult) ?? d.stabResult
        stabSmoothness = try c.decodeIfPresent(Double.self, forKey: .stabSmoothness) ?? d.stabSmoothness
        stabKeepPoint = try c.decodeIfPresent(Bool.self, forKey: .stabKeepPoint) ?? d.stabKeepPoint
        stabRotation = try c.decodeIfPresent(Bool.self, forKey: .stabRotation) ?? d.stabRotation
        stabScale = try c.decodeIfPresent(Bool.self, forKey: .stabScale) ?? d.stabScale
    }

    var fitModel: FitModel {
        switch kind {
        case .point: .translation
        case .line: correctScale ? .similarity : .rigid
        case .frame: perspective ? .homography : (correctScale ? .similarity : .rigid)
        }
    }
}

/// Everything needed to place any photo of the series on the output canvas.
struct AlignmentPlan: Sendable {
    var refPoints: [CGPoint]
    var refAspect: Double
    var settings: AlignSettings

    /// Photo k (frame space) -> reference photo (frame space).
    func frameToRef(_ pts: [CGPoint]) -> Mat3 {
        guard pts.count == refPoints.count else { return .identity }
        return fitTransform(from: pts, to: refPoints, model: settings.fitModel)
    }

    /// Reference photo (frame space) -> output canvas (pixels, y down).
    /// The reference fills the canvas (cropping the overflow), then the optional zoom,
    /// recentering on the anchor and leveling are applied.
    func refToCanvas(_ canvas: CGSize) -> Mat3 {
        let w = Double(canvas.width), h = Double(canvas.height)
        let s = max(w / refAspect, h) * settings.zoom
        let c = centroid(refPoints)
        let pivot = settings.centerAnchor ? c : CGPoint(x: refAspect / 2, y: 0.5)
        return .translation(w / 2, h / 2) * .scale(s, s)
            * .translation(Double(c.x - pivot.x), Double(c.y - pivot.y))
            * .rotation(levelAngle) * .translation(-Double(c.x), -Double(c.y))
    }

    /// Rotation that makes the reference line (or the frame's top / left edge) exactly level.
    var levelAngle: Double {
        guard settings.level != .off, settings.kind != .point else { return 0 }
        let a: CGPoint, b: CGPoint
        if settings.kind == .frame, refPoints.count == 4 {
            (a, b) = settings.level == .horizontal ? (refPoints[0], refPoints[1]) : (refPoints[0], refPoints[3])
        } else if refPoints.count >= 2 {
            (a, b) = (refPoints[0], refPoints[1])
        } else { return 0 }
        return (settings.level == .horizontal ? GuideKind.horizontal : .vertical).correction(a, b)
    }
}

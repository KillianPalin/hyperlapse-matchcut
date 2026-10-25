import AppKit
import SwiftUI

/// Where a photo (in frame space) sits in a view.
struct Fit {
    let rect: CGRect

    init(rect: CGRect) { self.rect = rect }

    init(container: CGSize, aspect: Double, inset: CGFloat = 24) {
        let w = max(container.width - 2 * inset, 10), h = max(container.height - 2 * inset, 10)
        let unit = min(w / aspect, h)
        let size = CGSize(width: aspect * unit, height: unit)
        rect = CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// View points per frame unit (the photo's height).
    var unit: CGFloat { rect.height }
    func view(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * unit, y: rect.minY + p.y * unit) }
    func frame(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - rect.minX) / unit, y: (v.y - rect.minY) / unit) }

    /// The same photo enlarged `zoom` times around its centre, then moved by `pan`.
    func zoomed(_ zoom: CGFloat, pan: CGSize) -> Fit {
        let w = rect.width * zoom, h = rect.height * zoom
        return Fit(rect: CGRect(x: rect.midX - w / 2 + pan.width, y: rect.midY - h / 2 + pan.height, width: w, height: h))
    }
}

enum Palette {
    static let anchor = Theme.anchor
    static let doubtful = Theme.negative
    static let target = Theme.text  // where the anchor must land, drawn in ink
    static let canvas = Theme.well

    static func status(_ s: FrameStatus) -> Color {
        switch s {
        case .none: Theme.faint
        case .manual: Theme.anchor
        case .tracked: Theme.tracked
        case .doubtful, .estimated: Theme.negative
        }
    }
}

/// Draws an anchor (already converted to view coordinates).
func drawAnchor(_ ctx: inout GraphicsContext, _ pts: [CGPoint], kind: AnchorKind, color: Color, ghost: Bool, bounds: CGRect) {
    let line = StrokeStyle(lineWidth: ghost ? 1.5 : 2, lineCap: .round, dash: ghost ? [5, 4] : [])
    let c = ghost ? Color.white.opacity(0.6) : color
    // Dark outline under everything so the anchor stays visible on bright photos.
    func stroke(_ path: Path, _ style: StrokeStyle) {
        ctx.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: style.lineWidth + 2, lineCap: .round, dash: style.dash))
        ctx.stroke(path, with: .color(c), style: style)
    }
    func handle(_ p: CGPoint, square: Bool = false) {
        let r: CGFloat = 6
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let path = square ? Path(rect) : Path(ellipseIn: rect)
        if !ghost { ctx.fill(path, with: .color(c.opacity(0.25))) }
        stroke(path, line)
    }
    switch kind {
    case .point:
        guard let p = pts.first else { return }
        let r: CGFloat = 10
        handle(p)
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - r - 14, y: p.y)); cross.addLine(to: CGPoint(x: p.x - r + 2, y: p.y))
        cross.move(to: CGPoint(x: p.x + r - 2, y: p.y)); cross.addLine(to: CGPoint(x: p.x + r + 14, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - r - 14)); cross.addLine(to: CGPoint(x: p.x, y: p.y - r + 2))
        cross.move(to: CGPoint(x: p.x, y: p.y + r - 2)); cross.addLine(to: CGPoint(x: p.x, y: p.y + r + 14))
        stroke(cross, line)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(c))
    case .line:
        guard pts.count == 2 else { return }
        // The ruler extended across the photo, then the part actually placed.
        let d = CGPoint(x: pts[1].x - pts[0].x, y: pts[1].y - pts[0].y)
        let len = max(hypot(d.x, d.y), 0.001)
        let far = (bounds.width + bounds.height) / len
        var ext = Path()
        ext.move(to: CGPoint(x: pts[0].x - d.x * far, y: pts[0].y - d.y * far))
        ext.addLine(to: CGPoint(x: pts[0].x + d.x * far, y: pts[0].y + d.y * far))
        var clipped = ctx
        clipped.clip(to: Path(bounds))
        clipped.stroke(ext, with: .color(c.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        var seg = Path()
        seg.move(to: pts[0]); seg.addLine(to: pts[1])
        stroke(seg, line)
        handle(pts[0]); handle(pts[1])
    case .frame:
        guard pts.count == 4 else { return }
        var quad = Path()
        quad.addLines(pts); quad.closeSubpath()
        if !ghost { ctx.fill(quad, with: .color(c.opacity(0.08))) }
        stroke(quad, line)
        let m = centroid(pts)
        var cross = Path()
        cross.move(to: CGPoint(x: m.x - 8, y: m.y)); cross.addLine(to: CGPoint(x: m.x + 8, y: m.y))
        cross.move(to: CGPoint(x: m.x, y: m.y - 8)); cross.addLine(to: CGPoint(x: m.x, y: m.y + 8))
        stroke(cross, StrokeStyle(lineWidth: 1))
        for p in pts { handle(p, square: true) }
    }
}

// MARK: - Placing the anchor

struct PlaceView: View {
    @ObservedObject var project: Project

    private enum DragKind {
        case handle(Int, [CGPoint])
        case move([CGPoint])
        case create(CGPoint)
    }

    @State private var drag: DragKind?
    @State private var live: [CGPoint]?
    @State private var loupeAt: CGPoint?
    @State private var hover: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { geo in
            let aspect = project.currentAspect
            let fit = Fit(container: geo.size, aspect: aspect).zoomed(project.canvasZoom, pan: project.canvasPan)
            ZStack(alignment: .topLeading) {
                Palette.canvas
                photo(fit)
                Canvas { ctx, _ in drawOverlay(&ctx, fit) }
                    .allowsHitTesting(false)
                if let at = loupeAt, let img = project.preview, project.canvasZoom < 3 {
                    let onLeft = fit.view(at).x > geo.size.width / 2
                    Loupe(image: img, at: at, aspect: aspect, unit: fit.unit)
                        .offset(x: onLeft ? 16 : geo.size.width - 16 - Loupe.size, y: 16)
                        .allowsHitTesting(false)
                }
                if project.canvasZoom > 1.001 {
                    HStack(spacing: 8) {
                        Text("\(Int((project.canvasZoom * 100).rounded())) %").monospacedDigit().foregroundStyle(Theme.text)
                        Button("Ajuster ⌘0") { project.fitCanvas() }.buttonStyle(HLButtonStyle(kind: .secondary, height: 24))
                    }
                    .font(Theme.small)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.surface))
                    .offset(x: 12, y: geo.size.height - 48)
                }
            }
            .contentShape(Rectangle())
            .gesture(gesture(fit, aspect))
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .onAppear { canvasSize = geo.size; installMonitor() }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
        }
    }

    /// Pinch or mouse wheel zooms around the pointer; two fingers on a trackpad move the enlarged photo.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard let at = hover, project.preview != nil else { return event }
            if event.type == .magnify {
                zoom(by: 1 + event.magnification, at: at)
                return nil
            }
            let zoomKey = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
            if event.hasPreciseScrollingDeltas, !zoomKey {
                guard project.canvasZoom > 1.001 else { return event }
                setPan(CGSize(width: project.canvasPan.width + event.scrollingDeltaX,
                              height: project.canvasPan.height + event.scrollingDeltaY))
                return nil
            }
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.12
            zoom(by: exp(step), at: at)
            return nil
        }
    }

    /// Zooms keeping the point of the photo under `v` where it is.
    private func zoom(by factor: CGFloat, at v: CGPoint) {
        let base = Fit(container: canvasSize, aspect: project.currentAspect)
        let z1 = project.canvasZoom, z2 = min(max(z1 * factor, 1), 8)
        let fp = base.zoomed(z1, pan: project.canvasPan).frame(v)
        let w = base.rect.width, h = base.rect.height
        project.canvasZoom = z2
        if z2 <= 1.001 { project.canvasPan = .zero; return }
        setPan(CGSize(width: v.x - fp.x * h * z2 - base.rect.midX + w * z2 / 2,
                      height: v.y - fp.y * h * z2 - base.rect.midY + h * z2 / 2))
    }

    /// Keeps at least half of the enlarged photo on screen.
    private func setPan(_ p: CGSize) {
        let base = Fit(container: canvasSize, aspect: project.currentAspect)
        let mx = base.rect.width * project.canvasZoom / 2, my = base.rect.height * project.canvasZoom / 2
        project.canvasPan = CGSize(width: min(max(p.width, -mx), mx), height: min(max(p.height, -my), my))
    }

    @ViewBuilder private func photo(_ fit: Fit) -> some View {
        if let img = project.preview {
            Image(decorative: img, scale: 1).resizable().interpolation(.high)
                .frame(width: fit.rect.width, height: fit.rect.height)
                .offset(x: fit.rect.minX, y: fit.rect.minY)
        } else {
            ZStack {
                if let f = project.currentFrame, let t = project.thumbnails[f.id] {
                    Image(decorative: t, scale: 1).resizable().opacity(0.5)
                }
                ProgressView().controlSize(.large)
            }
            .frame(width: fit.rect.width, height: fit.rect.height)
            .offset(x: fit.rect.minX, y: fit.rect.minY)
        }
    }

    /// Shape of what a click edits: the anchor, or a line for the orientation.
    private var editKind: AnchorKind { project.editTarget.guide != nil ? .line : project.settings.kind }

    private func drawOverlay(_ ctx: inout GraphicsContext, _ fit: Fit) {
        guard let frame = project.currentFrame else { return }
        let target = project.editTarget
        // The lines not being edited, in a quiet dashed white with their name.
        if project.guidesAvailable {
            for g in GuideKind.allCases where target.guide != g {
                guard let pts = frame.guide(g)?.points else { continue }
                drawAnchor(&ctx, pts.map(fit.view), kind: .line, color: .white, ghost: true, bounds: fit.rect)
                tag(&ctx, g.label, pts.map(fit.view), .white.opacity(0.7))
            }
        }
        if target != .anchor, let pts = frame.points {
            // The point stays visible as a landmark while a line is edited.
            drawAnchor(&ctx, pts.map(fit.view), kind: project.settings.kind, color: Palette.status(frame.status).opacity(0.8),
                       ghost: false, bounds: fit.rect)
        }
        let status = project.status(at: project.current)
        if let pts = live ?? project.targetPoints(at: project.current) {
            let color = (status == .doubtful || status == .estimated) && live == nil ? Palette.doubtful
                : (status == .tracked && live == nil && target != .anchor ? Palette.status(.tracked) : Palette.anchor)
            drawAnchor(&ctx, pts.map(fit.view), kind: editKind, color: color, ghost: false, bounds: fit.rect)
            if let g = target.guide { tag(&ctx, g.label, pts.map(fit.view), color) }
        } else if let guide = project.guidePoints(at: project.current) {
            drawAnchor(&ctx, guide.map(fit.view), kind: editKind, color: Palette.anchor, ghost: true, bounds: fit.rect)
            if let g = target.guide { tag(&ctx, g.label + " · glisse une poignée pour la poser ici", guide.map(fit.view), .white.opacity(0.7)) }
        }
    }

    /// Name of a line, written next to its far end.
    private func tag(_ ctx: inout GraphicsContext, _ text: String, _ pts: [CGPoint], _ color: Color) {
        guard pts.count == 2 else { return }
        let end = pts[0].x > pts[1].x ? pts[0] : pts[1]
        let label = Text(text).font(Theme.font(12, .semibold)).foregroundColor(color)
        ctx.draw(label, at: CGPoint(x: end.x, y: end.y - 16), anchor: .bottomTrailing)
    }

    private func gesture(_ fit: Fit, _ aspect: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                // The anchor can be placed while the photo is still decoding (its shape is known from the file).
                // Match cut: a photo can be corrected while the search goes on with the others.
                guard !project.isTracking || project.isMatchCut, project.currentFrame != nil else { return }
                func clamp(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: min(max(p.x, 0), aspect), y: min(max(p.y, 0), 1))
                }
                let start = clamp(fit.frame(v.startLocation)), loc = clamp(fit.frame(v.location))
                if drag == nil { drag = begin(at: v.startLocation, start: start, fit) }
                switch drag {
                case .handle(let i, var base)?:
                    base[i] = loc
                    live = base; loupeAt = loc
                case .move(let base)?:
                    live = base.map { CGPoint(x: $0.x + loc.x - start.x, y: $0.y + loc.y - start.y) }
                    loupeAt = nil
                case .create(let s)?:
                    live = shape(from: s, to: loc); loupeAt = loc
                case nil: break
                }
            }
            .onEnded { _ in
                defer { drag = nil; live = nil; loupeAt = nil }
                guard let pts = live else { return }
                if case .create? = drag {
                    let far = pts[pts.count == 4 ? 2 : pts.count - 1]  // opposite corner, or the other end
                    let size = hypot(pts[0].x - far.x, pts[0].y - far.y)
                    if size < 0.01 { return }  // a simple click, not a drawing
                }
                var drawn = false
                if case .create? = drag { drawn = true }
                // Match cut: a frame just drawn is fitted on the element; a corner moved by hand stays where it is put.
                project.setPoints(pts, at: project.current, snap: project.editTarget.guide != nil || (project.isMatchCut && drawn))
                if project.settings.advanceOnClick, project.settings.kind == .point, project.editTarget == .anchor { project.step(1) }
            }
    }

    private func begin(at v: CGPoint, start: CGPoint, _ fit: Fit) -> DragKind {
        let kind = editKind
        let existing = project.targetPoints(at: project.current) ?? project.guidePoints(at: project.current)
        if let ex = existing, ex.count == kind.pointCount {
            let views = ex.map(fit.view)
            if let i = views.indices.min(by: { hypot(views[$0].x - v.x, views[$0].y - v.y) < hypot(views[$1].x - v.x, views[$1].y - v.y) }),
               hypot(views[i].x - v.x, views[i].y - v.y) < 14 {
                return .handle(i, ex)
            }
            if kind == .frame, Path { p in p.addLines(views); p.closeSubpath() }.contains(v) { return .move(ex) }
            if kind == .line, distance(v, toSegment: views[0], views[1]) < 8 { return .move(ex) }
        }
        return kind == .point ? .handle(0, [start]) : .create(start)
    }

    private func shape(from s: CGPoint, to e: CGPoint) -> [CGPoint] {
        switch editKind {
        case .point: return [e]
        case .line: return [s, e]
        case .frame:
            let x0 = min(s.x, e.x), x1 = max(s.x, e.x), y0 = min(s.y, e.y), y1 = max(s.y, e.y)
            return [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
        }
    }

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 0.0001)))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Magnified view around the point being placed.
struct Loupe: View {
    static let size: CGFloat = 180
    static let zoom: CGFloat = 4
    let image: CGImage
    let at: CGPoint
    let aspect: Double
    let unit: CGFloat

    var body: some View {
        let u = unit * Self.zoom
        let s = Self.size
        ZStack(alignment: .topLeading) {
            Color.black
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
                .frame(width: aspect * u, height: u)
                .offset(x: s / 2 - at.x * u, y: s / 2 - at.y * u)
            Path { p in
                p.move(to: CGPoint(x: s / 2, y: s / 2 - 22)); p.addLine(to: CGPoint(x: s / 2, y: s / 2 - 5))
                p.move(to: CGPoint(x: s / 2, y: s / 2 + 5)); p.addLine(to: CGPoint(x: s / 2, y: s / 2 + 22))
                p.move(to: CGPoint(x: s / 2 - 22, y: s / 2)); p.addLine(to: CGPoint(x: s / 2 - 5, y: s / 2))
                p.move(to: CGPoint(x: s / 2 + 5, y: s / 2)); p.addLine(to: CGPoint(x: s / 2 + 22, y: s / 2))
            }
            .stroke(Palette.anchor, lineWidth: 1.5)
        }
        .frame(width: s, height: s, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 2))
        .shadow(color: .black.opacity(0.5), radius: 10)
    }
}

// MARK: - Aligned preview

struct AlignedView: View {
    @ObservedObject var project: Project

    var body: some View {
        GeometryReader { geo in
            let canvas = project.previewCanvas
            let fit = Fit(container: geo.size, aspect: canvas.width / canvas.height)
            ZStack(alignment: .topLeading) {
                Palette.canvas
                Rectangle().fill(.black)
                    .frame(width: fit.rect.width, height: fit.rect.height)
                    .offset(x: fit.rect.minX, y: fit.rect.minY)
                if let img = project.playbackFrame ?? project.aligned {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .offset(x: fit.rect.minX, y: fit.rect.minY)
                }
                if project.playbackFrame == nil, let ref = project.alignedReference, project.onion > 0 {
                    Image(decorative: ref, scale: 1).resizable().interpolation(.high)
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .offset(x: fit.rect.minX, y: fit.rect.minY)
                        .opacity(project.onion)
                }
                Canvas { ctx, _ in drawTarget(&ctx, fit, canvas) }
                    .allowsHitTesting(false)
                if project.plan == nil {
                    message("Place le repère sur la photo de référence (n° \(project.refIndex + 1)) pour voir l'alignement.")
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let p = project.playbackProgress {
                    VStack(spacing: 8) {
                        ProgressView(value: p).frame(width: 220)
                        Text("Préparation de la lecture…").font(Theme.body).foregroundStyle(.secondary)
                    }
                    .padding(16).background(RoundedRectangle(cornerRadius: Theme.radiusPanel).fill(Theme.surface))
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Theme.body).multilineTextAlignment(.center)
            .padding(14).frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: Theme.radiusPanel).fill(Theme.surface))
    }

    /// Where the anchor must land on every photo (taken from the reference).
    private func drawTarget(_ ctx: inout GraphicsContext, _ fit: Fit, _ canvas: CGSize) {
        guard let plan = project.plan, project.playbackFrame == nil else { return }
        let g = plan.refToCanvas(canvas)
        let k = fit.rect.height / canvas.height
        let pts = plan.refPoints.map { p -> CGPoint in
            let c = g.apply(p)
            return CGPoint(x: fit.rect.minX + c.x * k, y: fit.rect.minY + c.y * k)
        }
        // With lines, a level and a plumb reference through the target: what must look straight is judged against them.
        if project.guidesAvailable, project.settings.rotation != .off, let c = pts.first {
            var refs = Path()
            let mirror = project.frames.contains { $0.guide(.mirrorA) != nil }
            if project.frames.contains(where: { $0.guide(.horizontal) != nil }) || (mirror && project.settings.symmetryAxis == .horizontal) {
                refs.move(to: CGPoint(x: fit.rect.minX, y: c.y)); refs.addLine(to: CGPoint(x: fit.rect.maxX, y: c.y))
            }
            if project.frames.contains(where: { $0.guide(.vertical) != nil }) || (mirror && project.settings.symmetryAxis == .vertical) {
                refs.move(to: CGPoint(x: c.x, y: fit.rect.minY)); refs.addLine(to: CGPoint(x: c.x, y: fit.rect.maxY))
            }
            ctx.stroke(refs, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
        drawAnchor(&ctx, pts, kind: plan.settings.kind, color: Palette.target, ghost: false, bounds: fit.rect)
    }
}

import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

enum FrameStatus: String, Codable {
    case none       // no anchor yet
    case manual     // placed by hand
    case tracked    // found by the tracking
    case doubtful   // found by the tracking, worth a look
    case estimated  // hidden or unclear: placed between the photo before and the photo after
}

struct Frame: Identifiable, Codable {
    var id = UUID()
    var url: URL
    var pixelSize: CGSize
    var points: [CGPoint]?
    var status: FrameStatus = .none
    var score: Double?
    /// Lines that must stay straight (they set the rotation of the photo, around the point).
    var guides: Guides?

    var aspect: Double { Double(pixelSize.width / max(pixelSize.height, 1)) }

    var anchor: Anchor {
        get { Anchor(points: points, status: status, score: score) }
        set { points = newValue.points; status = newValue.status; score = newValue.score }
    }

    func guide(_ g: GuideKind) -> Anchor? {
        switch g {
        case .horizontal: guides?.horizontal
        case .vertical: guides?.vertical
        case .mirrorA: guides?.mirrorA
        case .mirrorB: guides?.mirrorB
        }
    }

    mutating func setGuide(_ g: GuideKind, _ a: Anchor?) {
        var gs = guides ?? Guides()
        switch g {
        case .horizontal: gs.horizontal = a
        case .vertical: gs.vertical = a
        case .mirrorA: gs.mirrorA = a
        case .mirrorB: gs.mirrorB = a
        }
        guides = gs.isEmpty ? nil : gs
    }

    /// Rotation keyframe set by hand on this photo (radians), added to what the lines give.
    var rotationKey: Double? {
        get { guides?.rotation }
        set {
            var gs = guides ?? Guides()
            gs.rotation = newValue
            guides = gs.isEmpty ? nil : gs
        }
    }
}

struct Guides: Codable, Equatable {
    var horizontal: Anchor?
    var vertical: Anchor?
    var mirrorA: Anchor?
    var mirrorB: Anchor?
    var rotation: Double?
    var isEmpty: Bool { horizontal == nil && vertical == nil && mirrorA == nil && mirrorB == nil && rotation == nil }
}

/// What a click on the photo edits: the point, or one of the two lines that set the rotation.
enum EditTarget: String, CaseIterable, Identifiable {
    case anchor, horizontal, vertical, mirrorA, mirrorB
    var id: String { rawValue }
    var guide: GuideKind? {
        switch self {
        case .anchor: nil
        case .horizontal: .horizontal
        case .vertical: .vertical
        case .mirrorA: .mirrorA
        case .mirrorB: .mirrorB
        }
    }
    var label: String { guide?.label ?? "Point" }
}

/// What a photo knows about its anchor.
struct Anchor: Codable, Equatable {
    var points: [CGPoint]?
    var status: FrameStatus = .none
    var score: Double?
}

/// State restored by Cmd-Z: the anchors of every kind and the reference.
private struct Snapshot {
    var anchors: [UUID: Anchor]
    var kind: AnchorKind
    var refIndex: Int
    var stash: [AnchorKind: [UUID: Anchor]]
    var guides: [UUID: Guides]
    var order: [UUID]
}

/// The two tools of the app, each with its own photos and session: they never touch each other.
enum WorkMode: String, CaseIterable, Identifiable {
    case hyperlapse, matchCut
    var id: String { rawValue }
    var label: String { self == .hyperlapse ? "Hyperlapse" : "Match cut" }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case original, aligned
    var id: String { rawValue }
    var label: String { self == .original ? "Placer" : "Aligné" }
}

private struct ProjectFile: Codable {
    var version = 1
    var frames: [Frame]
    var refIndex: Int
    var settings: AlignSettings
    /// Anchors of the kinds not shown (kind -> photo id -> anchor), kept when switching between point, ruler and frame.
    var stash: [String: [String: Anchor]]?
}

@MainActor
final class Project: ObservableObject {
    @Published var frames: [Frame] = [] { didSet { scheduleSave(); rotations = computeRotations() } }
    @Published var current = 0 { didSet { if current != oldValue { currentChanged() } } }
    @Published var refIndex = 0 { didSet { scheduleSave(); refreshAligned() } }
    @Published var settings = AlignSettings() { didSet { settingsChanged(oldValue) } }
    @Published var viewMode: ViewMode = .original { didSet { refreshAligned() } }
    @Published var onion = 0.35
    @Published var showExport = false
    /// Enlargement of the photo in the Placer view (1 = whole photo) and how far it is moved.
    @Published var canvasZoom: CGFloat = 1
    @Published var canvasPan: CGSize = .zero
    /// What clicks on the photo edit (the point, or a line that keeps the photo straight).
    @Published var editTarget: EditTarget = .anchor
    /// Rotation given to each photo around its point (radians), from the lines.
    @Published private(set) var rotations: [Double] = []

    /// Preview of the current photo (nil while it decodes).
    @Published private(set) var preview: CGImage?
    @Published private(set) var aligned: CGImage?
    @Published private(set) var alignedReference: CGImage?
    @Published private(set) var thumbnails: [UUID: CGImage] = [:]

    @Published private(set) var trackingProgress: Double?
    @Published private(set) var playbackProgress: Double?
    @Published private(set) var playing = false
    @Published private(set) var playbackFrame: CGImage?
    @Published var notice: String?

    let previews = PreviewCache()
    private var previewTask: Task<Void, Never>?
    private var alignTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var playbackFrames: [CGImage] = []
    private var playbackKey: String?

    /// Anchors of the other kinds: switching kind never loses work.
    private var stash: [AnchorKind: [UUID: Anchor]] = [:]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var restoring = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    static let sessionURL: URL = {
        // Tests and screenshots work on their own session, never on the real one.
        if let path = ProcessInfo.processInfo.environment["HYPERLAPSE_SESSION"] { return URL(fileURLWithPath: path) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Hyperlapse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.json")
        // The app was called Repère before: take its last session along.
        let old = support.appendingPathComponent("Repere/session.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: url)
        }
        return url
    }()

    /// Session of the match cut tool, next to the hyperlapse one.
    static let matchCutSessionURL: URL = {
        if let path = ProcessInfo.processInfo.environment["HYPERLAPSE_SESSION"] {
            return URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-matchcut.json")
        }
        return sessionURL.deletingLastPathComponent().appendingPathComponent("matchcut.json")
    }()

    let mode: WorkMode
    let sessionFile: URL
    var isMatchCut: Bool { mode == .matchCut }

    init(mode: WorkMode = .hyperlapse) {
        self.mode = mode
        sessionFile = mode == .hyperlapse ? Self.sessionURL : Self.matchCutSessionURL
        if mode == .matchCut { useFrameAnchor() }
        restoreSession()
    }

    /// A match cut aligns an element by its four corners (position, size, rotation, perspective).
    private func useFrameAnchor() {
        restoring = true
        settings.kind = .frame
        settings.perspective = true
        settings.correctScale = true
        restoring = false
    }

    // MARK: - Derived

    var currentFrame: Frame? { frames.indices.contains(current) ? frames[current] : nil }

    /// Aspect of the current photo, from its decoded preview when available.
    var currentAspect: Double {
        if let p = preview { return Double(p.width) / Double(p.height) }
        return currentFrame?.aspect ?? 1.5
    }

    var plan: AlignmentPlan? {
        guard frames.indices.contains(refIndex), let pts = frames[refIndex].points,
              pts.count == settings.kind.pointCount else { return nil }
        return AlignmentPlan(refPoints: pts, refAspect: frames[refIndex].aspect, settings: settings)
    }

    var outputSize: CGSize {
        if let s = settings.output.size { return s }
        guard frames.indices.contains(refIndex) else { return CGSize(width: 3840, height: 2160) }
        let s = frames[refIndex].pixelSize
        // Even sizes, as video codecs require.
        return CGSize(width: Double(Int(s.width) / 2 * 2), height: Double(Int(s.height) / 2 * 2))
    }

    var anchoredCount: Int { frames.filter { $0.points != nil }.count }
    var doubtfulCount: Int {
        frames.indices.filter { let s = status(at: $0); return s == .doubtful || s == .estimated }.count
    }

    /// The lines only make sense with a point: the point holds the position, the lines the rotation.
    var guidesAvailable: Bool { settings.kind == .point && !isMatchCut }

    /// What is being edited on photo k (the point, or one of the lines).
    func anchor(at k: Int, _ target: EditTarget? = nil) -> Anchor? {
        guard frames.indices.contains(k) else { return nil }
        if let g = (target ?? editTarget).guide { return frames[k].guide(g) }
        return frames[k].anchor
    }

    func targetPoints(at k: Int) -> [CGPoint]? { anchor(at: k)?.points }
    func status(at k: Int) -> FrameStatus { anchor(at: k)?.status ?? .none }

    /// Photos where a line was placed by hand: the keyframes of the rotation.
    func isRotationKey(_ k: Int) -> Bool {
        guard frames.indices.contains(k) else { return false }
        return frames[k].rotationKey != nil || GuideKind.allCases.contains { frames[k].guide($0)?.status == .manual }
    }

    /// What is edited on photo k, or the one of the nearest photo (shown as a guide).
    func guidePoints(at k: Int) -> [CGPoint]? {
        guard frames.indices.contains(k) else { return nil }
        if let p = targetPoints(at: k) { return p }
        for d in 1..<max(frames.count, 2) {
            if let p = targetPoints(at: k - d) { return shifted(p, from: k - d, to: k) }
            if let p = targetPoints(at: k + d) { return shifted(p, from: k + d, to: k) }
        }
        return nil
    }

    /// A line borrowed from another photo follows the point of this photo, so it lands close to its place.
    private func shifted(_ pts: [CGPoint], from a: Int, to b: Int) -> [CGPoint] {
        guard editTarget.guide != nil, let pa = frames[a].points?.first, let pb = frames[b].points?.first else { return pts }
        return pts.map { CGPoint(x: $0.x + pb.x - pa.x, y: $0.y + pb.y - pa.y) }
    }

    /// Photo k -> reference. A photo without anchor borrows the alignment of its nearest neighbour.
    /// With lines, the photo also turns around its point so that they stay straight.
    func frameToRef(_ k: Int, plan: AlignmentPlan) -> Mat3 {
        var src = frames[k].points
        if src == nil {
            for d in 1..<max(frames.count, 2) {
                if k - d >= 0, let p = frames[k - d].points { src = p; break }
                if k + d < frames.count, let p = frames[k + d].points { src = p; break }
            }
        }
        guard let pts = src else { return .identity }
        var base = plan.frameToRef(pts)
        if isMatchCut, settings.sizeMode == .progressive, let m = progressiveScale(k) {
            let c = centroid(plan.refPoints)
            base = .translation(Double(c.x), Double(c.y)) * .scale(m, m) * .translation(-Double(c.x), -Double(c.y)) * base
        }
        let theta = rotations.indices.contains(k) ? rotations[k] : 0
        guard theta != 0, plan.settings.kind == .point, let p = pts.first else { return base }
        return base * .translation(Double(p.x), Double(p.y)) * .rotation(theta) * .translation(-Double(p.x), -Double(p.y))
    }

    // MARK: - Rotation from the lines

    /// Rotation of every photo. Each line gives one where it is known (only on the keyframes in the
    /// "Clés seulement" mode), the photos in between are interpolated, the optional smoothing never moves a keyframe.
    /// The horizontal, the vertical and the pair of symmetric lines (their common axis) are averaged. The rotation
    /// keyframes set by hand are then added, interpolated from one to the next.
    private func computeRotations() -> [Double] {
        let n = frames.count
        var sum = [Double](repeating: 0, count: n), weight = [Double](repeating: 0, count: n)
        guard settings.kind == .point else { return sum }
        if settings.rotation != .off {
            func series(_ g: GuideKind) -> [Double]? {
                var raw = [Double?](repeating: nil, count: n)
                var key = [Bool](repeating: false, count: n)
                for k in 0..<n {
                    guard let a = frames[k].guide(g), let p = a.points, p.count == 2 else { continue }
                    if settings.rotation == .keys, a.status != .manual { continue }
                    raw[k] = g.correction(p[0], p[1], axis: settings.symmetryAxis)
                    key[k] = a.status == .manual
                }
                guard let s = Self.interpolated(raw) else { return nil }
                return settings.rotation == .follow ? Self.smoothed(s, keys: key, sigma: settings.smoothing.sigma) : s
            }
            var parts: [[Double]] = []
            if let h = series(.horizontal) { parts.append(h) }
            if let v = series(.vertical) { parts.append(v) }
            // Two lines leaning by the same amount each side: the average of the two is their axis.
            if let a = series(.mirrorA), let b = series(.mirrorB) { parts.append(zip(a, b).map { ($0 + $1) / 2 }) }
            for part in parts { for k in 0..<n { sum[k] += part[k]; weight[k] += 1 } }
        }
        let manual = Self.interpolated(frames.map(\.rotationKey)) ?? [Double](repeating: 0, count: n)
        return (0..<n).map { (weight[$0] > 0 ? sum[$0] / weight[$0] : 0) + manual[$0] }
    }

    /// Fills the gaps linearly between known values (held before the first and after the last).
    static func interpolated(_ raw: [Double?]) -> [Double]? {
        let known = raw.indices.filter { raw[$0] != nil }
        guard let first = known.first, let last = known.last else { return nil }
        var out = [Double](repeating: 0, count: raw.count)
        for k in raw.indices {
            if let v = raw[k] { out[k] = v; continue }
            if k < first { out[k] = raw[first]!; continue }
            if k > last { out[k] = raw[last]!; continue }
            let a = known.last { $0 < k }!, b = known.first { $0 > k }!
            let t = Double(k - a) / Double(b - a)
            out[k] = raw[a]! + (raw[b]! - raw[a]!) * t
        }
        return out
    }

    /// Gaussian smoothing over the series; the keyframes are put back exactly where they were placed.
    static func smoothed(_ v: [Double], keys: [Bool], sigma: Double) -> [Double] {
        guard sigma > 0, v.count > 2 else { return v }
        let r = Int((3 * sigma).rounded(.up))
        var out = v.indices.map { k -> Double in
            var s = 0.0, w = 0.0
            for j in max(0, k - r)...min(v.count - 1, k + r) {
                let wj = exp(-Double((j - k) * (j - k)) / (2 * sigma * sigma))
                s += v[j] * wj; w += wj
            }
            return s / w
        }
        let residual = v.indices.map { keys[$0] ? v[$0] - out[$0] : nil }
        if let fix = interpolated(residual) { for k in out.indices { out[k] += fix[k] } }
        return out
    }

    // MARK: - Import

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choisis tes photos (ou le dossier qui les contient)"
        panel.prompt = "Importer"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let content = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                             options: [.skipsHiddenFiles])) ?? []
                files += content.filter(ImageLoader.isSupported)
            } else if ImageLoader.isSupported(url) {
                files.append(url)
            }
        }
        guard !files.isEmpty else { notice = "Aucune photo reconnue (RAW, JPG, HEIC, TIFF, PNG)."; return }
        if anchoredCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Remplacer la série en cours ?"
            alert.informativeText = "Les repères déjà placés sur la série actuelle seront perdus."
            alert.addButton(withTitle: "Remplacer")
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        stopEverything()
        previews.removeAll()
        let loaded = files.map { Frame(url: $0, pixelSize: ImageLoader.pixelSize($0) ?? CGSize(width: 3, height: 2)) }
        load(frames: loaded, refIndex: 0)
        notice = isMatchCut
            ? "\(loaded.count) photos importées. Encadre l'élément (logo, forme, texte) sur la photo où il est le plus net, puis ⌘T."
            : "\(loaded.count) photos importées. Place ton repère sur la première."
    }

    private func load(frames newFrames: [Frame], refIndex newRef: Int, stash newStash: [AnchorKind: [UUID: Anchor]] = [:]) {
        thumbnails = [:]
        stash = newStash
        undoStack = []; redoStack = []
        updateUndoFlags()
        frames = newFrames
        refIndex = min(newRef, max(newFrames.count - 1, 0))
        preview = nil
        if current == 0 { currentChanged() } else { current = 0 }
        loadThumbnails()
    }

    private func loadThumbnails() {
        thumbTask?.cancel()
        let items = frames.map { ($0.id, $0.url) }
        thumbTask = Task { [weak self] in
            for chunk in stride(from: 0, to: items.count, by: 8) {
                let part = Array(items[chunk..<min(chunk + 8, items.count)])
                let done = await Task.detached(priority: .utility) {
                    part.compactMap { item in ImageLoader.thumbnail(item.1).map { (item.0, $0) } }
                }.value
                guard let self, !Task.isCancelled else { return }
                for (id, img) in done { self.thumbnails[id] = img }
            }
        }
    }

    func newProject() {
        stopEverything()
        previews.removeAll()
        frames = []
        thumbnails = [:]
        preview = nil
        aligned = nil
        alignedReference = nil
        refIndex = 0
        current = 0
        notice = nil
        stash = [:]
        undoStack = []; redoStack = []
        updateUndoFlags()
    }

    private func stopEverything() {
        trackTask?.cancel(); trackTask = nil; trackingProgress = nil
        trackRun += 1; isTracking = false
        stopPlayback()
    }

    // MARK: - Navigation

    func step(_ d: Int) {
        guard !frames.isEmpty else { return }
        current = min(max(current + d, 0), frames.count - 1)
    }

    func goToNextDoubtful() {
        guard !frames.isEmpty else { return }
        for d in 1...frames.count {
            let k = (current + d) % frames.count
            let st = status(at: k)
            if st == .doubtful || st == .estimated || (editTarget == .anchor && st == .none) { current = k; return }
        }
        notice = editTarget == .anchor ? "Toutes les photos ont un repère validé." : "Aucune ligne à vérifier."
    }

    private func currentChanged() {
        stopPlayback()
        guard let frame = currentFrame else { preview = nil; return }
        let idx = current
        if let img = previews.cached(frame.url) {
            preview = img
            refreshAligned()
            prefetch(after: idx)
            return
        }
        preview = nil
        previewTask?.cancel()
        let previews = self.previews, url = frame.url
        previewTask = Task { [weak self] in
            let img = await Task.detached(priority: .userInitiated) { previews.image(for: url) }.value
            guard let self, !Task.isCancelled, self.current == idx else { return }
            self.preview = img
            if img == nil { self.notice = "Impossible de lire \(url.lastPathComponent)." }
            self.refreshAligned()
            self.prefetch(after: idx)
        }
    }

    private func prefetch(after idx: Int) {
        let urls = [idx + 1, idx + 2, idx - 1].filter { frames.indices.contains($0) }.map { frames[$0].url }
        let previews = self.previews
        Task.detached(priority: .utility) { for u in urls { _ = previews.image(for: u) } }
    }

    // MARK: - Editing anchors

    /// Places what is being edited (the point, or a line) by hand on photo k. A line placed by hand is a
    /// keyframe of the rotation.
    func setPoints(_ pts: [CGPoint], at k: Int, snap: Bool = false) {
        guard frames.indices.contains(k) else { return }
        var pts = pts
        if snap, editTarget.guide != nil, let snapped = snapToEdge(pts, at: k) { pts = snapped }
        let placed = Anchor(points: pts, status: .manual, score: nil)
        if let g = editTarget.guide {
            guard frames[k].guide(g) != placed else { return }
            registerUndo()
            frames[k].setGuide(g, placed)
        } else {
            guard frames[k].anchor != placed else { return }
            registerUndo()
            frames[k].anchor = placed
            // Match cut: the first element framed is the reference, whatever photo it is on.
            if isMatchCut, k != refIndex, frames.indices.contains(refIndex), frames[refIndex].points == nil { refIndex = k }
            if snap, isMatchCut, settings.snapFrames, k != refIndex { fitDrawnFrame(at: k, drawn: pts) }
        }
        invalidatePlayback()
        refreshAligned()
    }

    func clearPoints(at k: Int) {
        guard frames.indices.contains(k), targetPoints(at: k) != nil else { return }
        registerUndo()
        if let g = editTarget.guide { frames[k].setGuide(g, nil) } else { frames[k].anchor = Anchor() }
        invalidatePlayback()
        refreshAligned()
    }

    func clearPoints(after k: Int) {
        guard k + 1 < frames.count else { return }
        registerUndo()
        var updated = frames
        for i in (k + 1)..<frames.count {
            if let g = editTarget.guide { updated[i].setGuide(g, nil) }
            else if i != refIndex { updated[i].anchor = Anchor() }
        }
        frames = updated
        invalidatePlayback()
        refreshAligned()
    }

    private lazy var snapEngine = TrackingEngine(previews: previews)

    /// A line drawn by hand is laid exactly on the straight edge it was drawn along, when there is a clear one
    /// within a few pixels and a degree or two.
    func snapToEdge(_ pts: [CGPoint], at k: Int) -> [CGPoint]? {
        guard pts.count == 2, frames.indices.contains(k), previews.cached(frames[k].url) != nil else { return nil }
        let url = frames[k].url
        let fits = [Float(1), -1].compactMap {
            snapEngine.findEdge(url, predicted: pts, polarity: $0, maxTurn: 2.5 * .pi / 180, radius: 0.008)
        }
        guard let best = fits.max(by: { $0.support < $1.support }), best.support >= 0.6 else { return nil }
        return best.points
    }

    /// With a line selected, turns it around its middle (degrees, positive = clockwise on screen). With the point
    /// selected, turns the photo itself around the point: a rotation keyframe on this photo.
    func rotateGuide(by degrees: Double) {
        guard frames.indices.contains(current) else { return }
        if editTarget == .anchor {
            setRotationKey((frames[current].rotationKey ?? currentManualRotation) + degrees * .pi / 180)
            return
        }
        guard let pts = targetPoints(at: current) ?? guidePoints(at: current), pts.count == 2 else {
            notice = "Trace d'abord la ligne sur la photo."
            return
        }
        let c = centroid(pts), a = degrees * .pi / 180
        let r = Mat3.translation(Double(c.x), Double(c.y)) * .rotation(a) * .translation(-Double(c.x), -Double(c.y))
        setPoints(pts.map(r.apply), at: current)
    }

    func makeReference() {
        guard frames[current].points != nil else { notice = "Place d'abord le repère sur cette photo."; return }
        guard refIndex != current else { return }
        registerUndo()
        refIndex = current
        invalidatePlayback()
    }

    /// Hand-set rotation of the current photo (interpolated between keyframes), in radians.
    var currentManualRotation: Double {
        guard frames.indices.contains(current) else { return 0 }
        return Self.interpolated(frames.map(\.rotationKey))?[current] ?? 0
    }

    /// Sets a rotation keyframe on the current photo (radians, turns the photo around its point).
    func setRotationKey(_ value: Double?) {
        guard frames.indices.contains(current), frames[current].rotationKey != value else { return }
        registerUndo()
        frames[current].rotationKey = value
        invalidatePlayback()
        refreshAligned()
    }

    private func settingsChanged(_ old: AlignSettings) {
        if settings.kind != .point, editTarget != .anchor { editTarget = .anchor }
        if settings.kind != old.kind, !restoring {
            // Each kind keeps its own anchors: put the old ones aside and bring back those of the new kind.
            registerUndo(kind: old.kind)
            trackTask?.cancel()
            stash[old.kind] = currentAnchors()
            apply(stash[settings.kind] ?? [:])
            stash[settings.kind] = nil
        }
        rotations = computeRotations()
        scheduleSave()
        invalidatePlayback()
        refreshAligned()
    }

    // MARK: - Canvas zoom and fine placement

    func zoomCanvas(_ factor: CGFloat) {
        let z2 = min(max(canvasZoom * factor, 1), 8)
        canvasPan = z2 <= 1.001 ? .zero
            : CGSize(width: canvasPan.width * z2 / canvasZoom, height: canvasPan.height * z2 / canvasZoom)
        canvasZoom = z2
    }

    func fitCanvas() {
        canvasZoom = 1
        canvasPan = .zero
    }

    /// Moves the anchor of the current photo by whole pixels of the preview.
    func nudge(_ dx: Int, _ dy: Int) {
        guard frames.indices.contains(current), let p = preview,
              let pts = targetPoints(at: current) ?? guidePoints(at: current) else { return }
        let u = 1 / CGFloat(p.height)
        setPoints(pts.map { CGPoint(x: $0.x + CGFloat(dx) * u, y: $0.y + CGFloat(dy) * u) }, at: current)
    }

    // MARK: - Undo

    private func currentAnchors() -> [UUID: Anchor] {
        Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0.anchor) })
    }

    private func apply(_ anchors: [UUID: Anchor], guides: [UUID: Guides]? = nil) {
        var updated = frames
        for i in updated.indices {
            updated[i].anchor = anchors[updated[i].id] ?? Anchor()
            if let guides { updated[i].guides = guides[updated[i].id] }
        }
        frames = updated
    }

    private func snapshot(kind: AnchorKind? = nil) -> Snapshot {
        let guides = Dictionary(uniqueKeysWithValues: frames.compactMap { f in f.guides.map { (f.id, $0) } })
        return Snapshot(anchors: currentAnchors(), kind: kind ?? settings.kind, refIndex: refIndex, stash: stash, guides: guides,
                        order: frames.map(\.id))
    }

    private func registerUndo(kind: AnchorKind? = nil) {
        undoStack.append(snapshot(kind: kind))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        if isTracking { stopTracking(); return }
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(s)
    }

    func redo() {
        guard !isTracking, let s = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        restoring = true
        if settings.kind != s.kind { settings.kind = s.kind }
        stash = s.stash
        if frames.map(\.id) != s.order {
            // Back to the order of the photos at that time (a sort is undone too).
            let byID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
            let currentID = currentFrame?.id
            frames = s.order.compactMap { byID[$0] }
            if let id = currentID, let i = frames.firstIndex(where: { $0.id == id }) { current = i }
        }
        apply(s.anchors, guides: s.guides)
        if refIndex != s.refIndex { refIndex = s.refIndex }
        restoring = false
        updateUndoFlags()
        invalidatePlayback()
        refreshAligned()
        scheduleSave()
    }

    // MARK: - Tracking

    @Published private(set) var isTracking = false
    /// Number of the tracking run; a step finishing after its run was stopped is dropped.
    private var trackRun = 0

    func trackForward() {
        if isMatchCut { findMatches(); return }
        guard trackTask == nil, let frame = currentFrame else { return }
        guard frame.points != nil else { notice = "Place d'abord le repère sur cette photo."; return }
        guard current + 1 < frames.count else { notice = "C'est la dernière photo."; return }
        registerUndo()  // Cmd-Z cancels the whole tracking run
        if frame.status != .manual {
            // Starting from a tracked photo: treat it as validated.
            frames[current].status = .manual
        }
        let start = current
        trackRun += 1
        let run = trackRun
        isTracking = true
        trackTask = Task { [weak self] in await self?.runTracking(from: start, run: run) }
    }

    /// Stops at once: the photo being analysed is dropped and the anchor can be placed by hand right away.
    func stopTracking() {
        guard isTracking else { return }
        trackTask?.cancel(); trackTask = nil
        trackRun += 1
        isTracking = false
        trackingProgress = nil
        notice = "Suivi arrêté sur la photo \(current + 1). Replace le repère si besoin, puis relance le suivi (⌘T)."
        invalidatePlayback()
        refreshAligned()
    }

    private func runTracking(from start: Int, run: Int) async {
        trackingProgress = 0
        notice = nil
        let engine = TrackingEngine(previews: previews)
        var key = start
        var prev = start
        var motion: [CGPoint]?
        var keyScales: [Double]?  // zoom of the previous photo relative to the hand-placed one
        let total = Double(frames.count - 1 - start)
        var lost: Int?
        var estimated = 0
        let previews = self.previews

        func step(to k: Int, motion m: [CGPoint]?) async -> TrackingEngine.Result? {
            guard let prevPts = frames[prev].points, let keyPts = frames[key].points else { return nil }
            let (pu, ku, nu, ks) = (frames[prev].url, frames[key].url, frames[k].url, keyScales)
            // Decode the next photos on the other cores meanwhile (a RAW takes about 2 s).
            for u in (k + 1..<min(k + 4, frames.count)).map({ frames[$0].url }) where previews.cached(u) == nil {
                Task.detached(priority: .utility) { _ = previews.image(for: u) }
            }
            return await Task.detached(priority: .userInitiated) {
                engine.track(prev: pu, prevPoints: prevPts, motion: m, key: ku, keyPoints: keyPts, keyScales: ks, next: nu)
            }.value
        }

        func accept(_ r: TrackingEngine.Result, at k: Int, steps: Int) {
            let before = frames[prev].points ?? r.points
            frames[k].points = r.points
            frames[k].score = r.score
            frames[k].status = r.score < 0.75 ? .doubtful : .tracked
            motion = zip(r.points, before).map { CGPoint(x: ($0.x - $1.x) / CGFloat(steps), y: ($0.y - $1.y) / CGFloat(steps)) }
            keyScales = r.scales
            prev = k
        }

        /// Places the photos between `prev` and `b` using the photo before and the photo after: first on the line
        /// between their anchors, then looked for around that estimate. A photo where the anchor is seen clearly
        /// takes its real place; one where it stays hidden keeps the estimate, marked to check.
        func fillBetween(upTo b: Int, with pts: [CGPoint]) async -> Bool {
            guard let a = frames[prev].points, a.count == pts.count, b - prev > 1 else { return true }
            for idx in (prev + 1)..<b {
                let t = CGFloat(idx - prev) / CGFloat(b - prev)
                let guess = zip(a, pts).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
                let r = await step(to: idx, motion: zip(guess, a).map { CGPoint(x: $0.x - $1.x, y: $0.y - $1.y) })
                guard run == trackRun, !Task.isCancelled else { return false }
                let near = r.map { zip($0.points, guess).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.04 } } ?? false
                if let r, r.score >= 0.75, near {
                    frames[idx].points = r.points
                    frames[idx].score = r.score
                    frames[idx].status = .tracked
                } else {
                    frames[idx].points = guess
                    frames[idx].status = .estimated
                    frames[idx].score = nil
                    estimated += 1
                }
            }
            return true
        }

        var k = start + 1
        while k < frames.count {
            if frames[k].status == .manual, let pts = frames[k].points, let pp = frames[prev].points {
                // A photo placed by hand is the truth: continue from it.
                motion = zip(pts, pp).map { CGPoint(x: $0.x - $1.x, y: $0.y - $1.y) }
                key = k; prev = k
                keyScales = nil
                k += 1
                continue
            }
            let result = await step(to: k, motion: motion)
            guard run == trackRun, !Task.isCancelled else { return }
            guard let result else { notice = "Impossible de lire \(frames[k].url.lastPathComponent)."; lost = k; break }
            if result.score >= 0.5 {
                accept(result, at: k, steps: 1)
                trackingProgress = Double(k - start) / total
                current = k
                k += 1
                continue
            }

            // Lost or unclear here (someone passing in front, two look-alike places): look for the anchor on the
            // next photos, then estimate this one between the photo before and the photo after.
            var bridged = false
            for j in 1...3 where k + j < frames.count {
                let far = k + j
                if frames[far].status == .manual, let pts = frames[far].points {
                    guard await fillBetween(upTo: far, with: pts) else { return }
                    k = far
                    bridged = true
                    break
                }
                let scaled = motion.map { $0.map { CGPoint(x: $0.x * CGFloat(j + 1), y: $0.y * CGFloat(j + 1)) } }
                let r = await step(to: far, motion: scaled)
                guard run == trackRun, !Task.isCancelled else { return }
                if let r, r.score >= 0.75 {
                    guard await fillBetween(upTo: far, with: r.points) else { return }
                    accept(r, at: far, steps: j + 1)
                    trackingProgress = Double(far - start) / total
                    current = far
                    k = far + 1
                    bridged = true
                    break
                }
            }
            if !bridged {
                frames[k].points = result.points
                frames[k].score = result.score
                frames[k].status = .doubtful
                lost = k
                break
            }
        }
        guard run == trackRun else { return }
        isTracking = false
        trackingProgress = nil
        trackTask = nil
        invalidatePlayback()
        if let lost {
            current = lost
            if notice == nil {
                notice = "Repère introuvable sur la photo \(lost + 1) ni sur les 3 suivantes. Replace-le à la main (zoome avec le pincement ou ⌘+), puis relance le suivi depuis cette photo."
            }
        } else {
            let doubtful = doubtfulCount
            var text = doubtful == 0 ? "Suivi terminé, tout semble bon. Vérifie en vue Aligné." : "Suivi terminé. \(doubtful) photo(s) en rouge à vérifier."
            if estimated > 0 { text += " \(estimated) photo(s) masquée(s) ou incertaine(s) estimée(s) entre leurs voisines." }
            notice = text
        }
        refreshAligned()
    }

    // MARK: - Match cut

    /// Size of the element as photographed (frame space): square root of the frame's area.
    func elementSize(_ k: Int) -> Double? {
        guard frames.indices.contains(k), let q = frames[k].points, q.count == 4 else { return nil }
        let a = 0.5 * abs((0..<4).reduce(0.0) { $0 + Double(q[$1].x * q[($1 + 1) % 4].y - q[($1 + 1) % 4].x * q[$1].y) })
        return a > 0 ? sqrt(a) : nil
    }

    /// Zoom progressif: the element goes smoothly from its size on the first photo to its size on the last one
    /// (same growth from each photo to the next), instead of keeping the size of the reference.
    func progressiveScale(_ k: Int) -> Double? {
        let placed = frames.indices.filter { elementSize($0) != nil }
        guard let first = placed.first, let last = placed.last, last > first,
              let s0 = elementSize(first), let s1 = elementSize(last), let sr = elementSize(refIndex) else { return nil }
        let t = min(max(Double(k - first) / Double(last - first), 0), 1)
        return exp(log(s0) + (log(s1) - log(s0)) * t) / sr
    }

    /// Puts the photos in order of the element's size as photographed (smallest first, or largest first). Photos
    /// where the element is not placed go to the end. ⌘Z gives the previous order back.
    func sortBySize(ascending: Bool) {
        guard frames.count > 1, !isTracking else { return }
        // Not measured everywhere yet: find the element on every photo first, then sort.
        if frames.contains(where: { $0.points == nil }), plan != nil {
            pendingSort = ascending
            findMatches()
            return
        }
        let sized = frames.indices.compactMap { k in elementSize(k).map { (k, $0) } }
        guard sized.count > 1 else {
            notice = "Encadre d'abord l'élément sur une photo : l'app le cherche sur les autres et mesure sa taille."
            return
        }
        registerUndo()
        let refID = frames[refIndex].id, currentID = currentFrame?.id
        let ordered = sized.sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }.map { frames[$0.0] }
        let rest = frames.indices.filter { elementSize($0) == nil }.map { frames[$0] }
        frames = ordered + rest
        refIndex = frames.firstIndex { $0.id == refID } ?? 0
        if let id = currentID, let i = frames.firstIndex(where: { $0.id == id }) { current = i }
        loadThumbnails()
        invalidatePlayback()
        refreshAligned()
        notice = ascending ? "Photos rangées du plus petit au plus gros élément. ⌘Z pour revenir à l'ordre d'avant."
            : "Photos rangées du plus gros au plus petit élément. ⌘Z pour revenir à l'ordre d'avant."
    }

    /// Moves the current photo in the series by hand (`to`: new index). When the size cannot tell which photo comes
    /// first, the order is the user's: the automatic sorting is switched off so that it never undoes it.
    func movePhoto(to target: Int) {
        guard isMatchCut, frames.indices.contains(current), !isTracking else { return }  // a hyperlapse keeps its order
        let to = min(max(target, 0), frames.count - 1)
        guard to != current else { return }
        registerUndo()
        let refID = frames[refIndex].id
        let f = frames.remove(at: current)
        frames.insert(f, at: to)
        refIndex = frames.firstIndex { $0.id == refID } ?? 0
        current = to
        loadThumbnails()
        invalidatePlayback()
        refreshAligned()
        if settings.autoSort {
            restoring = true
            settings.autoSort = false
            restoring = false
            notice = "Photo déplacée en position \(to + 1). Rangement automatique coupé pour garder ton ordre (⌘Z pour revenir)."
        }
    }

    /// Match cut: the frame found on this photo is right as it is. It becomes placed by hand (orange), so the search
    /// leaves it alone and it no longer counts as to check.
    func validateCurrent() {
        guard isMatchCut, frames.indices.contains(current), frames[current].points != nil, frames[current].status != .manual else { return }
        registerUndo()
        frames[current].status = .manual
        invalidatePlayback()
        let left = frames.filter { $0.status == .doubtful || $0.status == .estimated }.count
        notice = left == 0 ? "Photo validée. Plus aucune photo à vérifier." : "Photo validée. Encore \(left) à vérifier (⌘D pour la suivante)."
    }

    /// Order asked for while the element was still being looked for.
    private var pendingSort: Bool?

    /// Finds the element framed on the reference in every other photo (except those framed by hand): over the whole
    /// photo, at every size and tilt, then fitted to the pixel by its four corners.
    func findMatches() {
        guard trackTask == nil else { return }
        guard frames.indices.contains(refIndex), let refQuad = frames[refIndex].points, refQuad.count == 4 else {
            notice = "Encadre d'abord l'élément sur la photo de référence (n° \(refIndex + 1)) : glisse en diagonale autour du logo."
            return
        }
        guard frames.count > 1 else { return }
        registerUndo()
        trackRun += 1
        let run = trackRun
        isTracking = true
        trackTask = Task { [weak self] in await self?.runMatches(refQuad: refQuad, run: run) }
    }

    private func runMatches(refQuad: [CGPoint], run: Int) async {
        trackingProgress = 0
        notice = nil
        let engine = MatchCutEngine(previews: previews)
        let refURL = frames[refIndex].url
        guard let ref = await Task.detached(priority: .userInitiated, operation: { engine.reference(url: refURL, quad: refQuad) }).value else {
            isTracking = false; trackingProgress = nil; trackTask = nil
            notice = "Le cadre de la référence est trop petit ou la photo est illisible."
            return
        }
        guard run == trackRun else { return }
        var hints: [[CGPoint]] = [refQuad]
        let todo = frames.indices.filter { $0 != refIndex && frames[$0].status != .manual }
        var missed: [Int] = []
        for (n, k) in todo.enumerated() {
            let url = frames[k].url, h = Array(hints.suffix(3))
            let previews = self.previews
            for u in todo.dropFirst(n + 1).prefix(2).map({ frames[$0].url }) where previews.cached(u) == nil {
                Task.detached(priority: .utility) { _ = previews.image(for: u) }
            }
            // Corrected by hand meanwhile: the hand wins, the search leaves it alone.
            if frames[k].status == .manual { trackingProgress = Double(n + 1) / Double(todo.count); continue }
            let found = await Task.detached(priority: .userInitiated) { engine.find(ref, url: url, hints: h) }.value
            guard run == trackRun, !Task.isCancelled else { return }
            if frames[k].status == .manual { trackingProgress = Double(n + 1) / Double(todo.count); continue }
            if let f = found, f.score >= 0.4 {
                frames[k].anchor = Anchor(points: f.quad, status: f.score >= 0.7 ? .tracked : .doubtful, score: f.score)
                if f.score >= 0.6 { hints.append(f.quad) }
            } else {
                frames[k].anchor = Anchor()
                missed.append(k)
            }
            trackingProgress = Double(n + 1) / Double(todo.count)
        }
        isTracking = false
        trackingProgress = nil
        trackTask = nil
        invalidatePlayback()
        let doubtful = frames.filter { $0.status == .doubtful }.count
        // The sizes are known now: smallest to largest (or as asked), the order of a natural zoom.
        var sorted = ""
        if let asc = pendingSort ?? (settings.autoSort ? true : nil), frames.indices.filter({ elementSize($0) != nil }).count > 1 {
            let missedIDs = missed.map { frames[$0].id }
            sortBySize(ascending: asc)
            missed = missedIDs.compactMap { id in frames.firstIndex { $0.id == id } }
            sorted = asc ? " Photos rangées du plus petit au plus gros." : " Photos rangées du plus gros au plus petit."
        }
        pendingSort = nil
        if let first = missed.first {
            current = first
            notice = "Élément introuvable sur \(missed.count) photo(s), dont celle-ci. Trace un cadre grossier autour : il s'ajuste tout seul sur l'élément." + sorted
        } else if doubtful > 0 {
            notice = "Élément placé sur toutes les photos. \(doubtful) en rouge à vérifier en vue Aligné (⌘D)." + sorted
        } else {
            notice = "Élément placé au même endroit sur toutes les photos." + sorted + " Vérifie en vue Aligné, puis exporte."
        }
        refreshAligned()
    }

    /// A frame drawn roughly by hand around the element is fitted onto it, corners included.
    private func fitDrawnFrame(at k: Int, drawn: [CGPoint]) {
        guard frames.indices.contains(refIndex), let refQuad = frames[refIndex].points, refQuad.count == 4 else { return }
        let engine = MatchCutEngine(previews: previews)
        let refURL = frames[refIndex].url, url = frames[k].url
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> MatchCutEngine.Found? in
                guard let ref = engine.reference(url: refURL, quad: refQuad) else { return nil }
                return engine.find(ref, url: url, near: drawn)
            }.value
            guard let self, self.frames.indices.contains(k), self.frames[k].points == drawn else { return }
            guard let found, found.score >= 0.4 else {
                self.notice = "Cadre gardé tel que tracé : l'élément n'y ressemble pas assez à celui de la référence."
                return
            }
            self.frames[k].points = found.quad
            self.frames[k].score = found.score
            self.notice = String(format: "Cadre ajusté sur l'élément (ressemblance %.0f %%). ⌘Z pour revenir avant le tracé.", found.score * 100)
            self.invalidatePlayback()
            self.refreshAligned()
        }
    }

    // MARK: - Tracking the lines

    /// Follows the lines of this photo (horizontal, vertical or both) on the next photos. A line placed by hand
    /// further on is a keyframe: the tracking starts again from it.
    func trackGuides() {
        guard trackTask == nil, let frame = currentFrame else { return }
        let kinds = GuideKind.allCases.filter { frame.guide($0)?.points?.count == 2 }
        guard !kinds.isEmpty else {
            notice = "Trace d'abord une ligne horizontale ou verticale sur cette photo (Orientation, dans le panneau de droite)."
            return
        }
        guard current + 1 < frames.count else { notice = "C'est la dernière photo."; return }
        registerUndo()
        for g in kinds where frame.guide(g)?.status != .manual {
            var a = frame.guide(g)!; a.status = .manual; a.score = nil
            frames[current].setGuide(g, a)
        }
        let start = current
        trackRun += 1
        let run = trackRun
        isTracking = true
        trackTask = Task { [weak self] in await self?.runGuideTracking(from: start, kinds: kinds, run: run) }
    }

    private func runGuideTracking(from start: Int, kinds: [GuideKind], run: Int) async {
        trackingProgress = 0
        notice = nil
        let engine = TrackingEngine(previews: previews)
        let previews = self.previews
        let n = frames.count
        let steps = Double((n - 1 - start) * kinds.count)
        var done = 0.0
        var lostAt: [GuideKind: Int] = [:]
        let jumpLimit = 4 * Double.pi / 180
        let axis = settings.symmetryAxis

        for g in kinds {
            var key = start, prev = start
            var keyScales: [Double]?
            var polarity: Float?    // contrast of the edge on the keyframe
            var misses: [Int] = []  // photos where the line was not seen, placed once it is found again

            /// Puts the line on the photos missed between `prev` and `b`: its angle goes from one to the other,
            /// and it follows the point of each photo.
            func fillMisses(upTo b: Int?) {
                guard let a = frames[prev].guide(g)?.points else { return }
                let bp = b.flatMap { frames[$0].guide(g)?.points }
                for m in misses {
                    var pts = a
                    if let bp, let b {
                        let t = CGFloat(m - prev) / CGFloat(b - prev)
                        pts = zip(a, bp).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
                        // Same angle as the interpolation, laid where the point of this photo says.
                        if let pa = frames[prev].points?.first, let pb = frames[b].points?.first, let pm = frames[m].points?.first {
                            let ref = CGPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t)
                            pts = pts.map { CGPoint(x: $0.x + pm.x - ref.x, y: $0.y + pm.y - ref.y) }
                        }
                    } else if let pa = frames[prev].points?.first, let pm = frames[m].points?.first {
                        pts = a.map { CGPoint(x: $0.x + pm.x - pa.x, y: $0.y + pm.y - pa.y) }
                    }
                    frames[m].setGuide(g, Anchor(points: pts, status: .estimated, score: nil))
                }
                misses = []
            }

            var k = start + 1
            while k < n {
                defer { k += 1; done += 1; trackingProgress = done / steps }
                if let a = frames[k].guide(g), a.status == .manual, a.points?.count == 2 {
                    // A keyframe is the truth: continue from it.
                    fillMisses(upTo: k)
                    key = k; prev = k; keyScales = nil; polarity = nil
                    continue
                }
                guard let prevPts = frames[prev].guide(g)?.points, let keyPts = frames[key].guide(g)?.points else { break }
                if polarity == nil {
                    let ku = frames[key].url
                    polarity = await Task.detached(priority: .userInitiated) { engine.edgePolarity(ku, keyPts) }.value
                }
                // In a hyperlapse the line stays where it was around the point: the previous line, moved like the point.
                var predicted = prevPts
                if let a = frames[prev].points?.first, let b = frames[k].points?.first {
                    predicted = prevPts.map { CGPoint(x: $0.x + b.x - a.x, y: $0.y + b.y - a.y) }
                }
                let (pu, ku, nu, ks, pol) = (frames[prev].url, frames[key].url, frames[k].url, keyScales, polarity ?? 0)
                let motion = zip(predicted, prevPts).map { CGPoint(x: $0.x - $1.x, y: $0.y - $1.y) }
                for u in (k + 1..<min(k + 4, n)).map({ frames[$0].url }) where previews.cached(u) == nil {
                    Task.detached(priority: .utility) { _ = previews.image(for: u) }
                }
                let found = await Task.detached(priority: .userInitiated) { () -> (TrackingEngine.EdgeFit?, [Double]?) in
                    // The straight edge itself, looked for around the prediction: endpoints sliding along it do not
                    // matter, a parallel edge of the other contrast or a turn of more than 6 degrees is refused.
                    let first = engine.findEdge(nu, predicted: predicted, polarity: pol, maxTurn: 6 * .pi / 180)
                    if let first, first.support >= 0.55 { return (first, nil) }
                    // Not clear there: let the photo tracking say where the line went, then look for the edge again.
                    guard let r = engine.track(prev: pu, prevPoints: prevPts, motion: motion, key: ku, keyPoints: keyPts,
                                               keyScales: ks, next: nu), r.score >= 0.5 else { return (first, nil) }
                    let mid = centroid(r.points), pm = centroid(prevPts)
                    let moved = prevPts.map { CGPoint(x: $0.x + mid.x - pm.x, y: $0.y + mid.y - pm.y) }
                    let second = engine.findEdge(nu, predicted: moved, polarity: pol, maxTurn: 6 * .pi / 180)
                    if let second, second.support > first?.support ?? 0 { return (second, r.scales) }
                    if first == nil, second == nil {
                        // No straight edge under the line (it joins two details): the photo tracking alone decides.
                        return (TrackingEngine.EdgeFit(points: r.points, support: r.score >= 0.75 ? 0.6 : 0.4), r.scales)
                    }
                    return (first, nil)
                }.value
                guard run == trackRun, !Task.isCancelled else { return }
                current = k
                guard let fit = found.0, fit.support >= 0.3 else {
                    misses.append(k)
                    if misses.count >= 6 { lostAt[g] = misses[0]; break }
                    continue
                }
                fillMisses(upTo: nil)
                let jump = fit.support < 0.5
                    && abs(g.correction(fit.points[0], fit.points[1], axis: axis) - g.correction(prevPts[0], prevPts[1], axis: axis)) > jumpLimit
                frames[k].setGuide(g, Anchor(points: fit.points, status: fit.support < 0.5 || jump ? .doubtful : .tracked,
                                             score: fit.support))
                prev = k
                if let sc = found.1 { keyScales = sc }
            }
            if lostAt[g] == nil { fillMisses(upTo: nil) } else { misses = [] }
        }
        guard run == trackRun else { return }
        let flagged = flagRotationSpikes(from: start, kinds: kinds)
        isTracking = false
        trackingProgress = nil
        trackTask = nil
        invalidatePlayback()
        if let (g, k) = lostAt.min(by: { $0.value < $1.value }) {
            current = k
            notice = "Ligne \(g.label.lowercased()) perdue à partir de la photo \(k + 1). Retrace-la sur cette photo (elle devient une image clé), puis relance le suivi de l'orientation."
        } else {
            let doubtful = frames.indices.filter { k in kinds.contains { frames[k].guide($0)?.status == .doubtful || frames[k].guide($0)?.status == .estimated } }.count
            notice = doubtful == 0
                ? "Orientation suivie, tout semble droit. Vérifie en vue Aligné."
                : "Orientation suivie. \(doubtful) photo(s) en rouge à vérifier\(flagged > 0 ? ", dont \(flagged) où la rotation saute" : ""). Retrace la ligne pour en faire une image clé."
        }
        refreshAligned()
    }

    /// A photo whose rotation jumps away from both neighbours while they agree, or whose two lines stop agreeing,
    /// is most likely a slip of the tracking: marked to check.
    private func flagRotationSpikes(from start: Int, kinds: [GuideKind]) -> Int {
        let deg = Double.pi / 180
        var flagged = Set<Int>()
        func corr(_ g: GuideKind, _ k: Int) -> Double? {
            guard frames.indices.contains(k), let a = frames[k].guide(g), a.status != .estimated, let p = a.points else { return nil }
            return g.correction(p[0], p[1], axis: settings.symmetryAxis)
        }
        for g in kinds {
            for k in (start + 1)..<max(start + 1, frames.count - 1)
            where frames[k].guide(g)?.status == .tracked && (frames[k].guide(g)?.score ?? 1) < 0.6 {
                guard let a = corr(g, k - 1), let c = corr(g, k), let b = corr(g, k + 1) else { continue }
                if abs(a - b) < 0.7 * deg, abs(c - a) > 2 * deg, abs(c - b) > 2 * deg, (c - a) * (c - b) > 0 { flagged.insert(k) }
            }
        }
        if kinds.contains(.horizontal), kinds.contains(.vertical) {
            // Both lines turn with the camera by the same amount: their difference stays what it was on the start photo.
            if let h0 = corr(.horizontal, start), let v0 = corr(.vertical, start) {
                for k in (start + 1)..<frames.count {
                    guard let h = corr(.horizontal, k), let v = corr(.vertical, k) else { continue }
                    if abs((h - v) - (h0 - v0)) > 1.5 * deg { flagged.insert(k) }
                }
            }
        }
        for k in flagged {
            for g in kinds {
                guard var a = frames[k].guide(g), a.status == .tracked else { continue }
                a.status = .doubtful
                frames[k].setGuide(g, a)
            }
        }
        return flagged.count
    }

    // MARK: - Aligned preview

    static let previewCanvasLongEdge = 1600.0

    var previewCanvas: CGSize {
        let o = outputSize
        let s = Self.previewCanvasLongEdge / max(o.width, o.height)
        return CGSize(width: (o.width * s).rounded(), height: (o.height * s).rounded())
    }

    func refreshAligned() {
        alignTask?.cancel()
        guard viewMode == .aligned, let plan, let img = preview, frames.indices.contains(current) else {
            aligned = nil; alignedReference = nil
            return
        }
        let canvas = previewCanvas
        let g = plan.refToCanvas(canvas)
        let t = frameToRef(current, plan: plan)
        let refURL = frames[refIndex].url
        let isRef = current == refIndex
        let previews = self.previews
        alignTask = Task { [weak self] in
            let (a, r) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                let a = Renderer.cgImage(Renderer.render(CIImage(cgImage: img), frameToRef: t, refToCanvas: g, canvas: canvas))
                var r: CGImage?
                if !isRef, let refImg = previews.image(for: refURL) {
                    r = Renderer.cgImage(Renderer.render(CIImage(cgImage: refImg), frameToRef: .identity, refToCanvas: g, canvas: canvas))
                }
                return (a, r)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.aligned = a
            self.alignedReference = r
        }
    }

    /// Smallest zoom for which every aligned photo covers the whole canvas (no black edges).
    func autoZoom() {
        guard var plan else { notice = "Place d'abord le repère sur la photo de référence."; return }
        let canvas = outputSize
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: canvas.width, y: 0),
                       CGPoint(x: canvas.width, y: canvas.height), CGPoint(x: 0, y: canvas.height)]
        let transforms = frames.indices.map { (frameToRef($0, plan: plan), frames[$0].aspect) }
        func covers(_ zoom: Double) -> Bool {
            plan.settings.zoom = zoom
            let g = plan.refToCanvas(canvas)
            for (t, aspect) in transforms {
                guard let inv = (g * t).inverse else { return false }
                for c in corners {
                    let p = inv.apply(c)
                    if p.x < -1e-6 || p.y < -1e-6 || Double(p.x) > aspect + 1e-6 || p.y > 1 + 1e-6 { return false }
                }
            }
            return true
        }
        guard covers(4) else {
            notice = "Impossible d'éviter les bords noirs : les photos bougent trop. Vérifie les repères en orange."
            return
        }
        var lo = 1.0, hi = 4.0
        if covers(lo) { settings.zoom = 1; return }
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if covers(mid) { hi = mid } else { lo = mid }
        }
        settings.zoom = (hi * 1000).rounded(.up) / 1000
        notice = String(format: "Zoom réglé à %.0f %% pour masquer les bords noirs.", settings.zoom * 100)
    }

    // MARK: - Playback (aligned, low resolution)

    private var playbackSignature: String {
        let pts = frames.map { $0.points.map { $0.map { "\($0.x),\($0.y)" }.joined(separator: ";") } ?? "-" }
        return "\(refIndex)|\(settings.kind)|\(settings.level)|\(settings.correctScale)|\(settings.perspective)|"
            + "\(settings.centerAnchor)|\(settings.zoom)|\(settings.output)|\(settings.sizeMode)|" + pts.joined(separator: "|")
            + "|" + rotations.map { String($0) }.joined(separator: ",")
    }

    private func invalidatePlayback() {
        playbackFrames = []
        playbackKey = nil
    }

    func togglePlayback() {
        if playing || playbackProgress != nil { stopPlayback(); return }
        guard let plan else { notice = "Place d'abord le repère sur la photo de référence."; return }
        let key = playbackSignature
        if playbackKey == key, !playbackFrames.isEmpty {
            startLoop()
            return
        }
        let canvas: CGSize = {
            let o = outputSize, s = 960 / max(o.width, o.height)
            return CGSize(width: (o.width * s).rounded(), height: (o.height * s).rounded())
        }()
        let g = plan.refToCanvas(canvas)
        let jobs = frames.indices.map { (frames[$0].url, frameToRef($0, plan: plan)) }
        let previews = self.previews
        playTask = Task { [weak self] in
            var out: [CGImage] = []
            for (i, job) in jobs.enumerated() {
                if Task.isCancelled { return }
                let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let src = previews.cached(job.0) ?? ImageLoader.playback(job.0, maxPixel: 1280) else { return nil }
                    return Renderer.cgImage(Renderer.render(CIImage(cgImage: src), frameToRef: job.1, refToCanvas: g, canvas: canvas))
                }.value
                if let img { out.append(img) }
                self?.playbackProgress = Double(i + 1) / Double(jobs.count)
            }
            guard let self, !Task.isCancelled else { return }
            self.playbackFrames = out
            self.playbackKey = key
            self.playbackProgress = nil
            self.startLoop()
        }
    }

    private func startLoop() {
        playing = true
        let frames = playbackFrames
        let hold = isMatchCut ? Double(settings.holdFrames) : 1  // match cut: each photo lasts 1, 2 or 3 frames
        let delay = UInt64(1_000_000_000 * hold / settings.fps.value)
        playTask = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                self?.playbackFrame = frames[i % frames.count]
                i += 1
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func stopPlayback() {
        playTask?.cancel(); playTask = nil
        playing = false
        playbackProgress = nil
        playbackFrame = nil
    }

    // MARK: - Export

    func exportItems() -> [ExportItem]? {
        guard let plan else { return nil }
        return frames.indices.map { ExportItem(url: frames[$0].url, frameToRef: frameToRef($0, plan: plan)) }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.write(to: self.sessionFile)
        }
    }

    /// Writes the session at once (before quitting or restarting for an update).
    func saveNow() {
        saveTask?.cancel()
        write(to: sessionFile)
    }

    private func write(to url: URL) {
        let saved = Dictionary(uniqueKeysWithValues: stash.map { kind, anchors in
            (kind.rawValue, Dictionary(uniqueKeysWithValues: anchors.map { ($0.key.uuidString, $0.value) }))
        })
        let file = ProjectFile(frames: frames, refIndex: refIndex, settings: settings, stash: saved)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(file).write(to: url, options: .atomic)
    }

    private func read(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(ProjectFile.self, from: data)
        else { return false }
        let present = file.frames.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !present.isEmpty else { return false }
        restoring = true  // a loaded kind brings its own anchors, nothing to put aside
        settings = file.settings
        restoring = false
        if isMatchCut, settings.kind != .frame { useFrameAnchor() }
        let refID = file.frames.indices.contains(file.refIndex) ? file.frames[file.refIndex].id : nil
        var restored: [AnchorKind: [UUID: Anchor]] = [:]
        for (kind, anchors) in file.stash ?? [:] {
            guard let k = AnchorKind(rawValue: kind) else { continue }
            restored[k] = Dictionary(uniqueKeysWithValues: anchors.compactMap { id, a in UUID(uuidString: id).map { ($0, a) } })
        }
        load(frames: present, refIndex: present.firstIndex { $0.id == refID } ?? 0, stash: restored)
        if present.count < file.frames.count {
            notice = "\(file.frames.count - present.count) photo(s) introuvable(s), retirée(s) du projet."
        }
        return true
    }

    private func restoreSession() {
        _ = read(sessionFile)
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Serie.hyperlapse.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stopEverything()
        previews.removeAll()
        if !read(url) { notice = "Projet illisible ou photos introuvables." }
    }
}

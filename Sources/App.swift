import AppKit
import Combine
import SwiftUI

/// The two tools of the app. Each has its own photos, anchors, undo and session file.
@MainActor
final class AppState: ObservableObject {
    @Published var mode: WorkMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if mode != oldValue { (oldValue == .hyperlapse ? hyperlapse : matchCut).stopPlayback() }
        }
    }
    let hyperlapse = Project(mode: .hyperlapse)
    let matchCut = Project(mode: .matchCut)
    private var links: [AnyCancellable] = []

    var active: Project { mode == .hyperlapse ? hyperlapse : matchCut }

    init() {
        mode = WorkMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .hyperlapse
        // The menus follow the tool in use.
        links = [hyperlapse, matchCut].map { p in p.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
}

@main
struct HyperlapseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    private var project: Project { state.active }

    var body: some Scene {
        Window("Hyperlapse/Match cut", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(.dark)
                .tint(Theme.control)
                .font(Theme.body)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Annuler") { project.undo() }.keyboardShortcut("z").disabled(!project.canUndo && !project.isTracking)
                Button("Rétablir") { project.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!project.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Importer des photos…") { project.openPanel() }.keyboardShortcut("o")
                Button("Nouveau projet") { project.newProject() }.keyboardShortcut("n")
                Divider()
                Button("Ouvrir un projet…") { project.openProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Enregistrer le projet sous…") { project.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Exporter…") { project.showExport = true }.keyboardShortcut("e")
                    .disabled(project.plan == nil)
            }
            CommandMenu("Outil") {
                Button("Hyperlapse") { state.mode = .hyperlapse }.keyboardShortcut("1", modifiers: [.command, .control])
                Button("Match cut") { state.mode = .matchCut }.keyboardShortcut("2", modifiers: [.command, .control])
            }
            CommandMenu("Photo") {
                Button("Photo précédente") { project.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Photo suivante") { project.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Première photo") { project.current = 0 }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Dernière photo") { project.current = max(project.frames.count - 1, 0) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Prochaine photo à vérifier") { project.goToNextDoubtful() }.keyboardShortcut("d")
                Button("Valider le cadre de cette photo") { project.validateCurrent() }.keyboardShortcut(.return, modifiers: [])
                    .disabled(!project.isMatchCut)
                Button("Avancer la photo dans la vidéo") { project.movePhoto(to: project.current - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(!project.isMatchCut)
                Button("Reculer la photo dans la vidéo") { project.movePhoto(to: project.current + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(!project.isMatchCut)
                Divider()
                Button(project.isTracking ? "Arrêter" : project.isMatchCut ? "Trouver l'élément dans toutes les photos" : "Suivre à partir de cette photo") {
                    project.isTracking ? project.stopTracking() : project.trackForward()
                }
                .keyboardShortcut("t")
                Button("Suivre l'orientation à partir de cette photo") { project.trackGuides() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(project.isTracking || !project.guidesAvailable)
                Button("Définir comme référence") { project.makeReference() }.keyboardShortcut("r")
                Button("Effacer le repère de cette photo") { project.clearPoints(at: project.current) }
                    .keyboardShortcut(.delete, modifiers: [])
                Divider()
                Button("Zoom avant") { project.zoomCanvas(1.5) }.keyboardShortcut("+")
                Button("Zoom arrière") { project.zoomCanvas(1 / 1.5) }.keyboardShortcut("-")
                Button("Photo entière") { project.fitCanvas() }.keyboardShortcut("0")
                Button("Repère d'un pixel à gauche") { project.nudge(-1, 0) }.keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Repère d'un pixel à droite") { project.nudge(1, 0) }.keyboardShortcut(.rightArrow, modifiers: [.option])
                Button("Repère d'un pixel en haut") { project.nudge(0, -1) }.keyboardShortcut(.upArrow, modifiers: [.option])
                Button("Repère d'un pixel en bas") { project.nudge(0, 1) }.keyboardShortcut(.downArrow, modifiers: [.option])
                Button("Repère de 10 pixels à gauche") { project.nudge(-10, 0) }.keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
                Button("Repère de 10 pixels à droite") { project.nudge(10, 0) }.keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
                Button("Repère de 10 pixels en haut") { project.nudge(0, -10) }.keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                Button("Repère de 10 pixels en bas") { project.nudge(0, 10) }.keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                Divider()
                Button("Repère : point") { project.settings.kind = .point }.keyboardShortcut("1", modifiers: [.command, .option])
                    .disabled(project.isMatchCut)
                Button("Repère : règle") { project.settings.kind = .line }.keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(project.isMatchCut)
                Button("Repère : cadre") { project.settings.kind = .frame }.keyboardShortcut("3", modifiers: [.command, .option])
                    .disabled(project.isMatchCut)
                Divider()
                Button("Modifier le point") { project.editTarget = .anchor }.keyboardShortcut("p", modifiers: [.option])
                Button("Modifier la ligne horizontale") { project.editTarget = .horizontal }.keyboardShortcut("h", modifiers: [.option])
                    .disabled(!project.guidesAvailable)
                Button("Modifier la ligne verticale") { project.editTarget = .vertical }.keyboardShortcut("v", modifiers: [.option])
                    .disabled(!project.guidesAvailable)
                Button("Modifier les lignes symétriques") { project.editTarget = .mirrorA }.keyboardShortcut("s", modifiers: [.option])
                    .disabled(!project.guidesAvailable)
                Button("Tourner de 0,1° à gauche (ligne, ou photo avec le point)") { project.rotateGuide(by: -0.1) }
                    .keyboardShortcut("[", modifiers: [.option])
                Button("Tourner de 0,1° à droite (ligne, ou photo avec le point)") { project.rotateGuide(by: 0.1) }
                    .keyboardShortcut("]", modifiers: [.option])
                Divider()
                Button("Vue Placer") { project.viewMode = .original }.keyboardShortcut("1")
                Button("Vue Aligné") { project.viewMode = .aligned }.keyboardShortcut("2")
                Button("Lecture / Pause") {
                    project.viewMode = .aligned
                    project.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var dropTargeted = false
    private var project: Project { state.active }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(project: project, mode: $state.mode)
            if project.frames.isEmpty {
                EmptyStateView(project: project, targeted: dropTargeted)
                    .padding([.horizontal, .bottom], Theme.gap)
            } else {
                HStack(spacing: Theme.gap) {
                    VStack(spacing: Theme.gap) {
                        Panel(fill: Theme.well) {
                            ZStack(alignment: .bottom) {
                                if project.viewMode == .original { PlaceView(project: project) } else { AlignedView(project: project) }
                                if let notice = project.notice { NoticeBanner(text: notice) { project.notice = nil } }
                            }
                        }
                        Panel { FilmstripView(project: project) }
                    }
                    Panel { InspectorView(project: project) }.frame(width: 300)
                }
                .padding([.horizontal, .bottom], Theme.gap)
            }
        }
        .background(Theme.ground)
        .background(WindowChrome())
        .ignoresSafeArea()
        .dropDestination(for: URL.self) { urls, _ in
            project.importURLs(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(isPresented: Binding(get: { project.showExport }, set: { project.showExport = $0 })) { ExportSheet(project: project) }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @ObservedObject var project: Project
    @Binding var mode: WorkMode

    var body: some View {
        ZStack {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Mark(size: 18)
                    Text("HYPERLAPSE/MATCH CUT").font(Theme.font(13, .bold)).kerning(0.6).foregroundStyle(Theme.text)
                        .fixedSize()
                }
                Segmented(options: WorkMode.allCases.map { ($0, $0.label) }, selection: $mode, height: 26)
                    .frame(width: 196)
                    .help("Hyperlapse (⌃⌘1) ou match cut (⌃⌘2) : chaque outil garde ses photos et sa session")
                if !project.frames.isEmpty {
                    Rectangle().fill(Theme.border).frame(width: 1, height: 18)
                    Text(seriesName).font(Theme.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(-1)
                    if project.doubtfulCount > 0 {
                        Button { project.goToNextDoubtful() } label: {
                            Pill(text: "\(project.doubtfulCount) à vérifier", color: Theme.negative)
                        }
                        .buttonStyle(.plain)
                        .help("Aller à la prochaine photo à vérifier (⌘D)")
                    }
                }
                // Only the empty part of the bar moves the window: an AppKit view under the buttons would take
                // their clicks.
                WindowDragArea().frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
                if !project.frames.isEmpty {
                    Segmented(options: ViewMode.allCases.map { ($0, $0.label) }, selection: $project.viewMode)
                        .frame(width: 168)
                        .help("Placer le repère (⌘1) ou voir la série alignée (⌘2)")
                    Rectangle().fill(Theme.border).frame(width: 1, height: 18)
                    HStack(spacing: 2) {
                        iconButton("arrow.uturn.backward", "Annuler (⌘Z)", enabled: project.canUndo) { project.undo() }
                        iconButton("arrow.uturn.forward", "Rétablir (⇧⌘Z)", enabled: project.canRedo) { project.redo() }
                    }
                    Rectangle().fill(Theme.border).frame(width: 1, height: 18)
                    iconButton(project.playing ? "pause.fill" : "play.fill", "Lire l'hyperlapse aligné (espace)",
                               enabled: project.plan != nil) {
                        project.viewMode = .aligned
                        project.togglePlayback()
                    }
                }
                Button("Importer") { project.openPanel() }
                    .buttonStyle(HLButtonStyle(kind: project.frames.isEmpty ? .primary : .secondary))
                    .fixedSize()
                    .help("Importer des photos ou un dossier (⌘O)")
                if !project.frames.isEmpty {
                    Button("Exporter") { project.showExport = true }
                        .buttonStyle(HLButtonStyle(kind: .primary))
                        .fixedSize()
                        .disabled(project.plan == nil)
                        .help("Exporter la vidéo ou la séquence (⌘E)")
                }
            }
            .padding(.leading, 84)  // room for the traffic lights
            .padding(.trailing, Theme.gap + 4)
        }
        .frame(height: Theme.barHeight)
    }

    private var seriesName: String {
        project.frames.first?.url.deletingLastPathComponent().lastPathComponent ?? ""
    }

    private func iconButton(_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 16)
        }
        .buttonStyle(HLButtonStyle(kind: .ghost))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Theme.font(12, .medium).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Theme.raised))
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @ObservedObject var project: Project
    let targeted: Bool

    var body: some View {
        Panel(fill: Theme.well) {
            VStack(spacing: 0) {
                Mark(size: 44).padding(.bottom, 28)
                Text(project.isMatchCut ? "Glisse tes photos de match cut" : "Glisse une série de photos")
                    .font(Theme.font(26, .semibold)).foregroundStyle(Theme.text)
                Text(project.isMatchCut
                     ? "Encadre le logo, la forme ou le texte sur une photo : l'app le retrouve sur les autres\net le place exactement au même endroit, à la même taille. Une photo devient une image de la vidéo."
                     : "Place un repère sur la première, le suivi le retrouve sur toute la série,\npuis exporte la vidéo alignée. Une photo devient une image de la vidéo.")
                    .font(Theme.font(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .lineSpacing(3).padding(.top, 12)
                Button("Importer des photos…") { project.openPanel() }
                    .buttonStyle(HLButtonStyle(kind: .primary, height: 36))
                    .padding(.top, 28)
                Text("RAW (ARW, CR3, NEF, DNG…), JPG, HEIC, TIFF, PNG, ou un dossier entier")
                    .font(Theme.small).foregroundStyle(Theme.faint).padding(.top, 14)
                if let notice = project.notice {
                    Text(notice).font(Theme.small).foregroundStyle(Theme.negative).padding(.top, 10)
                }
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusPanel)
                    .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 0))
                    .foregroundStyle(Theme.anchor)
            )
        }
    }
}

struct NoticeBanner: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(text).font(Theme.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .accessibilityLabel("Fermer")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusPanel).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)  // it floats over the photo
        .padding(16)
        .frame(maxWidth: 640)
    }
}

// MARK: - Filmstrip with the reliability track

struct FilmstripView: View {
    @ObservedObject var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Photo \(project.current + 1) / \(project.frames.count)")
                    .font(Theme.font(13, .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                Text(project.currentFrame?.url.lastPathComponent ?? "").font(Theme.small).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                HStack(spacing: 12) {
                    legend(Theme.anchor, "À la main")
                    legend(Theme.tracked, "Suivi")
                    legend(Theme.negative, "À vérifier")
                    if project.frames.indices.contains(where: project.isRotationKey) {
                        HStack(spacing: 5) { KeyMark(); Text("Image clé") }
                    }
                    Text(project.editTarget == .anchor ? "Barre = fiabilité du point"
                         : "Barre = fiabilité de la ligne \(project.editTarget.label.lowercased())").foregroundStyle(Theme.faint)
                }
                .font(Theme.small).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Theme.pad)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 3) {
                        ForEach(Array(project.frames.enumerated()), id: \.element.id) { i, frame in
                            ThumbCell(frame: frame, index: i, image: project.thumbnails[frame.id],
                                      selected: i == project.current, reference: i == project.refIndex,
                                      status: project.status(at: i), score: project.anchor(at: i)?.score,
                                      key: project.isRotationKey(i), what: project.editTarget == .anchor ? "point" : "ligne")
                                .id(i)
                                .onTapGesture { project.current = i }
                        }
                    }
                    .padding(.horizontal, Theme.pad)
                }
                .onChange(of: project.current) { _, n in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(n, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 12)
        .frame(height: 132)
    }

    private func legend(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 3, height: 10)
            Text(label)
        }
    }
}

struct ThumbCell: View {
    let frame: Frame
    let index: Int
    let image: CGImage?
    let selected: Bool
    let reference: Bool
    let status: FrameStatus
    let score: Double?
    let key: Bool       // a line was placed by hand here: keyframe of the rotation
    let what: String    // "point" or "ligne", for the help text

    private let thumbHeight: CGFloat = 54
    private let trackHeight: CGFloat = 16

    var body: some View {
        let width = thumbHeight * min(max(frame.aspect, 0.6), 1.8)
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                    else { Theme.raised }
                }
                .frame(width: width, height: thumbHeight)
                .clipped()
                .opacity(selected ? 1 : 0.72)
                if key {
                    KeyMark().padding(4).frame(width: width, alignment: .topTrailing)
                }
                if reference {
                    Text("Réf").font(Theme.font(10, .semibold)).foregroundStyle(Theme.primaryInk)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.primaryFill))
                        .padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Theme.text : .clear, lineWidth: 2))
            // The reliability track: read along the strip, it shows where the tracking held and where it slipped.
            ZStack(alignment: .bottom) {
                Rectangle().fill(Theme.raised)
                Rectangle().fill(Palette.status(status))
                    .frame(height: max(trackHeight * barLevel, status == .none ? 0 : 2))
            }
            .frame(width: width, height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .contentShape(Rectangle())
        .help(statusHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusHelp)
        .accessibilityAddTraits(.isButton)
    }

    private var barLevel: CGFloat {
        switch status {
        case .none: 0
        case .manual: 1
        case .tracked, .doubtful: CGFloat(min(max(score ?? 0, 0), 1))
        case .estimated: 0.5
        }
    }

    private var statusHelp: String {
        let k = key ? " · image clé de la rotation" : ""
        switch status {
        case .none: return "Photo \(index + 1) · sans \(what)" + k
        case .manual: return "Photo \(index + 1) · \(what) placé\(what == "ligne" ? "e" : "") à la main" + k
        case .tracked: return String(format: "Photo %d · suivi, fiabilité %.0f %%", index + 1, (score ?? 0) * 100) + k
        case .doubtful: return String(format: "Photo %d · à vérifier, fiabilité %.0f %%", index + 1, (score ?? 0) * 100) + k
        case .estimated: return "Photo \(index + 1) · estimée entre les photos voisines, à vérifier" + k
        }
    }
}

/// Keyframe of the rotation: a small orange diamond, like a keyframe in a timeline.
struct KeyMark: View {
    var body: some View {
        Rectangle().fill(Theme.anchor).frame(width: 6, height: 6).rotationEffect(.degrees(45))
            .overlay(Rectangle().stroke(.black.opacity(0.5), lineWidth: 1).frame(width: 6, height: 6).rotationEffect(.degrees(45)))
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @ObservedObject var project: Project

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section { anchorSection }
                    rule
                    section { trackingSection }
                    if project.guidesAvailable {
                        rule
                        section { orientationSection }
                    }
                    rule
                    section { photoSection }
                    rule
                    section { outputSection }
                }
            }
            rule
            VStack(spacing: 8) {
                Button { project.showExport = true } label: {
                    HStack {
                        Text("Exporter…")
                        Spacer()
                        Text("⌘E").foregroundStyle(Theme.primaryInk.opacity(0.5))
                    }
                }
                .buttonStyle(HLButtonStyle(kind: .primary, fullWidth: true, height: 36))
                .disabled(project.plan == nil)
                if project.plan == nil {
                    Text("Place le repère sur la photo de référence pour exporter.")
                        .font(Theme.small).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.pad)
        }
    }

    private var rule: some View { Rectangle().fill(Theme.rule).frame(height: 1) }

    private func section<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.horizontal, Theme.pad).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Theme.section).foregroundStyle(Theme.text)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(label).font(Theme.body).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 26)
    }

    private var anchorSection: some View {
        Group {
            if project.isMatchCut { matchCutSection } else { hyperlapseAnchorSection }
        }
    }

    private var matchCutSection: some View {
        Group {
            title("Élément")
            Text("Glisse en diagonale autour du logo, de la forme ou du texte, sur la photo où il est le plus net : elle devient la référence. Ajuste les coins si besoin, puis ⌘T.")
                .font(Theme.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            row("Ajuster mes cadres sur l'élément") { toggle($project.settings.snapFrames) }
                .help("Un cadre tracé grossièrement à la main est calé sur l'élément, coins compris.")
            row("Redresser la perspective") { toggle($project.settings.perspective) }
                .help("Les quatre coins tombent exactement sur ceux de la référence. Sans, l'élément garde sa perspective.")
            row("Centrer l'élément") { toggle($project.settings.centerAnchor) }
            row("Taille de l'élément") {
                Picker("Taille de l'élément", selection: $project.settings.sizeMode) {
                    ForEach(SizeMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("Identique : l'élément garde la taille de la référence, le décor zoome autour. Zoom progressif : l'élément grandit (ou rétrécit) régulièrement d'une photo à l'autre, toujours au même endroit.")
            }
            row("Ranger du plus petit au plus gros") { toggle($project.settings.autoSort) }
                .help("Après la recherche (⌘T), l'app mesure l'élément sur chaque photo et les range de la plus petite à la plus grande.")
            HStack(spacing: 6) {
                Button("Petit → gros") { project.sortBySize(ascending: true) }
                    .buttonStyle(HLButtonStyle(kind: .secondary, fullWidth: true))
                Button("Gros → petit") { project.sortBySize(ascending: false) }
                    .buttonStyle(HLButtonStyle(kind: .secondary, fullWidth: true))
            }
            .disabled(project.isTracking || project.plan == nil)
            .help("Change l'ordre des photos dans la vidéo. ⌘Z rend l'ordre d'avant.")
        }
    }

    private var hyperlapseAnchorSection: some View {
        Group {
            title("Repère")
            Segmented(options: AnchorKind.allCases.map { ($0, $0.label) }, selection: $project.settings.kind)
                .help("Chaque type garde ses propres repères (⌥⌘1, ⌥⌘2, ⌥⌘3)")
            Text(kindHelp).font(Theme.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            if project.settings.kind != .point {
                row("Mettre de niveau") {
                    Picker("Mettre de niveau", selection: $project.settings.level) {
                        ForEach(LevelMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if project.settings.kind == .frame {
                row("Corriger la perspective") { toggle($project.settings.perspective) }
            }
            if project.settings.kind == .line || (project.settings.kind == .frame && !project.settings.perspective) {
                row("Corriger le zoom") { toggle($project.settings.correctScale) }
            }
            row("Centrer le repère") { toggle($project.settings.centerAnchor) }
            if project.settings.kind == .point {
                row("Clic = photo suivante") { toggle($project.settings.advanceOnClick) }
                    .help("Pour les match cuts : un clic place le point et passe à la photo suivante.")
            }
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View {
        Toggle("", isOn: b).toggleStyle(.switch).controlSize(.mini).labelsHidden()
    }

    private var kindHelp: String {
        switch project.settings.kind {
        case .point: "Clique sur un détail net (coin de logo, angle). Il reste fixe : corrige la position."
        case .line: "Trace une ligne le long d'un élément droit (horizon, toit, ligne de piste). Corrige position et rotation."
        case .frame: "Encadre un logo ou un panneau, puis ajuste les quatre coins. Corrige position, rotation, taille et perspective."
        }
    }

    private var trackingSection: some View {
        Group {
            title(project.isMatchCut ? "Recherche automatique" : "Suivi automatique")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(project.anchoredCount)").font(Theme.font(28, .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                Text("/ \(project.frames.count) photos alignées").font(Theme.body).foregroundStyle(Theme.muted)
                Spacer()
            }
            if let p = project.trackingProgress {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.raised)
                            Capsule().fill(Theme.text).frame(width: max(4, g.size.width * p))
                        }
                    }
                    .frame(height: 4)
                    Button(project.isMatchCut ? "Arrêter la recherche" : "Arrêter le suivi") { project.stopTracking() }
                        .buttonStyle(HLButtonStyle(kind: .secondary, fullWidth: true))
                }
            } else {
                Button { project.trackForward() } label: {
                    HStack {
                        Text(project.isMatchCut ? "Trouver l'élément partout" : "Suivre à partir de cette photo")
                        Spacer()
                        Text("⌘T").foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(HLButtonStyle(kind: project.isMatchCut ? .primary : .secondary, fullWidth: true, height: 32))
                .disabled(project.isMatchCut ? project.plan == nil : project.currentFrame?.points == nil)
            }
            if project.doubtfulCount > 0, project.editTarget == .anchor {
                Button { project.goToNextDoubtful() } label: {
                    HStack {
                        Text("\(project.doubtfulCount) photo\(project.doubtfulCount > 1 ? "s" : "") à vérifier")
                        Spacer()
                        Text("⌘D").foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(HLButtonStyle(kind: .destructive, fullWidth: true))
            }
        }
    }

    private var orientationSection: some View {
        Group {
            title("Orientation")
            Text("Trace une ligne sur un élément qui doit rester droit (horizon, bord de toit, poteau). Chaque photo tourne autour du point pour la garder droite.")
                .font(Theme.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            Segmented(options: [(EditTarget.anchor, "Point"), (.horizontal, "Horiz."), (.vertical, "Vert."), (.mirrorA, "Symétrie")],
                      selection: Binding(get: { project.editTarget == .mirrorB ? .mirrorA : project.editTarget },
                                         set: { project.editTarget = $0 }))
                .help("Ce que tu places sur la photo : le point (⌥P), une horizontale (⌥H), une verticale (⌥V) ou deux lignes symétriques (⌥S)")
            if project.editTarget.guide?.isMirror == true {
                Segmented(options: [(EditTarget.mirrorA, "Ligne 1"), (.mirrorB, "Ligne 2")], selection: $project.editTarget, height: 24)
                Text("Deux lignes qui penchent autant l'une que l'autre, de chaque côté (bords d'une porte, deux piliers vus d'en bas) : c'est leur axe qui reste droit, la perspective s'annule.")
                    .font(Theme.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                row("Axe") {
                    Picker("Axe", selection: $project.settings.symmetryAxis) {
                        Text("Vertical").tag(GuideKind.vertical)
                        Text("Horizontal").tag(GuideKind.horizontal)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            row("Rotation") {
                Picker("Rotation", selection: $project.settings.rotation) {
                    ForEach(RotationMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("Lignes suivies : chaque photo est redressée. Images clés : la rotation passe en douceur d'une ligne tracée à la main à la suivante.")
            }
            if project.settings.rotation == .follow {
                row("Lissage") {
                    Picker("Lissage", selection: $project.settings.smoothing) {
                        ForEach(Smoothing.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Adoucit les petits tremblements de rotation. Les images clés restent exactes.")
                }
            }
            if let p = project.trackingProgress, project.isTracking, project.editTarget != .anchor {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        Capsule().fill(Theme.text).frame(width: max(4, g.size.width * p))
                    }
                }
                .frame(height: 4)
            }
            Button { project.trackGuides() } label: {
                HStack {
                    Text("Suivre l'orientation")
                    Spacer()
                    Text("⇧⌘T").foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(HLButtonStyle(kind: .secondary, fullWidth: true, height: 32))
            .disabled(project.isTracking || !hasGuideHere)
            .help("Suit les lignes de cette photo sur les suivantes. Une ligne retracée à la main devient une image clé et le suivi repart d'elle.")
            if project.doubtfulCount > 0, project.editTarget != .anchor {
                Button { project.goToNextDoubtful() } label: {
                    HStack {
                        Text("\(project.doubtfulCount) ligne\(project.doubtfulCount > 1 ? "s" : "") à vérifier")
                        Spacer()
                        Text("⌘D").foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(HLButtonStyle(kind: .destructive, fullWidth: true))
            }
            Text(orientationInfo).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            // Rotation keyframes set by hand: the photo turns around the point.
            HStack(spacing: 4) {
                Text("Clé de rotation").font(Theme.body).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                stepButton("−1°", -1); stepButton("−0,1°", -0.1); stepButton("+0,1°", 0.1); stepButton("+1°", 1)
            }
            HStack {
                let key = project.currentFrame?.rotationKey
                Text(key.map { String(format: "Image clé : %+.2f°", $0 * 180 / .pi).replacingOccurrences(of: ".", with: ",") }
                     ?? "Pas de clé sur cette photo")
                    .font(Theme.small.monospacedDigit()).foregroundStyle(key == nil ? Theme.muted : Theme.anchor)
                Spacer()
                if key != nil {
                    Button("Retirer la clé") { project.setRotationKey(nil) }.buttonStyle(HLButtonStyle(kind: .ghost, height: 24))
                }
            }
        }
    }

    /// Turns the current photo around its point and makes it a rotation keyframe.
    private func stepButton(_ label: String, _ degrees: Double) -> some View {
        Button(label) {
            let base = project.currentFrame?.rotationKey ?? project.currentManualRotation
            project.setRotationKey(base + degrees * .pi / 180)
        }
        .buttonStyle(HLButtonStyle(kind: .secondary, height: 24))
        .help("Tourne la photo autour du point et pose une image clé (⌥[ et ⌥] avec Point choisi). Entre deux clés, la rotation est interpolée.")
    }

    private var hasGuideHere: Bool {
        GuideKind.allCases.contains { project.currentFrame?.guide($0)?.points != nil }
    }

    private var orientationInfo: String {
        let keys = project.frames.indices.filter(project.isRotationKey).count
        let angle = project.rotations.indices.contains(project.current) ? project.rotations[project.current] * 180 / .pi : 0
        let keyText = keys == 0 ? "aucune image clé" : "\(keys) image\(keys > 1 ? "s" : "") clé\(keys > 1 ? "s" : "")"
        if !project.frames.contains(where: { $0.guides != nil }) {
            return "Choisis Horiz., Vert. ou Symétrie, puis trace la ligne sur la photo : elle s'aimante au bord droit le plus proche."
        }
        return String(format: "Cette photo tourne de %+.2f° · ", angle).replacingOccurrences(of: ".", with: ",") + keyText
    }

    private var photoSection: some View {
        Group {
            title("Cette photo")
            if let f = project.currentFrame {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Palette.status(project.status(at: project.current))).frame(width: 3, height: 14)
                    Text(statusText(f)).font(Theme.body).foregroundStyle(Theme.text)
                }
                if project.isMatchCut, f.points != nil, f.status == .doubtful || f.status == .estimated {
                    Button { project.validateCurrent() } label: {
                        HStack {
                            Text("Le cadre est bon, valider")
                            Spacer()
                            Text("↩").foregroundStyle(Theme.muted)
                        }
                    }
                    .buttonStyle(HLButtonStyle(kind: .secondary, fullWidth: true))
                    .help("La photo passe en orange (placée à la main) : la recherche n'y touchera plus. Si le cadre est faux, déplace ses coins ou retrace-le : il passe aussi en orange.")
                }
                HStack(spacing: 6) {
                    Button("Référence") { project.makeReference() }
                        .buttonStyle(HLButtonStyle(kind: .secondary))
                        .disabled(project.current == project.refIndex || f.points == nil)
                        .help("Les autres photos s'alignent sur la référence (⌘R)")
                    Button("Effacer") { project.clearPoints(at: project.current) }
                        .buttonStyle(HLButtonStyle(kind: .ghost))
                        .disabled(project.targetPoints(at: project.current) == nil)
                        .help(project.editTarget == .anchor ? "Efface le repère de cette photo (⌫)" : "Efface la ligne de cette photo (⌫)")
                    Button("Effacer la suite") { project.clearPoints(after: project.current) }
                        .buttonStyle(HLButtonStyle(kind: .ghost))
                        .disabled(project.current + 1 >= project.frames.count)
                        .help(project.editTarget == .anchor ? "Efface les repères de toutes les photos suivantes (⌘Z pour revenir)"
                              : "Efface cette ligne sur toutes les photos suivantes (⌘Z pour revenir)")
                }
            }
            if project.isMatchCut, project.frames.count > 1 {
                HStack(spacing: 6) {
                    Text("Ordre").font(Theme.body).foregroundStyle(Theme.text)
                    Text("\(project.current + 1) / \(project.frames.count)").font(Theme.small.monospacedDigit()).foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    orderButton("arrow.left.to.line", "Mettre cette photo en premier (le plus petit)") { project.movePhoto(to: 0) }
                    orderButton("arrow.left", "Avancer d'une place (⌥⌘←)") { project.movePhoto(to: project.current - 1) }
                    orderButton("arrow.right", "Reculer d'une place (⌥⌘→)") { project.movePhoto(to: project.current + 1) }
                    orderButton("arrow.right.to.line", "Mettre cette photo en dernier (le plus gros)") { project.movePhoto(to: project.frames.count - 1) }
                }
                if let sz = project.elementSize(project.current) {
                    Text(String(format: "Élément mesuré : %.1f %% de la hauteur de la photo", sz * 100).replacingOccurrences(of: ".", with: ","))
                        .font(Theme.small.monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func orderButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 14) }
            .buttonStyle(HLButtonStyle(kind: .secondary, height: 24))
            .disabled(project.isTracking).help(help).accessibilityLabel(help)
    }

    private func statusText(_ f: Frame) -> String {
        var ref = project.current == project.refIndex ? "Référence · " : ""
        if let g = project.editTarget.guide { ref += "Ligne \(g.label.lowercased()) · " }
        let st = project.status(at: project.current), score = project.anchor(at: project.current)?.score
        switch st {
        case .none: return ref + (project.editTarget == .anchor ? "Pas de repère" : "Pas de ligne")
        case .manual: return ref + (project.editTarget == .anchor ? "Placé à la main" : "Tracée à la main, image clé")
        case .tracked: return ref + String(format: "Suivi, fiabilité %.0f %%", (score ?? 0) * 100)
        case .doubtful: return ref + String(format: "À vérifier, fiabilité %.0f %%", (score ?? 0) * 100)
        case .estimated: return ref + "Estimée entre les photos voisines, à vérifier"
        }
    }

    private var outputSection: some View {
        Group {
            title("Cadrage de sortie")
            Picker("Format", selection: $project.settings.output) {
                ForEach(OutputPreset.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            HStack(spacing: 10) {
                Text("Zoom").frame(width: 52, alignment: .leading)
                Slider(value: $project.settings.zoom, in: 1...2.5)
                Text(String(format: "%.0f %%", project.settings.zoom * 100)).monospacedDigit()
                    .foregroundStyle(Theme.muted).frame(width: 44, alignment: .trailing)
            }
            Button("Zoom auto, sans bords noirs") { project.autoZoom() }
                .buttonStyle(HLButtonStyle(kind: .secondary, fullWidth: true))
                .disabled(project.plan == nil)
            HStack(spacing: 10) {
                Text("Pelure").frame(width: 52, alignment: .leading)
                Slider(value: $project.onion, in: 0...0.8)
                Text(String(format: "%.0f %%", project.onion * 100)).monospacedDigit()
                    .foregroundStyle(Theme.muted).frame(width: 44, alignment: .trailing)
            }
            .help("Superpose la photo de référence en vue Aligné")
            .disabled(project.viewMode != .aligned)
            .opacity(project.viewMode == .aligned ? 1 : 0.45)
        }
    }
}

// MARK: - Export

@MainActor
final class ExportModel: ObservableObject {
    @Published var progress: Double?
    @Published var done: URL?
    @Published var error: String?
    private var task: Task<Void, Never>?

    func start(project: Project) {
        guard let plan = project.plan, let items = project.exportItems() else { return }
        let format = project.settings.format
        let panel = NSSavePanel()
        let base = (project.frames.first?.url.deletingPathExtension().lastPathComponent ?? "Hyperlapse") + "_hyperlapse"
        panel.nameFieldStringValue = format.isSequence ? base : "\(base).\(format.fileExtension)"
        panel.message = format.isSequence ? "Un dossier de ce nom sera créé avec les images." : "Enregistrer la vidéo"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if !format.isSequence, url.pathExtension.lowercased() != format.fileExtension {
            url = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        }
        let canvas = project.outputSize
        let g = plan.refToCanvas(canvas)
        let fps = project.settings.fps
        let hold = project.isMatchCut ? project.settings.holdFrames : 1  // a hyperlapse is always one frame per photo
        done = nil; error = nil; progress = 0
        task = Task { [weak self] in
            do {
                try await Exporter.run(items: items, refToCanvas: g, canvas: canvas, format: format, fps: fps,
                                       hold: hold, destination: url) { p in
                    Task { @MainActor in self?.progress = p }
                }
                self?.done = url
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.progress = nil
        }
    }

    func cancel() { task?.cancel() }
}

struct ExportSheet: View {
    @ObservedObject var project: Project
    @StateObject private var model = ExportModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Exporter la série alignée").font(Theme.font(17, .semibold)).foregroundStyle(Theme.text)
                Text(summary).font(Theme.body.monospacedDigit()).foregroundStyle(Theme.muted)
            }
            .padding(20)

            Form {
                Picker("Format", selection: $project.settings.format) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Taille", selection: $project.settings.output) {
                    ForEach(OutputPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Cadence", selection: $project.settings.fps) {
                    ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                }
                .disabled(project.settings.format.isSequence)
                if project.isMatchCut {
                    Picker("Durée de chaque photo", selection: $project.settings.holdFrames) {
                        Text("1 image").tag(1)
                        Text("2 images").tag(2)
                        Text("3 images").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .help("Chaque photo est répétée sur 1, 2 ou 3 images de la vidéo (ou de la séquence).")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.progress != nil)

            VStack(alignment: .leading, spacing: 10) {
                if let warning {
                    Text(warning).font(Theme.small).foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                }
                if let p = model.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.raised)
                                Capsule().fill(Theme.text).frame(width: max(4, g.size.width * p))
                            }
                        }
                        .frame(height: 4)
                        Text("Export en cours… \(Int(p * 100)) %").font(Theme.small.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                }
                if let done = model.done {
                    Text("Export terminé : \(done.lastPathComponent)").font(Theme.body).foregroundStyle(Theme.text)
                }
                if let err = model.error { Text(err).font(Theme.body).foregroundStyle(Theme.negative) }
                HStack(spacing: 8) {
                    if let done = model.done {
                        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                            .buttonStyle(HLButtonStyle(kind: .secondary))
                    }
                    Spacer()
                    if model.progress != nil {
                        Button("Annuler l'export") { model.cancel() }.buttonStyle(HLButtonStyle(kind: .secondary))
                    } else {
                        Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
                            .buttonStyle(HLButtonStyle(kind: .ghost))
                        Button("Exporter…") { model.start(project: project) }.keyboardShortcut(.defaultAction)
                            .buttonStyle(HLButtonStyle(kind: .primary))
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .background(Theme.surface)
        .tint(Theme.control)
    }

    private var summary: String {
        let photos = project.frames.count, size = project.outputSize
        let hold = project.isMatchCut ? project.settings.holdFrames : 1
        let n = photos * hold
        let what = hold > 1 ? "\(photos) photos × \(hold) = \(n) images" : "\(n) images"
        if project.settings.format.isSequence { return "\(what) · \(Int(size.width)) × \(Int(size.height))" }
        return String(format: "%@ · %.2f s · %d × %d", what, Double(n) / project.settings.fps.value,
                      Int(size.width), Int(size.height))
    }

    private var warning: String? {
        let missing = project.frames.count - project.anchoredCount
        let doubtful = project.doubtfulCount
        var parts: [String] = []
        if missing > 0 { parts.append("\(missing) photo(s) sans repère : elles reprennent l'alignement de la voisine.") }
        if doubtful > 0 { parts.append("\(doubtful) photo(s) à vérifier.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

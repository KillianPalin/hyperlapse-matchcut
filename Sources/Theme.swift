import AppKit
import SwiftUI

// Achromatic dark: the chrome holds no hue, so photos are judged against neutral grey (as in Lightroom
// or Resolve). Colour is kept for data: the anchor (orange signal) and what needs a look (red).

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum Theme {
    static let ground = Color(hex: 0x111111)      // window
    static let surface = Color(hex: 0x181818)     // panels
    static let well = Color(hex: 0x0B0B0B)        // behind the photo
    static let raised = Color(hex: 0x242424)      // secondary controls, tracks
    static let raisedHover = Color(hex: 0x2E2E2E)
    static let selected = Color(hex: 0x383838)    // selected segment
    static let border = Color(hex: 0x272727)
    static let rule = Color(hex: 0x222222)
    static let text = Color(hex: 0xEDEDED)
    static let muted = Color(hex: 0x929292)
    static let faint = Color(hex: 0x5C5C5C)
    static let control = Color(hex: 0x9E9E9E)     // tint of switches and sliders

    static let anchor = Color(hex: 0xFF7A1A)      // the anchor: the one signal colour
    static let negative = Color(hex: 0xFF5A4E)    // to check
    static let tracked = Color(hex: 0xA6A6A6)     // found by the tracking, in ink

    static let primaryFill = Color(hex: 0xEDEDED)
    static let primaryInk = Color(hex: 0x0A0A0A)

    static let radiusPanel: CGFloat = 8
    static let radiusControl: CGFloat = 6
    static let gap: CGFloat = 12
    static let pad: CGFloat = 16
    static let barHeight: CGFloat = 38

    /// Geist, bundled with the app (Resources/Fonts).
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }

    static let body = font(13)
    static let small = font(12)
    static let label = font(13, .medium)
    static let section = font(13, .semibold)
}

// MARK: - Buttons

enum ButtonKind { case primary, secondary, ghost, destructive }

struct HLButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var fullWidth = false
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        HLButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth, height: height)
    }
}

private struct HLButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ButtonKind
    let fullWidth: Bool
    let height: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(Theme.label)
            .lineLimit(1)
            .padding(.horizontal, kind == .ghost ? 8 : 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .foregroundStyle(ink)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.38)
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var ink: Color {
        switch kind {
        case .primary: Theme.primaryInk
        case .destructive: Theme.negative
        default: Theme.text
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: hovering ? Color.white : Theme.primaryFill
        case .secondary: hovering ? Theme.raisedHover : Theme.raised
        case .ghost, .destructive: hovering ? Theme.raised : .clear
        }
    }
}

/// Achromatic segmented control (the native one paints the selection in the accent colour).
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 28

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(Theme.font(13, on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.text : Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: height - 4)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusControl - 2).fill(on ? Theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.raised))
    }
}

/// A panel of the window: one tone step above the ground, a hairline edge, no shadow.
struct Panel<Content: View>: View {
    var fill: Color = Theme.surface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// The product mark: the viewfinder with its anchor point.
struct Mark: View {
    var size: CGFloat = 18
    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2), r = s.width * 0.24
            let lw = max(1.5, s.width * 0.1)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(Theme.anchor), lineWidth: lw)
            var p = Path()
            let a = r + s.width * 0.08, b = s.width / 2
            p.move(to: CGPoint(x: c.x - b, y: c.y)); p.addLine(to: CGPoint(x: c.x - a, y: c.y))
            p.move(to: CGPoint(x: c.x + a, y: c.y)); p.addLine(to: CGPoint(x: c.x + b, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - b)); p.addLine(to: CGPoint(x: c.x, y: c.y - a))
            p.move(to: CGPoint(x: c.x, y: c.y + a)); p.addLine(to: CGPoint(x: c.x, y: c.y + b))
            ctx.stroke(p, with: .color(Theme.anchor), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - lw * 0.7, y: c.y - lw * 0.7, width: lw * 1.4, height: lw * 1.4)),
                     with: .color(Theme.anchor))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Window

/// Hides the window title and lets the app draw its own bar under the traffic lights. No NSToolbar: its title
/// bar view sits above the content and would take the clicks of the app's bar.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = ChromeView()
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.backgroundColor = NSColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)
        }
    }
}

/// Lets the custom bar move the window like a title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}

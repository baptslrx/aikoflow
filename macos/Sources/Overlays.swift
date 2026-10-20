import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Bordure bleue autour de la fenêtre active

final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 13, yRadius: 13)
        path.lineWidth = 3
        Theme.accent.setStroke()
        path.stroke()
    }
}

@MainActor
final class FocusBorder {
    private var panel: NSPanel?

    func show(around frame: CGRect) {
        let p = panel ?? make()
        panel = p
        p.setFrame(frame.insetBy(dx: -4, dy: -4), display: true)
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = BorderView()
        return p
    }
}

// MARK: - Vue d'ensemble des pages

struct PagePreview: Identifiable {
    let id: Int
    let windows: [(frame: CGRect, bundleID: String, name: String)]
}

@MainActor
final class OverviewModel: ObservableObject {
    @Published var pages: [PagePreview] = []
    @Published var current = 1
    @Published var selected = 1
    var bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
}

struct OverviewView: View {
    @ObservedObject var model: OverviewModel
    var onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(Theme.accentUI)
                Text("Pages").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text("1 … 9, flèches, ↩ · Échap pour fermer").font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(300), spacing: 22), count: 3), spacing: 22) {
                ForEach(model.pages) { p in
                    card(p).onTapGesture { onPick(p.id) }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.78))
    }

    private func card(_ p: PagePreview) -> some View {
        let w: CGFloat = 300
        let h = w * model.bounds.height / max(model.bounds.width, 1)
        let isCurrent = p.id == model.current
        let isSelected = p.id == model.selected
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.10))
                ForEach(Array(p.windows.enumerated()), id: \.offset) { _, win in
                    let r = scaled(win.frame, w, h)
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.20))
                        RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.12))
                        if let icon = icon(win.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: min(34, r.height * 0.6), height: min(34, r.height * 0.6))
                        }
                    }
                    .frame(width: max(r.width, 6), height: max(r.height, 6))
                    .offset(x: r.minX, y: r.minY)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Theme.accentUI : (isCurrent ? Theme.accentUI.opacity(0.45) : Color.white.opacity(0.10)),
                        lineWidth: isSelected ? 3 : 1.5))
            HStack {
                Text("\(p.id)").font(.system(size: 15, weight: .bold)).foregroundStyle(isCurrent ? Theme.accentUI : .white)
                Text(p.windows.isEmpty ? "vide" : "\(p.windows.count) fenêtre\(p.windows.count > 1 ? "s" : "")")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func scaled(_ f: CGRect, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        let b = model.bounds
        let k = w / max(b.width, 1)
        return CGRect(x: (f.minX - b.minX) * k, y: (f.minY - b.minY) * k, width: f.width * k, height: f.height * k)
    }

    private func icon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Overview: NSObject, NSWindowDelegate {
    let model = OverviewModel()
    private var panel: KeyPanel?
    private var monitor: Any?
    var onPick: ((Int) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show(manager: Manager) {
        guard let screen = NSScreen.main else { return }
        model.bounds = ScreenGeometry.area(screen)
        model.current = manager.page
        model.selected = manager.page
        model.pages = (1...9).map { n in
            PagePreview(id: n, windows: manager.preview(page: n).filter { model.bounds.intersects($0.frame) })
        }
        let p = panel ?? make()
        panel = p
        p.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self else { return e }
                    return self.key(e) ? nil : e
                }
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func make() -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .modalPanel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.contentView = NSHostingView(rootView: OverviewView(model: model, onPick: { [weak self] n in self?.pick(n) }))
        return p
    }

    private func pick(_ n: Int) {
        hide()
        onPick?(n)
    }

    private func key(_ e: NSEvent) -> Bool {
        let code = Int(e.keyCode)
        if code == kVK_Escape || code == kVK_Tab { hide(); return true }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter { pick(model.selected); return true }
        if let i = Keys.digits.firstIndex(of: code) { pick(i + 1); return true }
        var s = model.selected
        switch code {
        case kVK_LeftArrow: s -= 1
        case kVK_RightArrow: s += 1
        case kVK_UpArrow: s -= 3
        case kVK_DownArrow: s += 3
        default: return false
        }
        model.selected = min(9, max(1, s))
        return true
    }
}

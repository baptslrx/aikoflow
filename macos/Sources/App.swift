import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
@MainActor
struct AikoFlowMain {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-window"), i + 1 < args.count {
            DemoWindow.run(number: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--selftest") {
            let test = SelfTest(outDir: URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "screenshots"))
            app.setActivationPolicy(.accessory)
            DispatchQueue.main.async { test.run() }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings: FlowSettings!
    private var manager: Manager!
    private var hotkeys: HotKeyCenter!
    private var drag: DragController!
    private let overview = Overview()
    private var statusItem: NSStatusItem!
    private var windowsByName: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install(appName: "AikoFlow")
        settings = FlowSettings()
        manager = Manager(settings: settings)
        manager.onChange = { [weak self] in self?.updateStatus() }
        drag = DragController(manager: manager, settings: settings)
        hotkeys = HotKeyCenter()
        overview.onPick = { [weak self] n in self?.manager.goTo(page: n) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !AX.isTrusted {
            AX.askTrust()
            showPermission()
        } else if settings.enableAtLaunch {
            manager.enable()
            drag.start()
        }
        registerHotkeys()
        updateStatus()

        if !UserDefaults.standard.bool(forKey: "welcomed") && AX.isTrusted {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showHelp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.disable()   // rend toutes les fenêtres visibles
    }

    // MARK: Raccourcis

    /// Coupé, AikoFlow ne garde que son raccourci « activer » pour ne gêner aucun autre raccourci.
    private func registerHotkeys() {
        hotkeys.unregisterAll()
        let m = settings.modKey.carbon
        let shift = UInt32(shiftKey), cmd = UInt32(cmdKey)
        let label = settings.modKey.symbol
        hotkeys.register(kVK_ANSI_P, m, label: "\(label) P") { [weak self] in
            MainActor.assumeIsolated { self?.toggleEnabled() }
        }
        guard manager.enabled else { return }
        for (i, code) in Keys.digits.enumerated() {
            hotkeys.register(code, m, label: "\(label) \(i + 1)") { [weak self] in
                MainActor.assumeIsolated { self?.manager.goTo(page: i + 1) }
            }
            hotkeys.register(code, m | shift, label: "\(label) ⇧ \(i + 1)") { [weak self] in
                MainActor.assumeIsolated { self?.manager.moveFocused(toPage: i + 1) }
            }
        }
        for (code, dir) in Keys.arrows {
            hotkeys.register(code, m, label: "\(label) flèche") { [weak self] in
                MainActor.assumeIsolated { self?.manager.focus(dir) }
            }
            hotkeys.register(code, m | shift, label: "\(label) ⇧ flèche") { [weak self] in
                MainActor.assumeIsolated { self?.manager.move(dir) }
            }
            hotkeys.register(code, m | cmd, label: "\(label) ⌘ flèche") { [weak self] in
                MainActor.assumeIsolated { self?.manager.resize(dir) }
            }
        }
        let simple: [(Int, String, @MainActor (Manager) -> Void)] = [
            (kVK_ANSI_F, "F", { $0.toggleFullscreen() }),
            (kVK_ANSI_T, "T", { $0.toggleFloating() }),
            (kVK_ANSI_S, "S", { $0.toggleSplit() }),
            (kVK_ANSI_R, "R", { $0.balance() }),
        ]
        for (code, key, action) in simple {
            hotkeys.register(code, m, label: "\(label) \(key)") { [weak self] in
                MainActor.assumeIsolated { if let mgr = self?.manager { action(mgr) } }
            }
        }
        hotkeys.register(kVK_Tab, m, label: "\(label) ⇥") { [weak self] in
            MainActor.assumeIsolated { self?.toggleOverview() }
        }
    }

    private func toggleEnabled() {
        if manager.enabled {
            overview.hide()
            drag.stop()
            manager.disable()
            Toast.shared.show("AikoFlow coupé — tes fenêtres sont libres")
        } else {
            guard AX.isTrusted else { showPermission(); return }
            manager.enable()
            drag.start()
            Toast.shared.show("AikoFlow activé · page \(manager.page)")
        }
        registerHotkeys()
        updateStatus()
    }

    private func toggleOverview() {
        if overview.isVisible { overview.hide() } else { overview.show(manager: manager) }
    }

    // MARK: Barre des menus : indicateur des pages

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        guard manager.enabled else {
            let img = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "AikoFlow coupé")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            img?.isTemplate = true
            button.image = img
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "AikoFlow — coupé (\(settings.modKey.symbol) P pour activer)"
            return
        }
        button.image = nil
        let occupied = manager.occupiedPages.union([manager.page])
        let s = NSMutableAttributedString()
        for n in occupied.sorted() {
            let current = n == manager.page
            s.append(NSAttributedString(string: " \(n) ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: current ? .bold : .regular),
                .foregroundColor: current ? Theme.accent : NSColor.secondaryLabelColor,
            ]))
        }
        button.attributedTitle = s
        button.toolTip = "AikoFlow — page \(manager.page)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let on = manager.enabled
        let toggle = item(on ? "Couper AikoFlow" : "Activer AikoFlow", #selector(menuToggle),
                          detail: "\(settings.modKey.symbol) P")
        menu.addItem(toggle)
        if on {
            menu.addItem(.separator())
            for n in 1...9 {
                let it = item("Page \(n)", #selector(menuPage(_:)), detail: "\(settings.modKey.symbol) \(n)")
                it.tag = n
                it.state = n == manager.page ? .on : .off
                if !manager.occupiedPages.contains(n) && n != manager.page {
                    it.attributedTitle = NSAttributedString(string: "Page \(n)", attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor])
                }
                menu.addItem(it)
            }
            menu.addItem(.separator())
            menu.addItem(item("Vue d'ensemble", #selector(menuOverview), detail: "\(settings.modKey.symbol) ⇥"))
            menu.addItem(item("Rééquilibrer", #selector(menuBalance), detail: "\(settings.modKey.symbol) R"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Raccourcis…", #selector(showHelp)))
        menu.addItem(item("Réglages…", #selector(openSettings)))
        if !AX.isTrusted { menu.addItem(item("Autoriser l'accessibilité…", #selector(showPermissionMenu))) }
        menu.addItem(.separator())
        menu.addItem(item("Quitter AikoFlow", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector, detail: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        if let detail {
            let s = NSMutableAttributedString(string: title)
            s.append(NSAttributedString(string: "    " + detail, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            it.attributedTitle = s
        }
        return it
    }

    @objc private func menuToggle() { toggleEnabled() }
    @objc private func menuPage(_ sender: NSMenuItem) { manager.goTo(page: sender.tag) }
    @objc private func menuOverview() { overview.show(manager: manager) }
    @objc private func menuBalance() { manager.balance() }
    @objc private func showPermissionMenu() { showPermission() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Fenêtres

    private func window<V: View>(_ name: String, title: String, _ view: V) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = windowsByName[name] { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        windowsByName[name] = w
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func showHelp() {
        windowsByName["help"]?.close()
        windowsByName["help"] = nil
        window("help", title: "Raccourcis AikoFlow", HelpView(settings: settings, conflicts: hotkeys.conflicts))
    }

    @objc private func openSettings() {
        window("settings", title: "Réglages AikoFlow", SettingsView(settings: settings, onChanged: { [weak self] in
            guard let self else { return }
            self.registerHotkeys()
            self.manager.scheduleRefresh()
            self.manager.updateBorder()
        }))
    }

    private func showPermission() {
        window("permission", title: "AikoFlow", PermissionView(
            onOpen: {
                AX.askTrust()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            },
            onRelaunch: {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
                try? p.run()
                NSApp.terminate(nil)
            }))
    }
}

// MARK: - Petite bulle d'information

@MainActor
final class Toast {
    static let shared = Toast()
    private var panel: NSPanel?
    private var work: DispatchWorkItem?

    func show(_ text: String) {
        guard let screen = NSScreen.main else { return }
        let dark = Theme.isDark()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        let size = NSSize(width: label.fittingSize.width + 36, height: 38)
        let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.97)
                                          : NSColor(white: 1, alpha: 0.98)).cgColor
        bg.layer?.cornerRadius = 19
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = Theme.accent.withAlphaComponent(0.6).cgColor
        label.frame = NSRect(x: 18, y: (38 - label.fittingSize.height) / 2, width: label.fittingSize.width,
                             height: label.fittingSize.height)
        bg.addSubview(label)
        p.contentView = bg
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - 60, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        panel = p
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel?.orderOut(nil) } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }
}

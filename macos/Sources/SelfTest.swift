import AppKit
import QuartzCore

/// Petite fenêtre de démonstration (lancée dans un processus séparé par le test automatique).
@MainActor
enum DemoWindow {
    static var keep: NSWindow?

    static func run(number: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 620, height: 420),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Démo \(number)"
        let v = NSView()
        v.wantsLayer = true
        let colors: [NSColor] = [Theme.accent, NSColor(white: 0.85, alpha: 1), Theme.accentDeep, NSColor(white: 0.3, alpha: 1)]
        v.layer?.backgroundColor = colors[(Int(number) ?? 1) % colors.count].cgColor
        let label = NSTextField(labelWithString: number)
        label.font = .systemFont(ofSize: 90, weight: .bold)
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        keep = w
        app.run()
    }
}

/// `AikoFlow --selftest <dossier>` : test en direct avec de vraies fenêtres (si l'accessibilité est accordée).
@MainActor
final class SelfTest {
    let outDir: URL
    private var failures: [String] = []
    private var report: [String] = []
    private var demos: [Process] = []
    private let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil

    init(outDir: URL) { self.outDir = outDir }

    func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await steps()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { [weak self] in
            MainActor.assumeIsolated {
                self?.check(false, "le test a dépassé 2 min 30")
                self?.finish()
            }
        }
    }

    private func log(_ s: String) {
        print(s)
        fflush(stdout)
        report.append(s)
    }

    private func check(_ ok: Bool, _ what: String) {
        log((ok ? "  ok   " : "  FAIL ") + what)
        if !ok {
            failures.append(what)
            if ci { print("::error title=Test en direct::\(what)") }
        }
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func shot(_ name: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", outDir.appendingPathComponent(name).path]
        try? p.run()
        p.waitUntilExit()
        log("   capture \(name)")
    }

    private func steps() async {
        log("Accessibilité accordée : \(AX.isTrusted ? "oui" : "non")")
        guard AX.isTrusted else {
            log("  (test en direct impossible sur cette machine — seuls les tests du pavage ont tourné)")
            if ci { print("::warning title=Test en direct::accessibilité non accordée sur la machine de test") }
            return
        }
        let exe = Bundle.main.executablePath!
        for n in 1...3 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["--demo-window", "\(n)"]
            try? p.run()
            demos.append(p)
            await sleep(1.2)
        }
        await sleep(1.5)
        let pids = Set(demos.map(\.processIdentifier))
        let settings = FlowSettings()
        settings.innerGap = 8
        settings.outerGap = 10
        settings.ignored = []
        let m = Manager(settings: settings)
        m.enable()
        await sleep(1.5)
        m.refresh()
        let demoWindows = m.windows.values.filter { pids.contains($0.pid) }
        log("   fenêtres gérées : \(m.windows.count) (dont démos : \(demoWindows.count))")
        check(demoWindows.count == 3, "les 3 fenêtres de démo sont prises en charge")

        let frames = demoWindows.compactMap { AX.frame($0.element) }
        let area = ScreenGeometry.area(NSScreen.main!)
        var overlap = false
        for i in frames.indices { for j in frames.indices where i < j && frames[i].insetBy(dx: 2, dy: 2).intersects(frames[j]) { overlap = true } }
        check(!overlap, "aucune fenêtre ne se chevauche")
        check(frames.allSatisfy { area.insetBy(dx: -2, dy: -2).contains($0) }, "toutes dans la zone de l'écran")
        log("   cadres : " + frames.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" }.joined(separator: " | "))
        shot("1-pavage.png")

        guard let moved = demoWindows.first else { return }
        m.send(moved.id, toPage: 2)
        await sleep(0.8)
        let hiddenFrame = AX.frame(moved.element) ?? .zero
        let corner = ScreenGeometry.hiddenCorner
        check(hiddenFrame.minX >= corner.x - 3, "fenêtre envoyée page 2 : rangée hors de l'écran")
        let rest = demoWindows.filter { $0.id != moved.id }.compactMap { AX.frame($0.element) }
        let shared = rest.count == 2
            && (abs(rest[0].height - rest[1].height) < 3 || abs(rest[0].width - rest[1].width) < 3)
        check(shared, "les 2 autres se partagent la place")
        shot("2-page1-apres-envoi.png")

        m.goTo(page: 2)
        await sleep(0.8)
        let full = AX.frame(moved.element) ?? .zero
        check(abs(full.width - (area.width - 20)) < 4, "page 2 : la fenêtre seule prend toute la largeur (\(Int(full.width)))")
        check(demoWindows.filter { $0.id != moved.id }.allSatisfy { $0.hidden }, "page 2 : les fenêtres de la page 1 sont cachées")
        shot("3-page2.png")

        m.goTo(page: 1)
        await sleep(0.8)
        if let a = demoWindows.first(where: { $0.id != moved.id }) {
            m.balance()
            let before = AX.frame(a.element) ?? .zero
            AX.raise(a.element)
            AX.setFrontmost(a.pid)
            await sleep(0.5)
            m.resize(.right)
            await sleep(0.5)
            let after = AX.frame(a.element) ?? .zero
            check(abs(after.width - before.width) > 20 || abs(after.minX - before.minX) > 20,
                  "agrandir au clavier déplace la séparation")
        }

        log("== Souris : ⌃⌥ + glisser")
        let drag = DragController(manager: m, settings: settings)
        drag.start()
        check(drag.isRunning, "écoute de la souris active")
        let page1 = demoWindows.filter { $0.page == 1 }
        if page1.count == 2, let fa = page1[0].placed, let fb = page1[1].placed {
            let a = page1[0], b = page1[1]
            func post(_ type: CGEventType, _ p: CGPoint) {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
                e?.flags = [.maskControl, .maskAlternate]
                e?.post(tap: .cghidEventTap)
            }
            let start = CGPoint(x: fa.midX, y: fa.midY), end = CGPoint(x: fb.midX, y: fb.midY)
            post(.leftMouseDown, start)
            await sleep(0.2)
            var followed = false
            for i in 1...12 {
                let t = CGFloat(i) / 12
                post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                await sleep(0.04)
                if i == 6, let mid = AX.frame(a.element), abs(mid.minX - fa.minX) > 40 || abs(mid.minY - fa.minY) > 40 {
                    followed = true
                }
            }
            shot("4a-glisser.png")
            post(.leftMouseUp, end)
            await sleep(0.7)
            check(followed, "la fenêtre suit la souris pendant le glissement")
            let na = AX.frame(a.element) ?? .zero, nb = AX.frame(b.element) ?? .zero
            check(abs(na.minX - fb.minX) < 4 && abs(na.minY - fb.minY) < 4 && abs(nb.minX - fa.minX) < 4,
                  "lâchée sur l'autre fenêtre : elles échangent leur place")
        } else {
            check(false, "2 fenêtres attendues sur la page 1 pour le test de glisser (\(page1.count))")
        }
        drag.stop()

        log("== Vitesse")
        settings.animations = false
        var t0 = CACurrentMediaTime()
        m.goTo(page: 2)
        let instant = (CACurrentMediaTime() - t0) * 1000
        await sleep(0.4)
        m.goTo(page: 1)
        await sleep(0.4)
        settings.animations = true
        t0 = CACurrentMediaTime()
        m.goTo(page: 2)
        let mainThread = (CACurrentMediaTime() - t0) * 1000
        await sleep(0.5)
        let onPage2 = AX.frame(moved.element) ?? .zero
        check(abs(onPage2.width - (area.width - 20)) < 4, "avec animation, la fenêtre arrive à la bonne place")
        log(String(format: "   changement de page : %.0f ms sans animation, %.0f ms d'attente avec animation (puis %.0f ms d'animation en arrière-plan)",
                   instant, mainThread, settings.animationDuration * 1000))
        check(mainThread < 60, "changer de page ne bloque pas (\(Int(mainThread)) ms)")
        m.goTo(page: 1)
        await sleep(0.5)

        let overview = Overview()
        overview.show(manager: m)
        await sleep(1.0)
        shot("4-vue-ensemble.png")
        overview.hide()

        m.disable()
        await sleep(0.8)
        let all = demoWindows.compactMap { AX.frame($0.element) }
        check(all.allSatisfy { $0.minX < corner.x - 50 }, "en coupant AikoFlow, toutes les fenêtres réapparaissent")
        shot("5-coupe.png")
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        demos.forEach { $0.terminate() }
        log(failures.isEmpty ? "\nTout est OK" : "\nÉCHECS :\n" + failures.joined(separator: "\n"))
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("rapport.txt"), atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
    }
}

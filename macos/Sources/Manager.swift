import AppKit
import ApplicationServices

/// Une fenêtre suivie par AikoFlow.
final class ManagedWindow {
    let id: UInt32
    let pid: pid_t
    let element: AXUIElement
    var page: Int
    var screen: CGDirectDisplayID
    var floating: Bool
    var appName: String
    var bundleID: String
    /// Dernier cadre posé par AikoFlow (pour reconnaître nos propres déplacements).
    var placed: CGRect?
    /// Cadre de la fenêtre avant qu'on la cache ou qu'on la range (pour la rendre en partant).
    var lastVisible: CGRect?
    var hidden = false

    init(id: UInt32, pid: pid_t, element: AXUIElement, page: Int, screen: CGDirectDisplayID, floating: Bool,
         appName: String, bundleID: String) {
        self.id = id
        self.pid = pid
        self.element = element
        self.page = page
        self.screen = screen
        self.floating = floating
        self.appName = appName
        self.bundleID = bundleID
    }
}

@MainActor
final class Manager {
    let settings: FlowSettings
    private(set) var enabled = false
    private(set) var page = 1
    private(set) var windows: [UInt32: ManagedWindow] = [:]
    private var layouts: [String: Layout] = [:]
    private var fullscreen: [Int: UInt32] = [:]
    private var lastFocused: [Int: UInt32] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var safetyTimer: Timer?
    private var userChangeTimer: Timer?
    private var pendingUserChange: Set<UInt32> = []
    private var suppressFocusUntil = Date.distantPast
    let border = FocusBorder()

    var onChange: (() -> Void)?

    init(settings: FlowSettings) {
        self.settings = settings
    }

    // MARK: - Marche / arrêt

    func enable() {
        guard !enabled, AX.isTrusted else { return }
        enabled = true
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                                 queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self?.observe(app) }
                self?.scheduleRefresh(after: 0.6)
            }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                 queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.observers[pid] = nil }
                self?.scheduleRefresh()
            }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusChanged() }
        })
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { observe(app) }

        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t
        refresh()
        onChange?()
    }

    /// Coupe AikoFlow et rend toutes les fenêtres visibles, là où elles étaient.
    func disable() {
        guard enabled else { return }
        enabled = false
        safetyTimer?.invalidate()
        safetyTimer = nil
        userChangeTimer?.invalidate()
        refreshWork?.cancel()
        workspaceObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        workspaceObservers.removeAll()
        for (_, obs) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observers.removeAll()
        restoreAll()
        windows.removeAll()
        layouts.removeAll()
        fullscreen.removeAll()
        border.hide()
        onChange?()
    }

    private func restoreAll() {
        for w in windows.values where w.hidden {
            let target = w.lastVisible ?? w.placed ?? defaultFrame(for: w)
            AX.setFrame(w.element, target)
            w.hidden = false
        }
    }

    private func defaultFrame(for w: ManagedWindow) -> CGRect {
        let area = ScreenGeometry.area(screen(w.screen) ?? NSScreen.main!)
        return area.insetBy(dx: area.width * 0.15, dy: area.height * 0.15)
    }

    // MARK: - Suivi des applis (AXObserver)

    private static let notifications = [
        kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<Manager>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            MainActor.assumeIsolated { me.axEvent(n, element) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notifications { AXObserverAddNotification(obs, appElement, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func axEvent(_ name: String, _ element: AXUIElement) {
        guard enabled else { return }
        switch name {
        case kAXFocusedWindowChangedNotification:
            focusChanged()
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let id = AX.windowID(element), let w = windows[id], id != dragging else { return }
            // Seuls les déplacements faits à la souris comptent (les nôtres arrivent bouton relâché)
            if NSEvent.pressedMouseButtons != 0, !w.hidden, !w.floating, let placed = w.placed,
               let now = AX.frame(element), !close(now, placed) {
                pendingUserChange.insert(id)
                waitForMouseUp()
            }
            if id == focusedID { updateBorder() }
        default:
            scheduleRefresh()
        }
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    func scheduleRefresh(after delay: Double = 0.12) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Inventaire des fenêtres

    private func key(_ page: Int, _ screen: CGDirectDisplayID) -> String { "\(page)-\(screen)" }

    private func layout(_ page: Int, _ screen: CGDirectDisplayID) -> Layout {
        let k = key(page, screen)
        if let l = layouts[k] { return l }
        let l = Layout()
        layouts[k] = l
        return l
    }

    func screen(_ id: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { $0.displayID == id } }

    /// Fenêtre « normale » à gérer ? (pas une boîte de dialogue, une palette, une fenêtre plein écran…)
    private func isManageable(_ e: AXUIElement) -> Bool {
        let role: String? = AX.attr(e, kAXRoleAttribute)
        let subrole: String? = AX.attr(e, kAXSubroleAttribute)
        guard role == kAXWindowRole as String, subrole == kAXStandardWindowSubrole as String else { return false }
        if AX.bool(e, kAXMinimizedAttribute) || AX.bool(e, "AXFullScreen") { return false }
        return AX.isSettable(e, kAXPositionAttribute)
    }

    private func shouldFloat(_ e: AXUIElement, bundleID: String) -> Bool {
        if settings.floatingBundleIDs.contains(bundleID) { return true }
        if !AX.isSettable(e, kAXSizeAttribute) { return true }
        // Les petites fenêtres non redimensionnables (calculatrice, réglages…) restent flottantes
        if let s = AX.size(e), s.width < 300 || s.height < 200 { return true }
        return false
    }

    func refresh() {
        guard enabled else { return }
        var seen: Set<UInt32> = []
        let focused = AX.focusedWindow().flatMap(AX.windowID)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            let bundle = app.bundleIdentifier ?? ""
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !settings.ignoredBundleIDs.contains(bundle) else { continue }
            observe(app)
            for e in AX.windows(of: app.processIdentifier) {
                guard let id = AX.windowID(e) else { continue }
                if let existing = windows[id] {
                    seen.insert(id)
                    if !isManageable(e) && !existing.hidden { forget(id) ; seen.remove(id) }
                    continue
                }
                guard isManageable(e) else { continue }
                seen.insert(id)
                adopt(e, id: id, app: app, nearFocused: focused)
            }
        }
        for id in Array(windows.keys) where !seen.contains(id) { forget(id) }
        apply()
    }

    private func adopt(_ e: AXUIElement, id: UInt32, app: NSRunningApplication, nearFocused: UInt32?) {
        var frame = AX.frame(e) ?? .zero
        // Fenêtre restée cachée après un arrêt brutal : on la ramène
        let corner = ScreenGeometry.hiddenCorner
        if frame.minX >= corner.x - 2 || frame.minY >= corner.y - 2 {
            frame.origin = ScreenGeometry.area(NSScreen.main!).origin
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let scr = ScreenGeometry.screen(containing: center)?.displayID ?? NSScreen.main!.displayID
        let bundle = app.bundleIdentifier ?? ""
        let w = ManagedWindow(id: id, pid: app.processIdentifier, element: e, page: page, screen: scr,
                              floating: shouldFloat(e, bundleID: bundle), appName: app.localizedName ?? "",
                              bundleID: bundle)
        w.lastVisible = frame
        windows[id] = w
        if !w.floating {
            let target = nearFocused.flatMap { windows[$0] }.flatMap { $0.page == page && $0.screen == scr ? $0.id : nil }
            layout(page, scr).insert(id, near: target, area: areaFor(scr), gaps: gaps)
        }
    }

    private func forget(_ id: UInt32) {
        guard let w = windows[id] else { return }
        layouts[key(w.page, w.screen)]?.remove(id)
        if fullscreen[w.page] == id { fullscreen[w.page] = nil }
        windows[id] = nil
    }

    private var gaps: Gaps { Gaps(inner: CGFloat(settings.innerGap), outer: CGFloat(settings.outerGap)) }

    private func areaFor(_ scr: CGDirectDisplayID) -> CGRect {
        ScreenGeometry.area(screen(scr) ?? NSScreen.main!)
    }

    private func screensChanged() {
        let valid = Set(NSScreen.screens.map(\.displayID))
        let fallback = NSScreen.main?.displayID ?? 0
        for w in windows.values where !valid.contains(w.screen) {
            layouts[key(w.page, w.screen)]?.remove(w.id)
            w.screen = fallback
            if !w.floating { layout(w.page, fallback).insert(w.id, near: nil, area: areaFor(fallback), gaps: gaps) }
        }
        layouts = layouts.filter { k, _ in valid.contains(where: { k.hasSuffix("-\($0)") }) }
        apply()
    }

    // MARK: - Placement

    let animator = Animator()
    /// Fenêtre tenue à la souris (⌃⌥ + glisser) : AikoFlow ne la replace pas pendant ce temps.
    var dragging: UInt32?
    /// Sens du glissement des fenêtres qui arrivent lors d'un changement de page (−1 : depuis la gauche, 1 : depuis la droite).
    private var slide: CGFloat = 0

    /// Place toutes les fenêtres : celles de la page en cours à leur case, les autres rangées hors de l'écran.
    func apply(animated: Bool = true) {
        guard enabled else { return }
        let corner = ScreenGeometry.hiddenCorner
        var moves: [FrameMove] = []
        var hides: [FrameMove] = []
        var targets: [UInt32: CGRect] = [:]
        for scr in NSScreen.screens {
            let id = scr.displayID
            let area = ScreenGeometry.area(scr)
            for (wid, f) in layout(page, id).frames(area: area, gaps: gaps) {
                guard let w = windows[wid], wid != dragging else { continue }
                let target = fullscreen[page] == wid ? area.insetBy(dx: gaps.outer, dy: gaps.outer) : f
                targets[wid] = target
                if !w.hidden, let placed = w.placed, close(placed, target) { continue }   // déjà en place : rien à faire
                var from: CGRect? = w.hidden ? nil : (w.placed ?? w.lastVisible)
                if w.hidden && slide != 0 { from = target.offsetBy(dx: slide * area.width * 0.18, dy: 0) }
                moves.append(FrameMove(pid: w.pid, element: w.element, from: from, to: target))
                w.placed = target
                w.lastVisible = target
                w.hidden = false
            }
        }
        for w in windows.values where w.id != dragging {
            if w.page == page {
                if w.floating && w.hidden {
                    let f = w.lastVisible ?? defaultFrame(for: w)
                    moves.append(FrameMove(pid: w.pid, element: w.element, from: nil, to: f))
                    w.hidden = false
                }
            } else if !w.hidden {
                if let p = w.placed, !w.floating { w.lastVisible = p }
                else if let f = AX.frame(w.element) { w.lastVisible = f }
                let size = w.lastVisible?.size ?? CGSize(width: 800, height: 600)
                hides.append(FrameMove(pid: w.pid, element: w.element, from: nil,
                                       to: CGRect(origin: corner, size: size)))
                w.hidden = true
            }
        }
        slide = 0
        let duration = animated && settings.animations ? settings.animationDuration : 0
        let fs = fullscreen[page].flatMap { windows[$0] }
        // Les fenêtres qui partent sont rangées tout de suite, celles qui arrivent glissent à leur place
        animator.run(hides + moves, duration: duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                if let fs { AX.raise(fs.element) }
                // Applis à taille minimale : on retient le cadre réel
                for m in moves {
                    if let id = AX.windowID(m.element), let w = self.windows[id], let real = AX.frame(m.element),
                       !self.close(real, m.to) {
                        w.placed = real
                    }
                }
                self.updateBorder()
            }
        }
        if let id = focusedID, let f = targets[id] { border.show(around: ScreenGeometry.toCocoa(f)) } else { updateBorder() }
        onChange?()
    }

    // MARK: - Focus

    var focusedID: UInt32? {
        AX.focusedWindow().flatMap(AX.windowID).flatMap { windows[$0] != nil ? $0 : nil }
    }

    private func focusChanged() {
        guard enabled else { return }
        guard let id = AX.focusedWindow().flatMap(AX.windowID) else { border.hide(); return }
        if windows[id] == nil { scheduleRefresh() }
        if let w = windows[id] {
            // ⌘⇥ vers une fenêtre rangée sur une autre page : on suit
            if w.page != page && Date() > suppressFocusUntil {
                goTo(page: w.page, focus: false)
            }
            lastFocused[w.page] = id
        }
        updateBorder()
    }

    func updateBorder() {
        guard enabled, dragging == nil, settings.showBorder, let id = focusedID, let w = windows[id], w.page == page, !w.hidden,
              let f = AX.frame(w.element) else {
            border.hide()
            return
        }
        border.show(around: ScreenGeometry.toCocoa(f))
    }

    private func focus(_ w: ManagedWindow) {
        lastFocused[w.page] = w.id
        AX.raise(w.element)
        AX.setFrontmost(w.pid)
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated { self?.updateBorder() }
        }
    }

    /// Cadres actuels des fenêtres de la page (tous écrans), pour les déplacements au clavier.
    private func pageFrames() -> [UInt32: CGRect] {
        var out: [UInt32: CGRect] = [:]
        for w in windows.values where w.page == page && !w.hidden {
            if let f = w.placed ?? AX.frame(w.element) { out[w.id] = f }
        }
        return out
    }

    // MARK: - Commandes

    func goTo(page n: Int, focus shouldFocus: Bool = true) {
        guard enabled, (1...9).contains(n), n != page else { return }
        slide = n > page ? 1 : -1
        page = n
        suppressFocusUntil = Date().addingTimeInterval(0.5)
        apply()
        if shouldFocus {
            let target = lastFocused[n].flatMap { windows[$0] }.flatMap { $0.page == n ? $0 : nil }
                ?? windows.values.first { $0.page == n }
            if let target { focus(target) } else { border.hide() }
        }
        onChange?()
    }

    func moveFocused(toPage n: Int) {
        guard let id = focusedID else { return }
        send(id, toPage: n)
    }

    func send(_ id: UInt32, toPage n: Int) {
        guard enabled, (1...9).contains(n), n != page, let w = windows[id] else { return }
        layouts[key(w.page, w.screen)]?.remove(id)
        if fullscreen[w.page] == id { fullscreen[w.page] = nil }
        w.page = n
        if !w.floating { layout(n, w.screen).insert(id, near: lastFocused[n], area: areaFor(w.screen), gaps: gaps) }
        lastFocused[n] = id
        apply()
        if let next = windows.values.first(where: { $0.page == page }) { focus(next) }
    }

    func focus(_ dir: Direction) {
        guard enabled else { return }
        let frames = pageFrames()
        let current = focusedID ?? lastFocused[page]
        guard let from = current, let to = neighbor(of: from, dir, in: frames), let w = windows[to] else { return }
        focus(w)
    }

    /// Échange la fenêtre active avec sa voisine (ou l'envoie sur l'écran d'à côté).
    func move(_ dir: Direction) {
        guard enabled, let id = focusedID, let w = windows[id], !w.floating else { return }
        let frames = pageFrames()
        guard let other = neighbor(of: id, dir, in: frames), let o = windows[other] else { return }
        if o.screen == w.screen {
            layout(page, w.screen).swap(id, other)
        } else if !o.floating {
            layout(page, w.screen).remove(id)
            w.screen = o.screen
            layout(page, o.screen).insert(id, near: other, area: areaFor(o.screen), gaps: gaps)
        }
        apply()
        focus(w)
    }

    func resize(_ dir: Direction) {
        guard enabled, let id = focusedID, let w = windows[id], !w.floating else { return }
        layout(page, w.screen).resize(id, dir)
        apply()
    }

    func toggleSplit() {
        guard enabled, let id = focusedID, let w = windows[id] else { return }
        layout(page, w.screen).toggleSplit(id)
        apply()
    }

    func toggleFullscreen() {
        guard enabled, let id = focusedID, windows[id] != nil else { return }
        fullscreen[page] = fullscreen[page] == id ? nil : id
        apply()
    }

    func toggleFloating() {
        guard enabled, let id = focusedID, let w = windows[id] else { return }
        w.floating.toggle()
        if w.floating {
            layout(page, w.screen).remove(id)
            let area = areaFor(w.screen)
            AX.setFrame(w.element, area.insetBy(dx: area.width * 0.2, dy: area.height * 0.15))
            w.placed = nil
        } else {
            layout(page, w.screen).insert(id, near: nil, area: areaFor(w.screen), gaps: gaps)
        }
        apply()
    }

    func balance() {
        guard enabled else { return }
        for scr in NSScreen.screens { layout(page, scr.displayID).balance() }
        apply()
    }

    // MARK: - Déplacements à la souris

    private func waitForMouseUp() {
        guard userChangeTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                self?.userChangeTimer = nil
                self?.handleUserChanges()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        userChangeTimer = t
    }

    private func handleUserChanges() {
        let ids = pendingUserChange
        pendingUserChange.removeAll()
        for id in ids {
            guard let w = windows[id], w.page == page, let placed = w.placed, let now = AX.frame(w.element) else { continue }
            defer { w.placed = now }   // pour qu'apply() la remette bien à sa place si besoin
            let resized = abs(now.width - placed.width) > 3 || abs(now.height - placed.height) > 3
            if resized {
                layout(page, w.screen).adopt(id, newFrame: now, area: areaFor(w.screen), gaps: gaps)
            } else {
                // Déposée sur une autre fenêtre : on échange ; sur un autre écran : elle y part
                let center = CGPoint(x: now.midX, y: now.midY)
                if let target = windows.values.first(where: { o in
                    o.id != id && o.page == page && !o.floating && (o.placed?.contains(center) ?? false)
                }) {
                    if target.screen == w.screen {
                        layout(page, w.screen).swap(id, target.id)
                    } else {
                        layout(page, w.screen).remove(id)
                        w.screen = target.screen
                        layout(page, target.screen).insert(id, near: target.id, area: areaFor(target.screen), gaps: gaps)
                    }
                } else if let scr = ScreenGeometry.screen(containing: center), scr.displayID != w.screen {
                    layout(page, w.screen).remove(id)
                    w.screen = scr.displayID
                    layout(page, scr.displayID).insert(id, near: nil, area: areaFor(scr.displayID), gaps: gaps)
                }
            }
        }
        apply()
    }

    // MARK: - ⌃⌥ + souris : déplacer / redimensionner n'importe où dans la fenêtre

    /// Fenêtre gérée sous le pointeur (coordonnées écran, origine en haut à gauche).
    func windowAt(_ p: CGPoint) -> ManagedWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  let n = info[kCGWindowNumber as String] as? UInt32 else { continue }
            return windows[n]   // la plus en avant ; nil si elle n'est pas gérée
        }
        return nil
    }

    func beginDrag(_ w: ManagedWindow) {
        dragging = w.id
        lastFocused[w.page] = w.id
        AX.raise(w.element)
        AX.setFrontmost(w.pid)
        border.hide()   // la bordure revient quand on lâche
    }

    /// Fenêtre rangée sur laquelle on lâcherait (pour l'aperçu).
    func dropTarget(for id: UInt32, at p: CGPoint) -> ManagedWindow? {
        windows.values.first { o in
            o.id != id && o.page == page && !o.floating && !o.hidden && (o.placed?.contains(p) ?? false)
        }
    }

    func endDrag(at p: CGPoint) {
        guard let id = dragging, let w = windows[id] else { dragging = nil; return }
        dragging = nil
        pendingUserChange.remove(id)
        if w.floating {
            w.lastVisible = AX.frame(w.element)
        } else if let target = dropTarget(for: id, at: p) {
            if target.screen == w.screen {
                layout(page, w.screen).swap(id, target.id)
            } else {
                layout(page, w.screen).remove(id)
                w.screen = target.screen
                layout(page, target.screen).insert(id, near: target.id, area: areaFor(target.screen), gaps: gaps)
            }
        } else if let scr = ScreenGeometry.screen(containing: p), scr.displayID != w.screen {
            layout(page, w.screen).remove(id)
            w.screen = scr.displayID
            layout(page, scr.displayID).insert(id, near: nil, area: areaFor(scr.displayID), gaps: gaps)
        }
        // Retour en douceur de là où on l'a lâchée
        if let now = AX.frame(w.element) { w.placed = now }
        apply()
    }

    /// Redimensionnement à la souris, en direct : les autres fenêtres suivent.
    func liveResize(_ w: ManagedWindow, to f: CGRect) {
        if w.floating {
            AX.setFrame(w.element, f)
            w.lastVisible = f
            return
        }
        layout(page, w.screen).adopt(w.id, newFrame: f, area: areaFor(w.screen), gaps: gaps)
        let saved = dragging
        dragging = nil
        apply(animated: false)
        dragging = saved
    }

    func endResize() {
        if let id = dragging { pendingUserChange.remove(id) }
        dragging = nil
        apply()
    }

    // MARK: - Pour la vue d'ensemble et la barre des menus

    var occupiedPages: Set<Int> { Set(windows.values.map(\.page)) }

    /// Cadres de chaque fenêtre d'une page (tels qu'ils seraient affichés), avec l'appli.
    func preview(page n: Int) -> [(frame: CGRect, bundleID: String, name: String)] {
        var out: [(CGRect, String, String)] = []
        for scr in NSScreen.screens {
            let frames = layout(n, scr.displayID).frames(area: ScreenGeometry.area(scr), gaps: gaps)
            for (id, f) in frames { if let w = windows[id] { out.append((f, w.bundleID, w.appName)) } }
        }
        for w in windows.values where w.page == n && w.floating {
            if let f = w.lastVisible { out.append((f, w.bundleID, w.appName)) }
        }
        return out.map { (frame: $0.0, bundleID: $0.1, name: $0.2) }
    }
}

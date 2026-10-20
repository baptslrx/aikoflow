import AppKit
import ApplicationServices

/// Aperçu bleu de l'endroit où la fenêtre va se ranger quand on la lâche.
@MainActor
final class DropHighlight {
    private var panel: NSPanel?

    func show(_ axFrame: CGRect) {
        let p = panel ?? make()
        panel = p
        p.setFrame(ScreenGeometry.toCocoa(axFrame), display: true)
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
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.22).cgColor
        v.layer?.borderColor = Theme.accent.cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 13
        p.contentView = v
        return p
    }
}

/// Déplace une fenêtre en continu sans bloquer : on ne garde que la dernière position demandée.
final class Mover: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.aikographic.aikoflow.mover", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (AXUIElement, CGRect, Bool)?
    private var busy = false

    func move(_ e: AXUIElement, to f: CGRect, resize: Bool) {
        lock.lock()
        pending = (e, f, resize)
        let start = !busy
        busy = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let job = pending else { busy = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                if job.2 { AX.setSize(job.0, job.1.size) }
                AX.setPosition(job.0, job.1.origin)
            }
        }
    }
}

/// ⌃⌥ (la touche de base) + clic gauche maintenu : la fenêtre suit la souris, où qu'on l'attrape.
/// ⌃⌥ + clic droit maintenu : on la redimensionne par le coin le plus proche.
@MainActor
final class DragController {
    enum Mode {
        case none
        case move(window: ManagedWindow, offset: CGPoint, size: CGSize)
        case resize(window: ManagedWindow, start: CGRect, mouse: CGPoint, left: Bool, top: Bool)
    }

    private weak var manager: Manager?
    private let settings: FlowSettings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var mode: Mode = .none
    private let mover = Mover()
    private let highlight = DropHighlight()
    private var lastResize = 0.0

    init(manager: Manager, settings: FlowSettings) {
        self.manager = manager
        self.settings = settings
    }

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<DragController>.fromOpaque(refcon).takeUnretainedValue()
            let consume = MainActor.assumeIsolated { me.handle(type, event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        cancel()
    }

    private func modsHeld(_ flags: CGEventFlags) -> Bool {
        let wanted: CGEventFlags = settings.modKey == .controlOption ? [.maskControl, .maskAlternate] : [.maskAlternate]
        return flags.contains(wanted) && !flags.contains(.maskCommand)
    }

    /// Renvoie vrai si l'évènement est « mangé » (l'appli en dessous ne le reçoit pas).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let manager, manager.enabled, settings.mouseDrag else { return false }
        let p = event.location
        switch type {
        case .leftMouseDown:
            guard modsHeld(event.flags), let w = manager.windowAt(p) else { return false }
            beginMove(w, at: p)
            return true
        case .rightMouseDown:
            guard modsHeld(event.flags), let w = manager.windowAt(p) else { return false }
            beginResize(w, at: p)
            return true
        case .leftMouseDragged, .rightMouseDragged:
            if case .none = mode { return false }
            drag(to: p)
            return true
        case .leftMouseUp, .rightMouseUp:
            if case .none = mode { return false }
            end(at: p)
            return true
        default:
            return false
        }
    }

    // Utilisé aussi par le test automatique

    func beginMove(_ w: ManagedWindow, at p: CGPoint) {
        let f = AX.frame(w.element) ?? w.placed ?? .zero
        mode = .move(window: w, offset: CGPoint(x: p.x - f.minX, y: p.y - f.minY), size: f.size)
        manager?.beginDrag(w)
    }

    func beginResize(_ w: ManagedWindow, at p: CGPoint) {
        let f = AX.frame(w.element) ?? w.placed ?? .zero
        mode = .resize(window: w, start: f, mouse: p, left: p.x < f.midX, top: p.y < f.midY)
        manager?.beginDrag(w)
    }

    func drag(to p: CGPoint) {
        switch mode {
        case .move(let w, let offset, let size):
            mover.move(w.element, to: CGRect(origin: CGPoint(x: p.x - offset.x, y: p.y - offset.y), size: size),
                       resize: false)
            if !w.floating, let target = manager?.dropTarget(for: w.id, at: p), let f = target.placed {
                highlight.show(f)
            } else {
                highlight.hide()
            }
        case .resize(let w, let s, let m, let left, let top):
            let dx = p.x - m.x, dy = p.y - m.y
            var f = s
            if left { f.origin.x += dx; f.size.width -= dx } else { f.size.width += dx }
            if top { f.origin.y += dy; f.size.height -= dy } else { f.size.height += dy }
            f.size.width = max(f.width, 220)
            f.size.height = max(f.height, 160)
            if w.floating {
                mover.move(w.element, to: f, resize: true)
            } else {
                let now = CACurrentMediaTime()
                guard now - lastResize > 1.0 / 30 else { return }   // les autres fenêtres suivent ~30 fois par seconde
                lastResize = now
                manager?.liveResize(w, to: f)
            }
        case .none:
            break
        }
    }

    func end(at p: CGPoint) {
        highlight.hide()
        let m = mode
        mode = .none
        switch m {
        case .move: manager?.endDrag(at: p)
        case .resize: manager?.endResize()
        case .none: break
        }
    }

    private func cancel() {
        highlight.hide()
        if case .none = mode { return }
        mode = .none
        manager?.endResize()
    }
}

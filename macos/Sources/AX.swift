import AppKit
import ApplicationServices

/// Identifiant système d'une fenêtre (fonction privée mais stable, utilisée par tous les gestionnaires de fenêtres).
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func askTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func windowID(_ e: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(e, &id) == .success && id != 0 ? id : nil
    }

    static func position(_ e: AXUIElement) -> CGPoint? {
        guard let v: AXValue = attr(e, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    static func size(_ e: AXUIElement) -> CGSize? {
        guard let v: AXValue = attr(e, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = position(e), let s = size(e) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setPosition(_ e: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v) }
    }

    static func setSize(_ e: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v) }
    }

    /// Place une fenêtre : position, taille, puis position à nouveau (macOS limite parfois la taille près des bords).
    static func setFrame(_ e: AXUIElement, _ f: CGRect) {
        setPosition(e, f.origin)
        setSize(e, f.size)
        setPosition(e, f.origin)
    }

    static func isSettable(_ e: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(e, name as CFString, &settable) == .success && settable.boolValue
    }

    static func bool(_ e: AXUIElement, _ name: String) -> Bool {
        (attr(e, name) as CFBoolean?).map { CFBooleanGetValue($0) } ?? false
    }

    static func raise(_ e: AXUIElement) {
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(e, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func setFrontmost(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        return attr(app, kAXWindowsAttribute) ?? []
    }

    static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        guard let app: AXUIElement = attr(system, kAXFocusedApplicationAttribute) else { return nil }
        return attr(app, kAXFocusedWindowAttribute)
    }

    static func pid(_ e: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        return pid
    }
}

/// Coordonnées : NSScreen (origine en bas à gauche) ↔ accessibilité (origine en haut à gauche).
enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Zone utilisable d'un écran (sans la barre des menus ni le Dock), en coordonnées d'accessibilité.
    static func area(_ s: NSScreen) -> CGRect { toAX(s.visibleFrame) }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { toAX($0.frame).contains(p) } ?? NSScreen.main
    }

    /// Coin où l'on range les fenêtres des autres pages : presque entièrement hors de l'écran (en bas à droite).
    static var hiddenCorner: CGPoint {
        let all = NSScreen.screens.map { toAX($0.frame) }.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: all.maxX - 1, y: all.maxY - 1)
    }
}

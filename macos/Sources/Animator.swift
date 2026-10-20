import ApplicationServices
import Foundation
import QuartzCore

/// Un déplacement de fenêtre à faire (éventuellement animé).
struct FrameMove {
    let pid: pid_t
    let element: AXUIElement
    let from: CGRect?
    let to: CGRect
}

/// Déplace les fenêtres hors du fil principal, toutes les applis en parallèle, avec une courbe douce.
final class Animator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.aikographic.aikoflow.animation", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    /// Lance les déplacements ; une nouvelle animation interrompt la précédente (on part de là où on en est).
    func run(_ moves: [FrameMove], duration: Double, completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        guard !moves.isEmpty else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        queue.async { [self] in
            let byApp = Dictionary(grouping: moves, by: \.pid)
            let groups = Array(byApp.values)
            let pids = Array(byApp.keys)
            // Les applis qui ont « l'interface améliorée » (utilisée par l'accessibilité) se redimensionnent
            // lentement : on la coupe le temps du déplacement, comme le font les gestionnaires de fenêtres connus
            let enhanced = pids.map { AX.disableEnhancedUI($0) }

            let animated = duration > 0.01 && moves.contains { $0.from != nil }
            if animated {
                let start = CACurrentMediaTime()
                var t = 0.0
                while t < 1 {
                    if self.current != gen { break }
                    let now = CACurrentMediaTime()
                    t = min(1, (now - start) / duration)
                    let e = 1 - pow(1 - t, 3)   // départ rapide, arrivée douce
                    DispatchQueue.concurrentPerform(iterations: groups.count) { i in
                        for m in groups[i] {
                            guard let from = m.from else { continue }
                            let f = Self.lerp(from, m.to, e)
                            if abs(from.width - m.to.width) > 1 || abs(from.height - m.to.height) > 1 {
                                AX.setSize(m.element, f.size)
                            }
                            AX.setPosition(m.element, f.origin)
                        }
                    }
                    if t >= 1 { break }
                    let spent = CACurrentMediaTime() - now
                    if spent < 1.0 / 90 { usleep(useconds_t((1.0 / 90 - spent) * 1_000_000)) }
                }
            }
            if self.current == gen {
                DispatchQueue.concurrentPerform(iterations: groups.count) { i in
                    for m in groups[i] { AX.setFrame(m.element, m.to) }
                }
            }
            for (pid, was) in zip(pids, enhanced) where was { AX.restoreEnhancedUI(pid) }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        let k = CGFloat(t)
        return CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
                      width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)
    }
}

import CoreGraphics

/// Repères : coordonnées « écran » de macOS côté accessibilité (origine en haut à gauche, y vers le bas).
enum Direction: String, CaseIterable {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
}

enum Axis {
    case horizontal   // côte à côte : premier à gauche, second à droite
    case vertical     // l'un sur l'autre : premier en haut, second en bas
}

/// Nœud de l'arbre « dwindle » (comme Hyprland) : une feuille = une fenêtre, sinon une séparation en deux.
final class LayoutNode {
    var window: UInt32?
    var axis: Axis = .horizontal
    var ratio: CGFloat = 0.5
    var first: LayoutNode?
    var second: LayoutNode?
    weak var parent: LayoutNode?

    init(window: UInt32) { self.window = window }
    init(axis: Axis, ratio: CGFloat, first: LayoutNode, second: LayoutNode) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
        first.parent = self
        second.parent = self
    }

    var isLeaf: Bool { window != nil }
}

struct Gaps: Equatable {
    var inner: CGFloat = 8
    var outer: CGFloat = 10
}

/// Pavage d'une page sur un écran.
final class Layout {
    private(set) var root: LayoutNode?

    var isEmpty: Bool { root == nil }

    var windows: [UInt32] {
        var out: [UInt32] = []
        func walk(_ n: LayoutNode?) {
            guard let n else { return }
            if let w = n.window { out.append(w); return }
            walk(n.first)
            walk(n.second)
        }
        walk(root)
        return out
    }

    func contains(_ w: UInt32) -> Bool { leaf(w) != nil }

    func leaf(_ w: UInt32) -> LayoutNode? {
        func find(_ n: LayoutNode?) -> LayoutNode? {
            guard let n else { return nil }
            if n.window == w { return n }
            return find(n.first) ?? find(n.second)
        }
        return find(root)
    }

    /// Ajoute une fenêtre en coupant en deux la fenêtre visée (ou la dernière), dans le sens de sa plus grande longueur.
    func insert(_ w: UInt32, near target: UInt32?, area: CGRect, gaps: Gaps) {
        guard !contains(w) else { return }
        let newLeaf = LayoutNode(window: w)
        guard let root else {
            self.root = newLeaf
            return
        }
        let host = target.flatMap { leaf($0) } ?? lastLeaf(root)
        let rect = rects(area: area, gaps: gaps)[ObjectIdentifier(host)] ?? area
        let axis: Axis = rect.width >= rect.height ? .horizontal : .vertical
        let parent = host.parent
        let split = LayoutNode(axis: axis, ratio: 0.5, first: host, second: newLeaf)
        if let parent {
            if parent.first === host { parent.first = split } else { parent.second = split }
            split.parent = parent
        } else {
            self.root = split
            split.parent = nil
        }
    }

    private func lastLeaf(_ n: LayoutNode) -> LayoutNode {
        var cur = n
        while !cur.isLeaf { cur = cur.second ?? cur.first! }
        return cur
    }

    func remove(_ w: UInt32) {
        guard let node = leaf(w) else { return }
        guard let parent = node.parent else {
            root = nil
            return
        }
        let sibling = parent.first === node ? parent.second! : parent.first!
        if let grand = parent.parent {
            if grand.first === parent { grand.first = sibling } else { grand.second = sibling }
            sibling.parent = grand
        } else {
            root = sibling
            sibling.parent = nil
        }
    }

    func swap(_ a: UInt32, _ b: UInt32) {
        guard let la = leaf(a), let lb = leaf(b) else { return }
        la.window = b
        lb.window = a
    }

    /// Change le sens de la séparation qui contient la fenêtre (côte à côte ↔ l'un sur l'autre).
    func toggleSplit(_ w: UInt32) {
        guard let p = leaf(w)?.parent else { return }
        p.axis = p.axis == .horizontal ? .vertical : .horizontal
    }

    /// Déplace la séparation la plus proche dans la direction donnée.
    func resize(_ w: UInt32, _ dir: Direction, step: CGFloat = 0.05) {
        guard let node = leaf(w) else { return }
        let wanted: Axis = dir.isHorizontal ? .horizontal : .vertical
        var cur: LayoutNode? = node.parent
        while let c = cur, c.axis != wanted { cur = c.parent }
        guard let split = cur else { return }
        let delta = (dir == .right || dir == .down) ? step : -step
        split.ratio = min(0.9, max(0.1, split.ratio + delta))
    }

    func balance() {
        func walk(_ n: LayoutNode?) {
            guard let n, !n.isLeaf else { return }
            n.ratio = 0.5
            walk(n.first)
            walk(n.second)
        }
        walk(root)
    }

    /// Après un redimensionnement à la souris : déduit la position des séparations à partir du nouveau cadre.
    func adopt(_ w: UInt32, newFrame f: CGRect, area: CGRect, gaps: Gaps) {
        guard let node = leaf(w) else { return }
        let all = rects(area: area, gaps: gaps)
        guard let old = all[ObjectIdentifier(node)] else { return }
        for axis in [Axis.horizontal, .vertical] {
            let changedMin = axis == .horizontal ? abs(f.minX - old.minX) > 2 : abs(f.minY - old.minY) > 2
            let changedMax = axis == .horizontal ? abs(f.maxX - old.maxX) > 2 : abs(f.maxY - old.maxY) > 2
            guard changedMin || changedMax else { continue }
            // Remonte jusqu'à la séparation de cet axe dont la frontière a bougé
            var child: LayoutNode = node
            var cur = node.parent
            while let split = cur {
                if split.axis == axis, let r = all[ObjectIdentifier(split)] {
                    let isFirst = split.first === child
                    if (isFirst && changedMax) || (!isFirst && changedMin) {
                        let length = axis == .horizontal ? r.width : r.height
                        let origin = axis == .horizontal ? r.minX : r.minY
                        let edge = isFirst ? (axis == .horizontal ? f.maxX : f.maxY) + gaps.inner / 2
                                           : (axis == .horizontal ? f.minX : f.minY) - gaps.inner / 2
                        if length > 0 { split.ratio = min(0.9, max(0.1, (edge - origin) / length)) }
                        break
                    }
                }
                child = split
                cur = split.parent
            }
        }
    }

    // MARK: - Calcul des cadres

    /// Rectangle de chaque nœud (feuilles et séparations).
    func rects(area: CGRect, gaps: Gaps) -> [ObjectIdentifier: CGRect] {
        var out: [ObjectIdentifier: CGRect] = [:]
        func walk(_ n: LayoutNode?, _ r: CGRect) {
            guard let n else { return }
            out[ObjectIdentifier(n)] = r
            guard !n.isLeaf, let a = n.first, let b = n.second else { return }
            if n.axis == .horizontal {
                let w = max(0, r.width - gaps.inner)
                let wa = (w * n.ratio).rounded()
                walk(a, CGRect(x: r.minX, y: r.minY, width: wa, height: r.height))
                walk(b, CGRect(x: r.minX + wa + gaps.inner, y: r.minY, width: w - wa, height: r.height))
            } else {
                let h = max(0, r.height - gaps.inner)
                let ha = (h * n.ratio).rounded()
                walk(a, CGRect(x: r.minX, y: r.minY, width: r.width, height: ha))
                walk(b, CGRect(x: r.minX, y: r.minY + ha + gaps.inner, width: r.width, height: h - ha))
            }
        }
        walk(root, area.insetBy(dx: gaps.outer, dy: gaps.outer))
        return out
    }

    func frames(area: CGRect, gaps: Gaps) -> [UInt32: CGRect] {
        let r = rects(area: area, gaps: gaps)
        var out: [UInt32: CGRect] = [:]
        func walk(_ n: LayoutNode?) {
            guard let n else { return }
            if let w = n.window, let f = r[ObjectIdentifier(n)] { out[w] = f; return }
            walk(n.first)
            walk(n.second)
        }
        walk(root)
        return out
    }
}

/// La fenêtre voisine dans une direction, d'après les cadres (fonctionne aussi d'un écran à l'autre).
func neighbor(of w: UInt32, _ dir: Direction, in frames: [UInt32: CGRect]) -> UInt32? {
    guard let f = frames[w] else { return nil }
    var best: (id: UInt32, score: CGFloat)?
    for (id, o) in frames where id != w {
        let gap: CGFloat
        let overlap: CGFloat
        switch dir {
        case .left: gap = f.minX - o.maxX; overlap = min(f.maxY, o.maxY) - max(f.minY, o.minY)
        case .right: gap = o.minX - f.maxX; overlap = min(f.maxY, o.maxY) - max(f.minY, o.minY)
        case .up: gap = f.minY - o.maxY; overlap = min(f.maxX, o.maxX) - max(f.minX, o.minX)
        case .down: gap = o.minY - f.maxY; overlap = min(f.maxX, o.maxX) - max(f.minX, o.minX)
        }
        guard gap > -4, overlap > 0 else { continue }
        // Le plus proche d'abord, puis celui qui se chevauche le plus
        let score = gap * 10 - overlap / 1000
        if best == nil || score < best!.score { best = (id, score) }
    }
    return best?.id
}

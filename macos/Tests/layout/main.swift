import CoreGraphics
import Foundation

// Tests du pavage (comme Hyprland « dwindle ») : sans écran, sans autorisation.

var failures: [String] = []
let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok {
        failures.append(what)
        if ci { print("::error title=Pavage::\(what)") }
    }
}
func show(_ f: [UInt32: CGRect]) -> String {
    f.keys.sorted().map { k in let r = f[k]!; return "\(k): \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }
        .joined(separator: " | ")
}

let area = CGRect(x: 0, y: 25, width: 1440, height: 875)   // écran 1440×900 sous la barre des menus
let gaps = Gaps(inner: 8, outer: 10)
let inside = area.insetBy(dx: 10, dy: 10)
let l = Layout()

print("== Ajout de fenêtres")
l.insert(1, near: nil, area: area, gaps: gaps)
var f = l.frames(area: area, gaps: gaps)
check(f[1] == inside, "1 fenêtre : tout l'écran moins la marge → \(show(f))")

l.insert(2, near: 1, area: area, gaps: gaps)
f = l.frames(area: area, gaps: gaps)
print("   " + show(f))
check(f[1]!.width == f[2]!.width && f[1]!.height == inside.height && f[2]!.minX == f[1]!.maxX + 8,
      "2 fenêtres côte à côte, même largeur, 8 px entre elles")

l.insert(3, near: 2, area: area, gaps: gaps)
f = l.frames(area: area, gaps: gaps)
print("   " + show(f))
check(f[2]!.minX == f[3]!.minX && f[3]!.minY == f[2]!.maxY + 8 && f[1]!.height == inside.height,
      "3e fenêtre : la moitié droite se coupe en haut / bas (dwindle)")

l.insert(4, near: 3, area: area, gaps: gaps)
f = l.frames(area: area, gaps: gaps)
print("   " + show(f))
check(f[4]!.minY == f[3]!.minY && f[4]!.minX == f[3]!.maxX + 8, "4e : le bas droit se coupe en gauche / droite")

func noOverlap(_ f: [UInt32: CGRect]) -> Bool {
    let v = Array(f.values)
    for i in v.indices { for j in v.indices where i < j && v[i].intersects(v[j]) { return false } }
    return v.allSatisfy { inside.contains($0) }
}
check(noOverlap(f), "aucun chevauchement, tout reste dans l'écran")
let covered = f.values.reduce(0) { $0 + $1.width * $1.height }
check(covered / (inside.width * inside.height) > 0.97, "l'écran est bien rempli (\(Int(covered * 100 / (inside.width * inside.height))) %)")

print("== Voisins")
check(neighbor(of: 1, .right, in: f) == 2, "à droite de 1 → 2")
check(neighbor(of: 2, .down, in: f) == 3 || neighbor(of: 2, .down, in: f) == 4, "sous 2 → 3 ou 4")
check(neighbor(of: 4, .left, in: f) == 3, "à gauche de 4 → 3")
check(neighbor(of: 3, .left, in: f) == 1, "à gauche de 3 → 1")
check(neighbor(of: 1, .left, in: f) == nil, "rien à gauche de 1")

print("== Modifications")
l.swap(1, 4)
f = l.frames(area: area, gaps: gaps)
check(f[4]!.minX == inside.minX && f[4]!.height == inside.height, "échange 1 ↔ 4")
l.swap(1, 4)

let before = l.frames(area: area, gaps: gaps)[1]!.width
l.resize(1, .right)
let after = l.frames(area: area, gaps: gaps)[1]!.width
check(after > before + 50, "agrandir vers la droite (\(Int(before)) → \(Int(after)))")
l.balance()
check(l.frames(area: area, gaps: gaps)[1]!.width == before, "rééquilibrer")

l.toggleSplit(3)
f = l.frames(area: area, gaps: gaps)
check(f[3]!.minY == f[4]!.minY - 0 || f[3]!.minX == f[4]!.minX, "changer le sens du partage")
l.toggleSplit(3)

// Redimensionnement à la souris : la fenêtre 1 tirée de 100 px vers la droite
let f1 = l.frames(area: area, gaps: gaps)[1]!
l.adopt(1, newFrame: CGRect(x: f1.minX, y: f1.minY, width: f1.width + 100, height: f1.height), area: area, gaps: gaps)
let g1 = l.frames(area: area, gaps: gaps)[1]!
check(abs(g1.width - (f1.width + 100)) <= 2, "redimensionnement à la souris adopté (\(Int(f1.width)) → \(Int(g1.width)))")
check(noOverlap(l.frames(area: area, gaps: gaps)), "toujours aucun chevauchement")
l.balance()

print("== Fermeture")
l.remove(2)
f = l.frames(area: area, gaps: gaps)
print("   " + show(f))
check(f.count == 3 && noOverlap(f) && f[1]!.width == before, "fermer 2 : 3 et 4 prennent sa place")
l.remove(1)
l.remove(3)
f = l.frames(area: area, gaps: gaps)
check(f[4] == inside, "dernière fenêtre : plein écran")
l.remove(4)
check(l.isEmpty, "page vide")

print("== Écran vertical")
let tall = CGRect(x: 0, y: 0, width: 1080, height: 1920)
let v = Layout()
v.insert(1, near: nil, area: tall, gaps: gaps)
v.insert(2, near: 1, area: tall, gaps: gaps)
let vf = v.frames(area: tall, gaps: gaps)
check(vf[1]!.minX == vf[2]!.minX && vf[2]!.minY > vf[1]!.maxY, "écran vertical : l'une sur l'autre")

if failures.isEmpty { print("\nTout est OK"); exit(0) }
print("\nÉCHECS :\n" + failures.joined(separator: "\n"))
exit(1)

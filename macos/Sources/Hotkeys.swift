import AppKit
import Carbon.HIToolbox

/// Plusieurs raccourcis globaux (API Carbon : aucune autorisation nécessaire).
final class HotKeyCenter {
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    /// Raccourcis refusés par macOS (déjà pris par une autre appli).
    private(set) var conflicts: [String] = []

    init() {
        guard !Self.installed else { return }
        Self.installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeyCenter.actions[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ keyCode: Int, _ modifiers: UInt32, label: String, _ action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: OSType(0x414B_464C), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            Self.actions[id] = action
        } else {
            conflicts.append(label)
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        Self.actions.removeAll()
        conflicts.removeAll()
    }
}

/// Touche de base des raccourcis.
enum ModKey: String, CaseIterable {
    case controlOption, option

    var carbon: UInt32 {
        switch self {
        case .controlOption: return UInt32(controlKey | optionKey)
        case .option: return UInt32(optionKey)
        }
    }

    var symbol: String {
        switch self {
        case .controlOption: return "⌃ ⌥"
        case .option: return "⌥"
        }
    }
}

/// La liste des raccourcis, partagée par l'enregistrement et l'aide.
struct KeyHelp {
    let keys: String          // ex. « 1 … 9 »
    let extra: String         // modificateurs en plus de la touche de base (« ⇧ », « ⌘ »…)
    let label: String
}

enum Keys {
    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
                         kVK_ANSI_8, kVK_ANSI_9]
    static let arrows: [(Int, Direction)] = [(kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_UpArrow, .up),
                                             (kVK_DownArrow, .down)]

    static let help: [KeyHelp] = [
        KeyHelp(keys: "1 … 9", extra: "", label: "Aller à la page"),
        KeyHelp(keys: "1 … 9", extra: "⇧", label: "Envoyer la fenêtre sur la page"),
        KeyHelp(keys: "← ↑ → ↓", extra: "", label: "Passer à la fenêtre voisine"),
        KeyHelp(keys: "← ↑ → ↓", extra: "⇧", label: "Déplacer la fenêtre"),
        KeyHelp(keys: "← ↑ → ↓", extra: "⌘", label: "Agrandir / réduire"),
        KeyHelp(keys: "⇥", extra: "", label: "Vue d'ensemble des pages"),
        KeyHelp(keys: "F", extra: "", label: "Plein écran (dans AikoFlow)"),
        KeyHelp(keys: "T", extra: "", label: "Fenêtre flottante / rangée"),
        KeyHelp(keys: "S", extra: "", label: "Côte à côte ↔ l'une sur l'autre"),
        KeyHelp(keys: "R", extra: "", label: "Rééquilibrer les tailles"),
        KeyHelp(keys: "P", extra: "", label: "Activer / couper AikoFlow"),
    ]
}

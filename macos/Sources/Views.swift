import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Aide : les raccourcis

struct HelpView: View {
    @ObservedObject var settings: FlowSettings
    var conflicts: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 26)).foregroundStyle(Theme.accentText(scheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AikoFlow").font(.system(size: 20, weight: .semibold))
                    Text("Tes fenêtres se rangent toutes seules, sur 9 pages").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(Keys.help.enumerated()), id: \.offset) { i, k in
                    HStack {
                        Text(k.label).font(.system(size: 13))
                        Spacer()
                        Text([settings.modKey.symbol, k.extra, k.keys].filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.system(size: 12, weight: .semibold).monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface(scheme)))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line(scheme)))
                    }
                    .padding(.vertical, 7)
                    if i < Keys.help.count - 1 { Rectangle().fill(Theme.line(scheme)).frame(height: 1) }
                }
            }
            if !conflicts.isEmpty {
                Text("Déjà pris par une autre appli : " + conflicts.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text("Tes bureaux macOS (Mission Control) ne sont pas touchés : les pages AikoFlow vivent dans le bureau actuel.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.background(scheme))
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @ObservedObject var settings: FlowSettings
    var onChanged: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Touche de base") {
                    Picker("", selection: Binding(get: { settings.modKey }, set: { settings.modKey = $0; onChanged() })) {
                        Text("⌃ ⌥  Contrôle + Option (conseillé)").tag(ModKey.controlOption)
                        Text("⌥  Option seule").tag(ModKey.option)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    Text("Avec ⌥ seule, tu perds { [ | ~ au clavier français et ⌥ ← → pour sauter de mot en mot.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                section("Espacements") {
                    slider("Entre les fenêtres", $settings.innerGap)
                    slider("Autour de l'écran", $settings.outerGap)
                    Toggle("Bordure bleue autour de la fenêtre active",
                           isOn: Binding(get: { settings.showBorder }, set: { settings.showBorder = $0; onChanged() }))
                        .toggleStyle(.switch).tint(Theme.accentUI)
                }
                appList("Toujours flottantes", "Elles gardent leur taille et leur place.", $settings.floating)
                appList("Ignorées", "AikoFlow ne touche jamais à leurs fenêtres.", $settings.ignored)
                section("Général") {
                    Toggle("Activer AikoFlow à l'ouverture", isOn: $settings.enableAtLaunch)
                        .toggleStyle(.switch).tint(Theme.accentUI)
                    Toggle("Ouvrir au démarrage du Mac",
                           isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).tint(Theme.accentUI)
                }
            }
            .padding(22)
        }
        .frame(width: 440, height: 600)
        .background(Theme.background(scheme))
    }

    private func slider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).frame(width: 150, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded(); onChanged() }),
                   in: 0...40)
                .tint(Theme.accentUI)
            Text("\(Int(value.wrappedValue)) px").font(.system(size: 12).monospacedDigit()).frame(width: 44)
        }
    }

    private func appList(_ title: String, _ detail: String, _ list: Binding<[AppRef]>) -> some View {
        section(title) {
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(list.wrappedValue) { app in
                HStack {
                    appIcon(app.bundleID)
                    Text(app.name).font(.system(size: 13))
                    Spacer()
                    Button { list.wrappedValue.removeAll { $0 == app }; onChanged() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            Button("Ajouter une app…") { add(to: list) }
        }
    }

    private func add(to list: Binding<[AppRef]>) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier,
                  !list.wrappedValue.contains(where: { $0.bundleID == id }) else { continue }
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            list.wrappedValue.append(AppRef(bundleID: id, name: name))
        }
        onChanged()
    }

    private func appIcon(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let img = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        return Image(nsImage: img).resizable().frame(width: 18, height: 18)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line(scheme)))
        }
    }
}

// MARK: - Autorisation « Accessibilité »

struct PermissionView: View {
    var onOpen: () -> Void
    var onRelaunch: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 28)).foregroundStyle(Theme.accentText(scheme))
                Text("Une autorisation, et c'est prêt").font(.system(size: 18, weight: .semibold))
            }
            Text("Pour ranger tes fenêtres, AikoFlow doit pouvoir les déplacer. macOS appelle ça « Accessibilité ».")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Clique sur « Ouvrir les réglages ».")
                step(2, "Active AikoFlow dans Confidentialité et sécurité → Accessibilité.")
                step(3, "Reviens ici et clique sur « Relancer AikoFlow ».")
            }
            HStack {
                Button("Ouvrir les réglages") { onOpen() }
                Spacer()
                Button("Relancer AikoFlow") { onRelaunch() }.keyboardShortcut(.defaultAction).tint(Theme.accentUI)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background(scheme))
    }

    private func step(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 20, height: 20).background(Circle().fill(Theme.accentUI))
            Text(s).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

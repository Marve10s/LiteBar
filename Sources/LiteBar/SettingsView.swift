import ServiceManagement
import SwiftUI

struct SettingsPage: View {
    @ObservedObject var store: Store
    @AppStorage("refreshInterval") private var refreshInterval = RefreshInterval.fiveMinutes.rawValue
    @AppStorage("menuBarShowsPercent") private var menuBarShowsPercent = true
    @AppStorage(MenuBarSource.key) private var menuBarSource = MenuBarSource.tightest.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            PageScroll {
                VStack(spacing: 8) {
                    SettingsCard(title: "CLIs", footer: nil) {
                        ForEach(Array(Provider.allCases.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 { Divider().opacity(0.6) }
                            SwitchRow(isOn: Binding(
                                get: { store.enabledProviders.contains(provider) },
                                set: { store.setEnabled(provider, $0) }
                            )) {
                                HStack(spacing: 8) {
                                    BrandBadge(provider: provider, size: 18)
                                    Text(provider.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                        }
                    }

                    if store.enabledProviders.contains(.claude) {
                        ClaudeUsageSettings(store: store)
                    }

                    ForEach(store.enabledProviders) { provider in
                        LimitPreferencesCard(store: store, provider: provider)
                    }

                    SettingsCard(title: "Menu bar", footer: nil) {
                        SettingRow(label: "Refresh") {
                            PillPicker(
                                options: RefreshInterval.allCases.map { (String($0.rawValue), $0.label) },
                                selection: Binding(
                                    get: { String(refreshInterval) },
                                    set: { refreshInterval = Int($0) ?? RefreshInterval.fiveMinutes.rawValue; store.applyIntervalChange() }
                                )
                            )
                        }
                        Divider().opacity(0.6)
                        SettingRow(label: "Gauge tracks") {
                            PillPicker(
                                options: [(MenuBarSource.tightest.rawValue, MenuBarSource.tightest.label)]
                                    + Provider.allCases.map { (MenuBarSource.provider($0).rawValue, $0.displayName) },
                                selection: Binding(
                                    get: { menuBarSource },
                                    set: { menuBarSource = $0; store.updateMenuBar() }
                                )
                            )
                        }
                        Divider().opacity(0.6)
                        SwitchRow(isOn: $menuBarShowsPercent) {
                            Text("Show percentage next to the icon")
                                .font(.system(size: 12))
                        }
                    }

                    SettingsCard(title: "System", footer: nil) {
                        SwitchRow(isOn: $launchAtLogin) {
                            Text("Launch at login")
                                .font(.system(size: 12))
                        }
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    }

                    SettingsCard(title: "About", footer: "LiteBar reads usage from provider APIs or Claude Code captures. There is no embedded browser or telemetry.") {
                        HStack(spacing: 8) {
                            Image(nsImage: AppIconArtwork.headerImage(size: 22))
                                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                            Text("LiteBar")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BackButton(store: store)
            SectionIcon(symbol: "gearshape.fill", tint: .gray)
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

struct SettingRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            control()
        }
    }
}

struct SwitchRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack {
            label()
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .pointerCursor()
        }
    }
}

struct LimitPreferencesCard: View {
    @ObservedObject var store: Store
    let provider: Provider
    @State private var expanded = false

    private var titles: [String] {
        var seen: [String] = []
        for window in store.snapshot(for: provider)?.windows ?? [] where !seen.contains(window.displayTitle) {
            seen.append(window.displayTitle)
        }
        return seen
    }

    private var summary: String {
        let shown = titles.filter { store.windowPreferences.isVisible($0, for: provider) }.count
        let headline = store.windowPreferences.headline(for: provider)
        let headlineText = headline == WindowPreferences.tightest ? "tightest" : headline
        return titles.isEmpty ? "" : "\(shown) of \(titles.count) shown · \(headlineText)"
    }

    var body: some View {
        DisclosureRow(isExpanded: $expanded) {
            BrandBadge(provider: provider, size: 18)
            Text("\(provider.displayName) limits")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if titles.isEmpty {
                    Text("Limits appear here after the first successful refresh.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    SettingRow(label: "Overview shows") {
                        PillPicker(
                            options: [(WindowPreferences.tightest, "Tightest limit")] + titles.map { ($0, $0) },
                            selection: Binding(
                                get: { store.windowPreferences.headline(for: provider) },
                                set: { store.setHeadlineWindow($0, for: provider) }
                            )
                        )
                    }
                    Divider().opacity(0.6)
                    ForEach(titles, id: \.self) { title in
                        SwitchRow(isOn: Binding(
                            get: { store.windowPreferences.isVisible(title, for: provider) },
                            set: { store.setWindowVisible($0, title, for: provider) }
                        )) {
                            Text(title)
                                .font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(CardBackground())
    }
}

struct PillPicker: View {
    let options: [(tag: String, label: String)]
    @Binding var selection: String
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(options, id: \.tag) { option in
                Button {
                    selection = option.tag
                } label: {
                    if option.tag == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.tag == selection }?.label ?? selection)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(width: 176, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.12 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

struct ClaudeUsageSettings: View {
    @ObservedObject var store: Store
    @AppStorage(ClaudeUsageMode.key) private var mode = ClaudeUsageMode.live.rawValue

    var body: some View {
        SettingsCard(title: "Claude usage", footer: mode == ClaudeUsageMode.local.rawValue
                     ? "Reads the last captured limits, including while offline. No Claude network requests. Capture runs only on Claude Code status-line updates."
                     : "Fetches current limits even when Claude Code is closed. A separate sign-in renews automatically; no helper stays running.") {
            SettingRow(label: "Source") {
                PillPicker(options: ClaudeUsageMode.allCases.map { ($0.rawValue, $0.label) },
                           selection: Binding(get: { mode }, set: {
                    guard let selected = ClaudeUsageMode(rawValue: $0) else { return }
                    mode = $0
                    store.setClaudeMode(selected)
                }))
            }
            if mode == ClaudeUsageMode.local.rawValue {
                Button("Enable capture in Claude Code") { store.installClaudeCapture() }
                    .controlSize(.small)
                if let message = store.claudeSetupMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(store.claudeAuthorization == nil ? "Connect Claude…" : "Start a new sign-in…") {
                    do {
                        let request = try ClaudeOAuth.Authorization()
                        store.claudeAuthorization = request
                        store.claudeAuthorizationCode = ""
                        store.claudeConnectionMessage = nil
                        guard NSWorkspace.shared.open(request.url) else {
                            throw AppError("Could not open your browser for Claude sign-in.")
                        }
                    } catch { store.claudeConnectionMessage = error.localizedDescription }
                }
                .controlSize(.small)
                .disabled(store.claudeConnecting)
                if let authorization = store.claudeAuthorization {
                    Text("Approve profile access in your browser, then paste the complete authorization code. Claude may label its authorization client as Claude Code.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Authorization code", text: $store.claudeAuthorizationCode)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Finish connection") {
                            store.claudeConnecting = true
                            store.claudeConnectionMessage = nil
                            let pasted = store.claudeAuthorizationCode
                            store.claudeAuthorizationCode = ""
                            Task {
                                do {
                                    try await ClaudeOAuth.session.connect(authorization, code: pasted)
                                    store.claudeAuthorization = nil
                                    store.claudeConnectionMessage = "Connected. Live limits renew automatically."
                                    await store.refresh(.claude)
                                } catch { store.claudeConnectionMessage = error.localizedDescription }
                                store.claudeConnecting = false
                            }
                        }
                        .disabled(store.claudeAuthorizationCode.isEmpty || store.claudeConnecting)
                        Button("Cancel") { store.claudeAuthorization = nil; store.claudeAuthorizationCode = "" }
                            .disabled(store.claudeConnecting)
                        if store.claudeConnecting { ProgressView().controlSize(.mini) }
                    }
                    .controlSize(.small)
                }
                if let message = store.claudeConnectionMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

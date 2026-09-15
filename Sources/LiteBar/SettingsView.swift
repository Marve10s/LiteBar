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
                    SettingsCard(title: "CLIs") {
                        ForEach(Array(Provider.allCases.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 { RowDivider() }
                            SwitchRow(isOn: Binding(
                                get: { store.enabledProviders.contains(provider) },
                                set: { store.setEnabled(provider, $0) }
                            )) {
                                BrandBadge(provider: provider, size: 18)
                                Text(provider.displayName)
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                    }

                    if store.enabledProviders.contains(.claude) {
                        ClaudeUsageSettings(store: store)
                    }

                    SettingsCard(title: "General") {
                        SwitchRow(isOn: $launchAtLogin) {
                            RowIcon(symbol: "power")
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
                        RowDivider()
                        SettingRow(symbol: "arrow.clockwise", label: "Refresh") {
                            PillPicker(
                                options: RefreshInterval.allCases.map { (String($0.rawValue), $0.label) },
                                selection: Binding(
                                    get: { String(refreshInterval) },
                                    set: { refreshInterval = Int($0) ?? RefreshInterval.fiveMinutes.rawValue; store.applyIntervalChange() }
                                )
                            )
                        }
                        RowDivider()
                        SettingRow(symbol: "gauge.with.needle", label: "Menu bar gauge") {
                            PillPicker(
                                options: [(MenuBarSource.tightest.rawValue, MenuBarSource.tightest.label)]
                                    + Provider.allCases.map { (MenuBarSource.provider($0).rawValue, $0.displayName) },
                                selection: Binding(
                                    get: { menuBarSource },
                                    set: { menuBarSource = $0; store.updateMenuBar() }
                                )
                            )
                        }
                        RowDivider()
                        SwitchRow(isOn: $menuBarShowsPercent) {
                            RowIcon(symbol: "percent")
                            Text("Percentage in menu bar")
                                .font(.system(size: 12))
                        }
                    }

                    HStack(spacing: 8) {
                        Image(nsImage: AppIconArtwork.headerImage(size: 18))
                            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                        Text("LiteBar")
                            .font(.system(size: 12, weight: .medium))
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
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
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            content()
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().opacity(0.6)
    }
}

struct RowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
    }
}

struct SettingRow<Control: View>: View {
    var symbol: String? = nil
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { RowIcon(symbol: symbol) }
            Text(label)
                .font(.system(size: 12))
            Spacer()
            control()
        }
        .frame(minHeight: 22)
    }
}

struct SwitchRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(spacing: 8) {
            label()
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .pointerCursor()
        }
        .frame(minHeight: 22)
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
            HStack(spacing: 5) {
                Text(options.first { $0.tag == selection }?.label ?? selection)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
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

    private var isLocal: Bool { mode == ClaudeUsageMode.local.rawValue }

    var body: some View {
        SettingsCard(title: "Claude Code", footer: isLocal
                     ? "Reads limits that Claude Code writes on each status-line update. Works offline."
                     : "Signs in once and renews automatically, even while Claude Code is closed.") {
            SettingRow(symbol: "antenna.radiowaves.left.and.right", label: "Source") {
                PillPicker(options: ClaudeUsageMode.allCases.map { ($0.rawValue, $0.label) },
                           selection: Binding(get: { mode }, set: {
                    guard let selected = ClaudeUsageMode(rawValue: $0) else { return }
                    mode = $0
                    store.setClaudeMode(selected)
                }))
            }
            RowDivider()
            if isLocal {
                SettingRow(symbol: "terminal", label: "Capture") {
                    Button("Enable in Claude Code") { store.installClaudeCapture() }
                        .controlSize(.small)
                }
                if let message = store.claudeSetupMessage {
                    StatusLine(text: message)
                }
            } else {
                SettingRow(symbol: "person.crop.circle", label: "Sign-in") {
                    Button(store.claudeAuthorization == nil ? "Connect…" : "Restart…") { startSignIn() }
                        .controlSize(.small)
                        .disabled(store.claudeConnecting)
                }
                if let authorization = store.claudeAuthorization {
                    authorizationForm(authorization)
                }
                if let message = store.claudeConnectionMessage {
                    StatusLine(text: message)
                }
            }
        }
    }

    private func startSignIn() {
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

    private func authorizationForm(_ authorization: ClaudeOAuth.Authorization) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approve in the browser, then paste the code here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                SecureField("Authorization code", text: $store.claudeAuthorizationCode)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("Finish") { finishSignIn(authorization) }
                    .controlSize(.small)
                    .disabled(store.claudeAuthorizationCode.isEmpty || store.claudeConnecting)
                Button("Cancel") { store.claudeAuthorization = nil; store.claudeAuthorizationCode = "" }
                    .controlSize(.small)
                    .disabled(store.claudeConnecting)
                if store.claudeConnecting { ProgressView().controlSize(.mini) }
            }
        }
        .padding(.top, 2)
    }

    private func finishSignIn(_ authorization: ClaudeOAuth.Authorization) {
        store.claudeConnecting = true
        store.claudeConnectionMessage = nil
        let pasted = store.claudeAuthorizationCode
        store.claudeAuthorizationCode = ""
        Task {
            do {
                try await ClaudeOAuth.session.connect(authorization, code: pasted)
                store.claudeAuthorization = nil
                store.claudeConnectionMessage = "Connected."
                await store.refresh(.claude)
            } catch { store.claudeConnectionMessage = error.localizedDescription }
            store.claudeConnecting = false
        }
    }
}

struct StatusLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

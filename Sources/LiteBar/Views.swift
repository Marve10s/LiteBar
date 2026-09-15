import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            switch store.page {
            case .overview:
                OverviewPage(store: store)
            case let .provider(provider):
                ProviderPage(store: store, provider: provider)
            case .settings:
                SettingsPage(store: store)
            }
            if store.page != .settings, let notice = store.connectionNotice {
                NoteCard(symbol: "wifi.exclamationmark", text: notice)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            PopoverFooter(store: store)
                .padding(.top, 10)
        }
        .frame(width: 336)
        .onAppear { store.setPopoverVisible(true) }
        .onDisappear { store.setPopoverVisible(false) }
        .task { await refreshIfStale() }
    }

    private func refreshIfStale() async {
        if let last = store.lastRefresh, Date().timeIntervalSince(last) < 60 { return }
        await store.refreshAll()
    }

    static func ago(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(seconds / 60)m ago"
        case ..<86_400: "\(seconds / 3600)h ago"
        default: "over a day ago"
        }
    }
}

struct PageScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            content()
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct OverviewPage: View {
    @ObservedObject var store: Store

    var body: some View {
        PageScroll {
        VStack(spacing: 8) {
            if store.enabledProviders.isEmpty {
                NoteCard(symbol: "slider.horizontal.3", text: "No CLIs enabled. Turn some on in Settings.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.enabledProviders.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 {
                            Divider().padding(.leading, 44).opacity(0.6)
                        }
                        if let snapshot = store.snapshot(for: provider) {
                            OverviewRow(snapshot: snapshot, window: store.windowPreferences.headlineWindow(of: snapshot), now: store.clock, isRefreshing: store.refreshing.contains(provider) && store.connectivity == .available) {
                                withAnimation(.snappy(duration: 0.2)) { store.page = .provider(provider) }
                            }
                        } else {
                            PendingRow(provider: provider, isRefreshing: store.refreshing.contains(provider) && store.connectivity == .available)
                        }
                    }
                }
                .background(CardBackground())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        }
    }
}

struct OverviewRow: View {
    let snapshot: ProviderSnapshot
    let window: RateWindow?
    let now: Date
    let isRefreshing: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                BrandBadge(provider: snapshot.provider, size: 26)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(snapshot.provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        if let badge = snapshot.badge, !badge.isEmpty {
                            PlanPill(text: badge)
                        }
                        Spacer(minLength: 6)
                        if let window {
                            Text(resetSummary(window))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                    }
                    if let window {
                        HStack(spacing: 10) {
                            UsageBar(leftPercent: window.leftPercent)
                                .frame(height: 5)
                            PercentLabel(leftPercent: window.leftPercent, compact: true)
                        }
                    } else if let error = snapshot.error {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if !snapshot.windows.isEmpty {
                        Text("All limits hidden")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if snapshot.isLocalCapture {
                        Text("Captured \(PopoverView.ago(from: snapshot.fetchedAt, now: now)) · may be out of date")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    .padding(3)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }

    private func resetSummary(_ window: RateWindow) -> String {
        guard let reset = window.resetsAt else { return window.displayTitle }
        if reset <= now { return "\(window.displayTitle) · resetting…" }
        return "\(window.displayTitle) · \(WindowRow.format(reset, now: now))"
    }
}

struct PendingRow: View {
    let provider: Provider
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 10) {
            BrandBadge(provider: provider, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(isRefreshing ? "Fetching…" : "Not loaded yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isRefreshing {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct ProviderPage: View {
    @ObservedObject var store: Store
    let provider: Provider

    private var snapshot: ProviderSnapshot? { store.snapshot(for: provider) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            PageScroll {
            VStack(spacing: 8) {
                if let snapshot {
                    if snapshot.windows.isEmpty, let error = snapshot.error {
                        ErrorRow(message: error)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CardBackground())
                    } else {
                        LimitsCard(snapshot: snapshot, windows: store.windowPreferences.visibleWindows(of: snapshot), now: store.clock)
                        if snapshot.isLocalCapture {
                            NoteCard(symbol: "clock", text: "Last changed capture: \(PopoverView.ago(from: snapshot.fetchedAt, now: store.clock)). These figures update while you use Claude Code and may be out of date.")
                        }
                        if provider == .codex {
                            CreditsCard(store: store, availableCount: snapshot.creditsAvailable)
                        }
                    }
                } else {
                    if store.connectivity == .available, !store.connectionFailures.contains(provider) {
                        NoteCard(symbol: nil, text: "Fetching \(provider.displayName) usage…")
                    } else {
                        NoteCard(symbol: "clock", text: "No usage loaded yet.")
                    }
                }
                if provider == .opencode {
                    ModelCatalogCard(store: store)
                }
                if provider.localUsageDescription != nil {
                    LocalUsageCard(store: store, provider: provider)
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
            BrandBadge(provider: provider, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let badge = snapshot?.badge, !badge.isEmpty {
                        PlanPill(text: badge)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let snapshot, !snapshot.windows.isEmpty {
                LimitsMenu(store: store, provider: provider, snapshot: snapshot)
            }
            if store.refreshing.contains(provider), store.connectivity == .available {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                IconButton(symbol: "arrow.clockwise", help: "Refresh \(provider.displayName)") {
                    Task { await store.refresh(provider) }
                }
            }
        }
    }

    private var subtitle: String {
        if let account = snapshot?.accountLine, !account.isEmpty { return account }
        guard let fetched = snapshot?.fetchedAt else { return "Not fetched yet" }
        return "Updated \(PopoverView.ago(from: fetched, now: store.clock))"
    }
}

struct LimitsCard: View {
    let snapshot: ProviderSnapshot
    let windows: [RateWindow]
    let now: Date
    @State private var extrasExpanded = false
    @State private var extrasReady = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                WindowRow(title: window.displayTitle, window: window, now: now)
            }
            if windows.isEmpty {
                Text("All limits hidden. Use the filter above to show them.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !snapshot.extras.isEmpty {
                Divider().opacity(0.6)
                DisclosureRow(isExpanded: Binding(
                    get: { extrasExpanded },
                    set: { expanded in
                        extrasExpanded = expanded
                        extrasReady = false
                        guard expanded else { return }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            extrasReady = true
                        }
                    }
                )) {
                    Text("\(snapshot.extras.count) \((snapshot.extrasTitle ?? "extras").lowercased())")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } content: {
                    if extrasReady {
                        VStack(spacing: 7) {
                            ForEach(Array(snapshot.extras.enumerated()), id: \.offset) { _, window in
                                CompactWindowRow(title: window.displayTitle, window: window)
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading \((snapshot.extrasTitle ?? "extras").lowercased())…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

struct PopoverFooter: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                HoverButton(help: "Quit LiteBar (⌘Q)") {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit LiteBar", systemImage: "power")
                        .font(.system(size: 12))
                }
                .keyboardShortcut("q", modifiers: .command)
                Spacer()
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: refreshHelp) {
                        Task { await store.refreshAll() }
                    }
                }
                IconButton(symbol: "gearshape", help: "Settings") {
                    store.page = store.page == .settings ? .overview : .settings
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
        }
    }

    private var refreshHelp: String {
        guard let last = store.lastRefresh else { return "Refresh all" }
        return "Refresh all · updated \(PopoverView.ago(from: last, now: store.clock))"
    }
}

extension View {
    func pointerCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct BackButton: View {
    @ObservedObject var store: Store

    var body: some View {
        HoverButton(help: "Back to all CLIs") {
            store.page = .overview
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("All")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }
}

struct HoverButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help(help)
    }
}

struct LimitsMenu: View {
    @ObservedObject var store: Store
    let provider: Provider
    let snapshot: ProviderSnapshot
    @State private var hovering = false

    private var titles: [String] {
        var seen: [String] = []
        for window in snapshot.windows where !seen.contains(window.displayTitle) {
            seen.append(window.displayTitle)
        }
        return seen
    }

    var body: some View {
        Menu {
            Picker("Overview shows", selection: Binding(
                get: { store.windowPreferences.headline(for: provider) },
                set: { store.setHeadlineWindow($0, for: provider) }
            )) {
                Text("Tightest limit").tag(WindowPreferences.tightest)
                ForEach(titles, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            Section("Visible limits") {
                ForEach(titles, id: \.self) { title in
                    Toggle(title, isOn: Binding(
                        get: { store.windowPreferences.isVisible(title, for: provider) },
                        set: { store.setWindowVisible($0, title, for: provider) }
                    ))
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
        .help("Choose which limits to show")
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

struct NoteCard: View {
    let symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(CardBackground())
    }
}

struct PlanPill: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            )
            .fixedSize()
    }
}

struct BrandBadge: View {
    let provider: Provider
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let icon = BrandIcon.providerIcon(provider, size: size * 0.8) {
                Image(nsImage: icon)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ErrorRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WindowRow: View {
    let title: String
    let window: RateWindow
    let now: Date

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(Self.resetText(for: window, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                UsageBar(leftPercent: window.leftPercent)
                    .frame(height: 6)
                PercentLabel(leftPercent: window.leftPercent)
            }
        }
    }

    static func resetText(for window: RateWindow, now: Date) -> String {
        guard let reset = window.resetsAt else { return "" }
        if reset <= now { return "resetting…" }
        return "resets in \(format(reset, now: now))"
    }

    static func format(_ date: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: now, to: date) ?? ""
    }
}

struct CompactWindowRow: View {
    let title: String
    let window: RateWindow

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 128, alignment: .leading)
            UsageBar(leftPercent: window.leftPercent)
                .frame(height: 4)
            PercentLabel(leftPercent: window.leftPercent, compact: true)
        }
    }
}

struct PercentLabel: View {
    let leftPercent: Double
    var compact = false

    var body: some View {
        let fraction = leftPercent / 100
        Text("\(Int(leftPercent.rounded()))% left")
            .font(.system(size: compact ? 11 : 12, weight: compact ? .medium : .semibold))
            .monospacedDigit()
            .foregroundStyle(fraction < 0.5 ? Status.swiftUIColor(leftFraction: fraction) : .primary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: 64, alignment: .trailing)
    }
}

struct UsageBar: View {
    let leftPercent: Double

    var body: some View {
        GeometryReader { proxy in
            let fraction = max(0, min(1, leftPercent / 100))
            let tint = Status.swiftUIColor(leftFraction: fraction)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.height, proxy.size.width * fraction))
            }
        }
    }
}

struct DisclosureRow<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @State private var hovering = false
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    label()
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.snappy(duration: 0.2), value: isExpanded)
                }
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                        .padding(-6)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .pointerCursor()

            if isExpanded {
                content()
            }
        }
    }
}

struct CreditsCard: View {
    @ObservedObject var store: Store
    let availableCount: Int?

    var body: some View {
        DisclosureRow(isExpanded: Binding(
            get: { store.creditsExpanded },
            set: { expanded in
                store.creditsExpanded = expanded
                if expanded {
                    Task { await store.loadCreditsIfNeeded() }
                }
            }
        )) {
            SectionIcon(symbol: "arrow.counterclockwise.circle.fill", tint: .orange)
            Text(countText)
                .font(.system(size: 12, weight: .medium))
            if let next = nextExpiry {
                Text("· next \(next)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } content: {
            detail
                .font(.caption)
                .padding(.leading, 30)
        }
        .padding(12)
        .background(CardBackground())
    }

    private var countText: String {
        switch availableCount {
        case .some(1): "1 reset credit"
        case .some(let count): "\(count) reset credits"
        case .none:
            if case let .done(credits) = store.creditsState { "\(credits.count) reset credits" } else { "Reset credits" }
        }
    }

    private var nextExpiry: String? {
        guard case let .done(credits) = store.creditsState,
              let earliest = credits.compactMap(\.expiresAt).min() else { return nil }
        return "expires \(earliest.formatted(.dateTime.month(.abbreviated).day()))"
    }

    @ViewBuilder
    private var detail: some View {
        switch store.creditsState {
        case .idle where store.connectivity != .available || store.creditsConnectionFailed:
            Text("Credit details haven't loaded yet.")
                .foregroundStyle(.secondary)
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fetching credit details…")
            }
            .foregroundStyle(.secondary)
        case let .failed(message):
            ErrorRow(message: message)
        case let .done(credits):
            if credits.isEmpty {
                Text("No detailed credits reported.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(credits) { credit in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 4, height: 4)
                            if let expires = credit.expiresAt {
                                Text("Expires \(expires.formatted(.dateTime.month(.abbreviated).day())) · in \(WindowRow.format(expires, now: store.clock))")
                            } else {
                                Text("No expiry reported")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
        }
    }
}

struct SectionIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 22, height: 22)
    }
}

struct ModelCatalogCard: View {
    @ObservedObject var store: Store

    var body: some View {
        DisclosureRow(isExpanded: Binding(
            get: { store.modelsExpanded },
            set: { expanded in
                store.modelsExpanded = expanded
                if expanded {
                    Task { await store.loadModelCatalogIfNeeded() }
                }
            }
        )) {
            SectionIcon(symbol: "square.stack.3d.up.fill", tint: .purple)
            Text("Models")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            if case let .done(groups) = store.modelsState {
                Text("\(groups.reduce(0) { $0 + $1.models.count }) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } content: {
            content
        }
        .padding(12)
        .background(CardBackground())
    }

    @ViewBuilder
    private var content: some View {
        switch store.modelsState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading OpenCode's model catalog…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            ErrorRow(message: message)
        case let .done(groups):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(group.title.uppercased()) · \(group.models.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(group.models) { model in
                            HStack(spacing: 8) {
                                Text(model.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text(model.priceLine)
                                    .font(.caption2)
                                    .foregroundStyle(model.priceLine == "Free" ? Color.green : Color.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Text("From OpenCode's cached catalog and saved provider logins.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
    }
}

struct LocalUsageCard: View {
    @ObservedObject var store: Store
    let provider: Provider

    var body: some View {
        DisclosureRow(isExpanded: Binding(
            get: { store.usageExpanded.contains(provider) },
            set: { expanded in
                if expanded {
                    store.usageExpanded.insert(provider)
                    Task { await store.loadUsageIfNeeded(provider) }
                } else {
                    store.usageExpanded.remove(provider)
                }
            }
        )) {
            SectionIcon(symbol: "chart.bar.xaxis", tint: .accentColor)
            Text("Local usage")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            if case let .done(totals) = store.usageState(for: provider) {
                Text("\(Self.formatTokens(totals.tokens30d)) tokens · 30d")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } content: {
            content
        }
        .padding(12)
        .background(CardBackground())
    }

    @ViewBuilder
    private var content: some View {
        switch store.usageState(for: provider) {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Compiling totals from \(provider.localUsageDescription ?? "local logs")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                ErrorRow(message: message)
                Button("Retry") {
                    Task { await store.loadUsageIfNeeded(provider, force: true) }
                }
                .controlSize(.small)
            }
        case let .done(totals):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatTile(label: "Last 24h", value: Self.formatTokens(totals.tokens24h))
                    StatTile(label: "Last 30d", value: Self.formatTokens(totals.tokens30d))
                }
                HStack {
                    Text("Estimated from \(provider.localUsageDescription ?? "local logs") · \(PopoverView.ago(from: totals.computedAt, now: store.clock))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        Task { await store.loadUsageIfNeeded(provider, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .pointerCursor()
                    .help("Recompute")
                }
            }
            .padding(.top, 2)
        }
    }

    static func formatTokens(_ count: Int) -> String {
        let value = Double(count)
        return switch value {
        case 1_000_000_000...: String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", value / 1_000_000)
        case 1_000...: String(format: "%.1fK", value / 1_000)
        default: String(count)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

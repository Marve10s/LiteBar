import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    enum Page: Equatable {
        case overview
        case provider(Provider)
        case settings
    }

    @Published private(set) var snapshots: [Provider: ProviderSnapshot] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var refreshing: Set<Provider> = []
    @Published private(set) var connectivity: Connectivity = .checking
    @Published private(set) var connectionFailures: Set<Provider> = []
    @Published private(set) var creditsConnectionFailed = false

    var isRefreshing: Bool { connectivity == .available && !refreshing.isEmpty }

    var connectionNotice: String? {
        guard enabledProviders.contains(where: { $0 != .claude || ClaudeUsageMode.current == .live }) else { return nil }
        let message: String
        switch connectivity {
        case .checking:
            return "Checking the network connection…"
        case .offline:
            message = "Waiting for an internet connection. Usage will refresh automatically when it returns."
        case .available:
            guard !connectionFailures.isEmpty || creditsConnectionFailed else { return nil }
            message = "The connection was interrupted. Refresh to try again."
        }
        return orderedSnapshots.contains(where: { !$0.windows.isEmpty })
            ? message + " Showing last loaded usage." : message
    }

    @Published private(set) var windowPreferences = WindowPreferences.load()

    @Published private(set) var iconImage: NSImage
    @Published private(set) var menuBarPercent: Double?

    @Published var page: Page = .overview
    @Published private(set) var clock = Date()

    @Published var creditsExpanded = false
    @Published private(set) var creditsState: LoadState<[ResetCredit]> = .idle
    @Published var usageExpanded: Set<Provider> = []
    @Published private(set) var usageStates: [Provider: LoadState<ProviderTotals>] = [:]
    @Published var modelsExpanded = false
    @Published private(set) var modelsState: LoadState<[OpenCodeClient.ModelGroup]> = .idle

    private var refreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var creditsLoadedAt: Date?
    private var usageLoadedAt: [Provider: Date] = [:]
    private var modelsLoadedAt: Date?
    private let monitor = ConnectivityMonitor()
    private let captureWatcher = ClaudeCaptureWatcher()
    private var captureRevision = 0
    @Published private(set) var claudeSetupMessage: String?
    @Published var claudeAuthorization: ClaudeOAuth.Authorization?
    @Published var claudeAuthorizationCode = ""
    @Published var claudeConnecting = false
    @Published var claudeConnectionMessage: String?
    private var started = false
    private var connectionRevision = 0
    private var providerTasks: [Provider: (id: UUID, task: Task<Void, Never>)] = [:]
    private let fetchProvider: @Sendable (Provider) async -> ProviderSnapshot

    init(fetchProvider: @escaping @Sendable (Provider) async -> ProviderSnapshot = Store.fetch) {
        self.fetchProvider = fetchProvider
        iconImage = MenuBarGlyph.image(leftFraction: 1, hasError: false)
    }

    var enabledProviders: [Provider] { ProviderPreferences.enabled }

    var orderedSnapshots: [ProviderSnapshot] {
        enabledProviders.compactMap { snapshots[$0] }
    }

    func snapshot(for provider: Provider) -> ProviderSnapshot? {
        snapshots[provider]
    }

    func start() {
        guard !started else { return }
        started = true
        configureClaudeCapture()
        if ClaudeUsageMode.current == .local { Task { await refresh(.claude) } }
        monitor.start { [weak self] connectivity in
            Task { @MainActor [weak self] in
                await self?.connectivityChanged(connectivity)
            }
        }
        scheduleLoop()
    }

    func connectivityChanged(_ state: Connectivity) async {
        let previous = connectivity
        connectivity = state
        connectionRevision += 1
        updateMenuBar()
        guard state == .available else { return }
        if previous != .available || !connectionFailures.isEmpty {
            await refreshAll()
        }
        if creditsExpanded, previous != .available || creditsConnectionFailed {
            await loadCreditsIfNeeded(force: creditsConnectionFailed)
        }
    }

    func applyIntervalChange() {
        scheduleLoop()
    }

    private func scheduleLoop() {
        refreshTask?.cancel()
        let interval = RefreshInterval.current
        guard interval.seconds > 0 else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = RefreshInterval.current.seconds
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        clockTask?.cancel()
        clockTask = nil
        guard visible else { return }
        clock = Date()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.clock = Date()
            }
        }
    }

    func refreshAll() async {
        let tasks = enabledProviders.compactMap { refreshTask(for: $0) }
        guard !tasks.isEmpty else { return }
        for task in tasks { await task.value }
        lastRefresh = Date()
    }

    func refresh(_ provider: Provider) async {
        await refreshTask(for: provider)?.value
    }

    private func refreshTask(for provider: Provider) -> Task<Void, Never>? {
        let isLocal = provider == .claude && ClaudeUsageMode.current == .local
        guard connectivity == .available || isLocal, enabledProviders.contains(provider) else { return nil }
        if let running = providerTasks[provider] {
            return running.task
        }
        let id = UUID()
        let revision = connectionRevision
        let localRevision = captureRevision
        let fetch = fetchProvider
        refreshing.insert(provider)
        let task = Task { [weak self] in
            let snapshot = await fetch(provider)
            guard let self, self.providerTasks[provider]?.id == id else { return }
            self.providerTasks[provider] = nil
            self.refreshing.remove(provider)
            guard !Task.isCancelled, self.enabledProviders.contains(provider) else { return }

            if isLocal, localRevision != self.captureRevision {
                await self.refresh(provider)
                return
            }

            if snapshot.connectionFailed {
                if self.connectivity == .available, revision != self.connectionRevision {
                    await self.refresh(provider)
                    return
                }
                self.connectionFailures.insert(provider)
            } else {
                self.connectionFailures.remove(provider)
                self.snapshots[provider] = snapshot
            }
            self.updateMenuBar()
        }
        providerTasks[provider] = (id, task)
        return task
    }

    func setEnabled(_ provider: Provider, _ enabled: Bool) {
        ProviderPreferences.setEnabled(provider, enabled)
        if provider == .claude { configureClaudeCapture() }
        if enabled {
            Task { await refresh(provider) }
        } else {
            providerTasks.removeValue(forKey: provider)?.task.cancel()
            refreshing.remove(provider)
            connectionFailures.remove(provider)
            snapshots[provider] = nil
            if provider == .codex { creditsConnectionFailed = false }
            if page == .provider(provider) { page = .overview }
            updateMenuBar()
        }
    }

    func setClaudeMode(_ mode: ClaudeUsageMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ClaudeUsageMode.key)
        providerTasks.removeValue(forKey: .claude)?.task.cancel()
        refreshing.remove(.claude)
        snapshots[.claude] = nil
        connectionFailures.remove(.claude)
        configureClaudeCapture()
        updateMenuBar()
        Task { await refresh(.claude) }
    }

    private func configureClaudeCapture() {
        captureWatcher.stop()
        guard enabledProviders.contains(.claude), ClaudeUsageMode.current == .local else { return }
        do {
            try captureWatcher.start { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.captureRevision += 1
                    await self.refresh(.claude)
                }
            }
        } catch { claudeSetupMessage = "Could not watch Claude captures: \(error.localizedDescription)" }
    }

    func installClaudeCapture() {
        do {
            _ = try ClaudeCaptureInstaller.install()
            claudeSetupMessage = "Capture enabled. Claude Code will publish limits after its next response."
            configureClaudeCapture()
        } catch { claudeSetupMessage = error.localizedDescription }
    }

    func setWindowVisible(_ visible: Bool, _ title: String, for provider: Provider) {
        windowPreferences.setVisible(visible, title, for: provider)
        windowPreferences.save()
        updateMenuBar()
    }

    func setHeadlineWindow(_ title: String, for provider: Provider) {
        windowPreferences.setHeadline(title, for: provider)
        windowPreferences.save()
    }

    func updateMenuBar() {
        let source = MenuBarSource.current
        let tracked: [ProviderSnapshot]
        switch source {
        case .tightest: tracked = orderedSnapshots
        case let .provider(provider): tracked = snapshots[provider].map { [$0] } ?? []
        }
        let visible = tracked.map { windowPreferences.visibleWindows(of: $0) }.filter { !$0.isEmpty }
        let hasError = visible.isEmpty && (connectivity == .offline || !connectionFailures.isEmpty || tracked.contains { $0.error != nil })
        let worst = visible.flatMap { $0 }.map(\.leftPercent).min()
        menuBarPercent = worst
        iconImage = MenuBarGlyph.image(leftFraction: (worst ?? 100) / 100, hasError: hasError)
    }

    nonisolated static func fetch(_ provider: Provider) async -> ProviderSnapshot {
        do {
            switch provider {
            case .codex:
                let usage = try await CodexClient.usage()
                return ProviderSnapshot(
                    provider: .codex,
                    accountLine: usage.email,
                    badge: usage.planType?.capitalized,
                    windows: usage.windows,
                    extras: usage.extras,
                    extrasTitle: "Extras",
                    creditsAvailable: usage.resetCreditCount,
                    fetchedAt: Date()
                )
            case .claude:
                let usage = try await ClaudeClient.usage()
                return ProviderSnapshot(
                    provider: .claude,
                    badge: usage.accountSummary,
                    windows: usage.windows,
                    extras: [],
                    isLocalCapture: usage.capturedAt != nil,
                    fetchedAt: usage.capturedAt ?? Date()
                )
            case .antigravity:
                let usage = try await AntigravityClient.usage()
                return ProviderSnapshot(
                    provider: .antigravity,
                    accountLine: usage.email,
                    badge: usage.tier,
                    windows: usage.pools,
                    extras: usage.models,
                    extrasTitle: "Models",
                    fetchedAt: Date()
                )
            case .opencode:
                let usage = try await OpenCodeClient.usage()
                return ProviderSnapshot(
                    provider: .opencode,
                    badge: "Go",
                    windows: usage.windows,
                    extras: [],
                    fetchedAt: Date()
                )
            }
        } catch {
            return .failed(provider, error)
        }
    }

    func loadCreditsIfNeeded(force: Bool = false) async {
        guard connectivity == .available, creditsState != .loading else { return }
        if let loaded = creditsLoadedAt, !force, Date().timeIntervalSince(loaded) < 600,
           case .done = creditsState { return }
        let previous = creditsState
        let revision = connectionRevision
        creditsState = .loading
        do {
            creditsState = .done(try await CodexClient.resetCredits())
            creditsLoadedAt = Date()
            creditsConnectionFailed = false
        } catch {
            if Connectivity.isConnectionError(error) {
                creditsState = previous
                creditsConnectionFailed = true
                if connectivity == .available, revision != connectionRevision {
                    await loadCreditsIfNeeded(force: true)
                }
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                creditsState = previous
            } else {
                creditsConnectionFailed = false
                creditsState = .failed(error.localizedDescription)
            }
        }
    }

    func usageState(for provider: Provider) -> LoadState<ProviderTotals> {
        usageStates[provider] ?? .idle
    }

    func loadUsageIfNeeded(_ provider: Provider, force: Bool = false) async {
        if let loaded = usageLoadedAt[provider], !force, Date().timeIntervalSince(loaded) < 600,
           case .done = usageState(for: provider) { return }
        usageStates[provider] = .loading
        do {
            let totals = try await Task.detached(priority: .utility) {
                try await LogUsage.compute(provider)
            }.value
            usageStates[provider] = .done(totals)
            usageLoadedAt[provider] = Date()
        } catch {
            usageStates[provider] = .failed(error.localizedDescription)
        }
    }

    func loadModelCatalogIfNeeded(force: Bool = false) async {
        if let loaded = modelsLoadedAt, !force, Date().timeIntervalSince(loaded) < 600,
           case .done = modelsState { return }
        modelsState = .loading
        do {
            let groups = try await Task.detached(priority: .utility) {
                try OpenCodeClient.modelCatalog()
            }.value
            modelsState = .done(groups)
            modelsLoadedAt = Date()
        } catch {
            modelsState = .failed(error.localizedDescription)
        }
    }
}

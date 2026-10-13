import AppKit
import SwiftUI
import Testing
@testable import LiteBar

@MainActor
struct PopoverSizingTests {
    @Test func windowTracksNavigationAndExpandedContent() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = [ProviderPreferences.key, ProviderPreferences.catalogKey, OverviewMode.key]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(Provider.available.map(\.rawValue), forKey: ProviderPreferences.key)
        defaults.set(Provider.allCases.map(\.rawValue), forKey: ProviderPreferences.catalogKey)
        defaults.set(OverviewMode.expanded.rawValue, forKey: OverviewMode.key)
        let store = Store(fetchProvider: { provider in
            ProviderSnapshot(provider: provider,
                             windows: [RateWindow(usedPercent: 10, title: "Session"), RateWindow(usedPercent: 20, title: "Weekly")],
                             extras: [], fetchedAt: Date())
        })
        await store.connectivityChanged(.available)
        let host = NSHostingView(rootView: PopoverView(store: store))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settleLayout() async {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        func expectFittedWindow() {
            let size = window.contentRect(forFrameRect: window.frame).size
            #expect(abs(size.width - host.fittingSize.width) < 1)
            #expect(abs(size.height - host.fittingSize.height) < 1)
        }
        await settleLayout()
        let overviewHeight = window.frame.height
        let topEdge = window.frame.maxY
        expectFittedWindow()
        store.page = .provider(.codex)
        await settleLayout()
        let detailHeight = window.frame.height
        #expect(detailHeight < overviewHeight)
        #expect(abs(window.frame.maxY - topEdge) < 1)
        expectFittedWindow()
        store.usageExpanded.insert(.codex)
        await settleLayout()
        #expect(window.frame.height > detailHeight)
        #expect(abs(window.frame.maxY - topEdge) < 1)
        expectFittedWindow()
        store.page = .overview
        await settleLayout()
        #expect(abs(window.frame.height - overviewHeight) < 1)
        #expect(abs(window.frame.maxY - topEdge) < 1)
        expectFittedWindow()
    }
}

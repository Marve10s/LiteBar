import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct LiteBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: Store

    init() {
        Self.handleMakeIconFlag()
        let store = Store()
        _store = StateObject(wrappedValue: store)
        Task { @MainActor in store.start() }
    }

    private static func handleMakeIconFlag() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--make-icon"),
              arguments.count > index + 1 else { return }
        let output = URL(fileURLWithPath: arguments[index + 1])
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("litebar-icon-\(UUID().uuidString)")
        let iconset = workDir.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        let variants: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for variant in variants {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: variant.pixels,
                pixelsHigh: variant.pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            AppIconArtwork.draw(in: NSRect(x: 0, y: 0, width: CGFloat(variant.pixels), height: CGFloat(variant.pixels)))
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: iconset.appendingPathComponent(variant.name))
            }
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        try? iconutil.run()
        iconutil.waitUntilExit()
        exit(iconutil.terminationStatus)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: Store
    @AppStorage("menuBarShowsPercent") private var showsPercent = true

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: store.iconImage)
            if showsPercent, let percent = store.menuBarPercent {
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
            }
        }
    }
}

import ClaudeUsageData
import Foundation

final class ClaudeCaptureWatcher {
    private var source: DispatchSourceFileSystemObject?

    func start(_ changed: @escaping @Sendable () -> Void) throws {
        stop()
        let directory = ClaudeCapture.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                              eventMask: [.write],
                                                              queue: DispatchQueue(label: "dev.ibrahime.LiteBar.capture", qos: .utility))
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}

enum ClaudeCaptureInstaller {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LiteBarCapture")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func install(settingsURL: URL = settingsURL, helperURL: URL = helperURL) throws -> URL? {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AppError("The capture helper is missing. Reinstall the packaged LiteBar app.")
        }
        let original = try? Data(contentsOf: settingsURL)
        var settings: [String: Any] = [:]
        if let original {
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw AppError("Claude settings must be a JSON object. No changes were made.")
            }
            settings = object
        } else if FileManager.default.fileExists(atPath: settingsURL.path) {
            throw AppError("Claude settings could not be read. No changes were made.")
        }
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        if settings["statusLine"] != nil, !(settings["statusLine"] is NSNull),
           settings["statusLine"] as? [String: Any] == nil {
            throw AppError("Claude has an unsupported status line configuration. No changes were made.")
        }
        let command = shellQuote(helperURL.path)
        let previous = statusLine["command"] as? String
        if previous == command || previous?.hasPrefix(command + " --forward ") == true { return nil }
        if !statusLine.isEmpty, statusLine["type"] as? String != "command" {
            throw AppError("Claude has an unsupported status line type. No changes were made.")
        }
        statusLine["type"] = "command"
        statusLine["command"] = previous.map { command + " --forward " + shellQuote($0) } ?? command
        settings["statusLine"] = statusLine
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if let original {
            let url = settingsURL.appendingPathExtension("litebar-backup-" + UUID().uuidString)
            try original.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            backup = url
        }
        let updated = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: settingsURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        return backup
    }
}

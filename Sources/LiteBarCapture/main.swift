import ClaudeUsageData
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
let capture = input.count <= 262_144 ? try? ClaudeCapture.fromStatusLine(input) : nil
if let capture { _ = try? capture.save() }

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--forward" {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", arguments[2]]
    let pipe = Pipe()
    process.standardInput = pipe
    do {
        try process.run()
        try pipe.fileHandleForWriting.write(contentsOf: input)
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        exit(process.terminationStatus)
    } catch {
        fputs("LiteBar could not forward the existing status line.\n", stderr)
        exit(1)
    }
} else {
    print(capture?.statusText ?? "Claude")
}

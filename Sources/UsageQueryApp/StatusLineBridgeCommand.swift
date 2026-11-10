import Foundation
import UsageQueryCore

/// `UsageQuery --statusline-bridge [-- <existing status line command>]`
///
/// A single argument after `--` is run as a shell command line, like Claude
/// Code runs `statusLine.command`; several arguments are run as given.
///
/// Reads the status line JSON Claude Code pipes to stdin, stores its 5h / 7 days
/// limit numbers for the app, then prints a status line: the wrapped command's
/// output when one is given, otherwise a short usage summary.
enum StatusLineBridgeCommand {
    static let flag = "--statusline-bridge"

    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let snapshots = (try? ClaudeRateLimitBridge.record(statusLineJSON: input)) ?? []

        let arguments = CommandLine.arguments
        if let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count {
            exit(runWrapped(Array(arguments[(separator + 1)...]), input: input))
        }

        let now = Date()
        let current = snapshots.filter { $0.resetAt.map { $0 > now } ?? true }
        print(ClaudeRateLimitBridge.statusLineText(for: current))
        exit(0)
    }

    private static func runWrapped(_ command: [String], input: Data) -> Int32 {
        let process = Process()
        if command.count == 1 {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command[0]]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }
        // A command that never reads stdin must neither kill nor stall the bridge.
        signal(SIGPIPE, SIG_IGN)
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            return 1
        }
        let writer = stdin.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

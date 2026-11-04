import Foundation

struct GitResult: Sendable {
    let stdout: Data
    let stderr: String
    let status: Int32

    var output: String { String(decoding: stdout, as: UTF8.self) }
}

struct GitError: LocalizedError {
    let command: String
    let message: String

    var errorDescription: String? { message.isEmpty ? "`git \(command)` failed" : message }
}

/// Thin async wrapper around the `git` CLI. Shelling out keeps behaviour identical to the
/// terminal (hooks, credentials, config) and avoids a libgit2 dependency.
enum Git {
    /// GUI apps get a minimal PATH, so resolve git explicitly.
    static let executable: String = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }()

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// PATH from the user's interactive login shell. Apps launched from Finder get a minimal PATH,
    /// so git hooks (husky → npx/node via nvm, Homebrew tools) would fail with "command not found".
    /// Resolved once, lazily and thread-safely; falls back to the process PATH after 4 s.
    static let loginShellPath: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '__SIGHTLINE_PATH__%s__END__' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        do { try process.run() } catch { return nil }
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            return nil
        }
        let output = String(decoding: box.data, as: UTF8.self)
        guard let start = output.range(of: "__SIGHTLINE_PATH__"),
              let end = output.range(of: "__END__", range: start.upperBound..<output.endIndex) else { return nil }
        let path = String(output[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }()

    /// Runs `git -C <repo> <args>`. Exit codes outside `okCodes` throw with git's stderr.
    static func run(
        _ args: [String],
        in repo: String,
        okCodes: Set<Int32> = [0],
        extraEnv: [String: String] = [:]
    ) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["-C", repo] + args

                var env = ProcessInfo.processInfo.environment
                if let path = loginShellPath { env["PATH"] = path }
                env["GIT_OPTIONAL_LOCKS"] = "0" // our reads must never touch .git/index (watcher loop)
                env["GIT_TERMINAL_PROMPT"] = "0" // never block on a credential prompt
                env["GIT_PAGER"] = "cat"
                for (key, value) in extraEnv { env[key] = value }
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain both pipes concurrently; reading one while the other fills past the
                // pipe buffer deadlocks the child.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                let result = GitResult(
                    stdout: outData,
                    stderr: String(decoding: errBox.data, as: UTF8.self),
                    status: process.terminationStatus
                )
                if okCodes.contains(result.status) {
                    continuation.resume(returning: result)
                } else {
                    // Hooks (husky/lint-staged) often report on stdout; show both.
                    let message = [result.stderr, result.output]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    continuation.resume(throwing: GitError(command: args.joined(separator: " "), message: message))
                }
            }
        }
    }
}

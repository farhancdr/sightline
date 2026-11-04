import AppKit

/// An installed code editor. "Open in" opens the file's git repo as the editor's workspace, with the file
/// at the line, using the CLI bundled inside the editor's app (so nothing needs to be on PATH).
struct ExternalEditor: Identifiable, Hashable, Sendable {
    enum CLIStyle: Sendable {
        /// VS Code family: `code <repo> -g <file>:<line>`
        case vscode
        /// `cli <repo> <file>:<line>` (Zed, Sublime Text)
        case pathWithLine
    }

    /// Bundle identifier.
    let id: String
    let name: String
    /// CLI inside the .app.
    let cliPath: String?
    let cliStyle: CLIStyle
    /// Fallback when the CLI is missing: `<scheme>://file/<path>:<line>` (file only).
    let urlScheme: String?

    static let known: [ExternalEditor] = [
        ExternalEditor(id: "com.microsoft.VSCode", name: "VS Code", cliPath: "Contents/Resources/app/bin/code",
                       cliStyle: .vscode, urlScheme: "vscode"),
        ExternalEditor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", cliPath: "Contents/Resources/app/bin/cursor",
                       cliStyle: .vscode, urlScheme: "cursor"),
        ExternalEditor(id: "com.exafunction.windsurf", name: "Windsurf", cliPath: "Contents/Resources/app/bin/windsurf",
                       cliStyle: .vscode, urlScheme: "windsurf"),
        ExternalEditor(id: "dev.zed.Zed", name: "Zed", cliPath: "Contents/MacOS/cli",
                       cliStyle: .pathWithLine, urlScheme: nil),
        ExternalEditor(id: "com.sublimetext.4", name: "Sublime Text", cliPath: "Contents/SharedSupport/bin/subl",
                       cliStyle: .pathWithLine, urlScheme: nil),
        ExternalEditor(id: "com.apple.dt.Xcode", name: "Xcode", cliPath: nil, cliStyle: .pathWithLine, urlScheme: nil),
    ]

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static var installed: [ExternalEditor] { known.filter { $0.appURL != nil } }

    /// `vscode://file/Users/me/a b.ts:12` (path percent-encoded; ":line" stays literal).
    static func fileURL(scheme: String, path: String, line: Int?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = path + (line.map { ":\($0)" } ?? "")
        return components.url
    }

    /// CLI arguments to open `repo` as the workspace and `file` at `line`.
    static func cliArguments(style: CLIStyle, repo: String?, file: String?, line: Int?) -> [String] {
        let target = file.map { $0 + (line.map { ":\($0)" } ?? "") }
        switch style {
        case .vscode:
            return [repo].compactMap { $0 } + (target.map { line != nil ? ["-g", $0] : [$0] } ?? [])
        case .pathWithLine:
            return [repo, target].compactMap { $0 }
        }
    }

    /// Opens `repo` (folder) as the workspace and, when given, `file` at `line` inside it.
    func open(repo: String?, file: String?, line: Int?) {
        if let cliPath, let app = appURL {
            let cli = app.appendingPathComponent(cliPath)
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                let process = Process()
                process.executableURL = cli
                process.arguments = Self.cliArguments(style: cliStyle, repo: repo, file: file, line: line)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { return }
            }
        }
        // No CLI: open the file at the line via URL scheme, else hand the folder/file to the app.
        if let urlScheme, let file, let url = Self.fileURL(scheme: urlScheme, path: file, line: line) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let app = appURL else { return }
        let urls = [repo, file].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

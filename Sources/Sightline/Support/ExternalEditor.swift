import AppKit

/// An installed code editor that files can be handed off to, at a line when the editor supports it.
struct ExternalEditor: Identifiable, Hashable, Sendable {
    /// Bundle identifier.
    let id: String
    let name: String
    /// URL scheme that understands `<scheme>://file/<absolute path>:<line>` (VS Code family).
    let urlScheme: String?
    /// Bundled CLI (relative to the .app) that takes `path:line`.
    let cliPath: String?

    static let known: [ExternalEditor] = [
        ExternalEditor(id: "com.microsoft.VSCode", name: "VS Code", urlScheme: "vscode", cliPath: nil),
        ExternalEditor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", urlScheme: "cursor", cliPath: nil),
        ExternalEditor(id: "com.exafunction.windsurf", name: "Windsurf", urlScheme: "windsurf", cliPath: nil),
        ExternalEditor(id: "dev.zed.Zed", name: "Zed", urlScheme: nil, cliPath: "Contents/MacOS/cli"),
        ExternalEditor(id: "com.sublimetext.4", name: "Sublime Text", urlScheme: nil,
                       cliPath: "Contents/SharedSupport/bin/subl"),
        ExternalEditor(id: "com.apple.dt.Xcode", name: "Xcode", urlScheme: nil, cliPath: nil),
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

    func open(path: String, line: Int?) {
        if let urlScheme, let url = Self.fileURL(scheme: urlScheme, path: path, line: line) {
            NSWorkspace.shared.open(url)
            return
        }
        if let cliPath, let app = appURL {
            let cli = app.appendingPathComponent(cliPath)
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                let process = Process()
                process.executableURL = cli
                process.arguments = [path + (line.map { ":\($0)" } ?? "")]
                if (try? process.run()) != nil { return }
            }
        }
        guard let app = appURL else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

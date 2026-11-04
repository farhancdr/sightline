import Foundation

/// Reads a file for the editor: text, or a reason it can't be edited.
struct FileContent: Sendable {
    let path: String
    let text: String?
    let message: String?

    static let maxBytes = 2 * 1024 * 1024

    static func load(path: String) -> FileContent {
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return FileContent(path: path, text: nil, message: "File not found")
        }
        if size > maxBytes {
            let mb = String(format: "%.1f", Double(size) / 1_048_576)
            return FileContent(path: path, text: nil, message: "File is \(mb) MB, too large to open")
        }
        guard let data = try? Data(contentsOf: url) else {
            return FileContent(path: path, text: nil, message: "Could not read file")
        }
        if data.prefix(8192).contains(0) {
            return FileContent(path: path, text: nil, message: "Binary file")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return FileContent(path: path, text: nil, message: "Not UTF-8 text, not opened to avoid corrupting it")
        }
        return FileContent(path: path, text: text, message: nil)
    }
}

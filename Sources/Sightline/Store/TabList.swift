import Foundation

/// Open-file tabs (absolute paths, any repo), VS Code style:
/// - a new tab opens to the right of the active one;
/// - a "preview" tab (italic) is replaced by the next preview open, unless it has unsaved edits;
///   editing it or double-clicking its tab keeps it;
/// - closing the active tab activates its right neighbor, else its left one (optionally only tabs matching a
///   predicate, e.g. the same repo).
struct TabList: Equatable {
    private(set) var paths: [String] = []
    private(set) var active: String?
    private(set) var preview: String?

    var isEmpty: Bool { paths.isEmpty }

    func contains(_ path: String) -> Bool { paths.contains(path) }

    /// Opens or activates `path`. Returns the path of a preview tab it replaced (its session can be dropped).
    @discardableResult
    mutating func open(_ path: String, asPreview: Bool, previewIsDirty: Bool = false) -> String? {
        if paths.contains(path) {
            active = path
            if !asPreview { pin(path) }
            return nil
        }
        if asPreview, let old = preview, !previewIsDirty, let index = paths.firstIndex(of: old) {
            paths[index] = path // in place, so the bar doesn't jump
            preview = path
            active = path
            return old
        }
        let index = active.flatMap { paths.firstIndex(of: $0) }.map { $0 + 1 } ?? paths.endIndex
        paths.insert(path, at: index)
        active = path
        if asPreview { preview = path }
        return nil
    }

    mutating func activate(_ path: String) {
        if paths.contains(path) { active = path }
    }

    /// No active tab (nil), or one of the open ones.
    mutating func setActive(_ path: String?) {
        if path == nil || paths.contains(path!) { active = path }
    }

    mutating func pin(_ path: String) {
        if preview == path { preview = nil }
    }

    /// Closes `path`; returns the new active tab: the nearest tab to the right, else to the left, among
    /// those matching `preferring` (nil if none does).
    @discardableResult
    mutating func close(_ path: String, preferring: (String) -> Bool = { _ in true }) -> String? {
        guard let index = paths.firstIndex(of: path) else { return active }
        paths.remove(at: index)
        if preview == path { preview = nil }
        if active == path {
            active = paths[index...].first(where: preferring) ?? paths[..<index].last(where: preferring)
        }
        return active
    }

    /// Tabs that "Close Others" / "Close to the Right" would close.
    func others(than path: String) -> [String] { paths.filter { $0 != path } }

    func right(of path: String) -> [String] {
        guard let index = paths.firstIndex(of: path) else { return [] }
        return Array(paths[(index + 1)...])
    }

    /// The tab `offset` steps from the active one, wrapping around.
    func neighbor(_ offset: Int) -> String? {
        guard !paths.isEmpty else { return nil }
        guard let active, let index = paths.firstIndex(of: active) else { return paths.first }
        let count = paths.count
        return paths[((index + offset) % count + count) % count]
    }
}

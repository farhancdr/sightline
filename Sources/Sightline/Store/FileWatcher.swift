import CoreServices
import Foundation

/// One recursive FSEvents stream on the root. Delivers batches of changed paths on the main queue.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let changed = (0..<count).compactMap { array[$0] as? String }
            watcher.handler(changed)
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    /// Paths that should trigger a status refresh. Inside `.git` only the files that change when
    /// the user stages, commits, switches or fetches in the terminal.
    static func isRelevant(_ path: String) -> Bool {
        if path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/.swiftpm/")
            || path.hasSuffix("/.DS_Store") { return false }
        guard let gitRange = path.range(of: "/.git/") else {
            return !path.hasSuffix("/.git")
        }
        let inside = path[gitRange.upperBound...]
        if inside.hasSuffix(".lock") { return false }
        let first = inside.split(separator: "/").first.map(String.init) ?? ""
        return ["HEAD", "index", "refs", "packed-refs", "MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"]
            .contains(first)
    }
}

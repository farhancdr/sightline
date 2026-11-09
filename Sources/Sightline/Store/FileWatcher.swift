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
    ///
    /// This is hot: FSEvents hands over batches of hundreds or thousands of paths **on the main
    /// queue**, ahead of the debounce, so the whole batch is classified before the next frame can
    /// draw. It therefore matches raw UTF-8 rather than `String.contains` / `range(of:)`, whose
    /// Foundation overloads are locale-aware: measured at `-O` over 10 000 realistic paths, those
    /// cost 6.7µs per path against 0.3µs here — 67ms of blocked main thread versus 3ms.
    static func isRelevant(_ path: String) -> Bool {
        var path = path
        return path.withUTF8 { isRelevant(bytes: $0) }
    }

    private static func isRelevant(bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        if contains(bytes, Pattern.nodeModules) || contains(bytes, Pattern.build)
            || contains(bytes, Pattern.swiftpm) || hasSuffix(bytes, Pattern.dsStore) { return false }
        guard let gitDir = firstIndex(bytes, Pattern.gitSlash) else {
            return !hasSuffix(bytes, Pattern.gitEnd)
        }
        // Everything after the first "/.git/": "index", "refs/heads/main", "objects/ab/cdef"…
        let inside = gitDir + Pattern.gitSlash.count
        if bytes.count - inside >= Pattern.lock.count, hasSuffix(bytes, Pattern.lock) { return false }
        // The first non-empty component, matching `split(separator:)`, which drops empty ones:
        // "//HEAD" and "/HEAD" both name HEAD.
        var start = inside
        while start < bytes.count, bytes[start] == UInt8(ascii: "/") { start += 1 }
        var end = start
        while end < bytes.count, bytes[end] != UInt8(ascii: "/") { end += 1 }
        return Pattern.gitEntries.contains { equals(bytes, $0, from: start, to: end) }
    }

    private enum Pattern {
        static let nodeModules = Array("/node_modules/".utf8)
        static let build = Array("/.build/".utf8)
        static let swiftpm = Array("/.swiftpm/".utf8)
        static let dsStore = Array("/.DS_Store".utf8)
        static let gitSlash = Array("/.git/".utf8)
        static let gitEnd = Array("/.git".utf8)
        static let lock = Array(".lock".utf8)
        /// The entries inside `.git` that change when the user stages, commits, switches or fetches.
        static let gitEntries = ["HEAD", "index", "refs", "packed-refs", "MERGE_HEAD", "REBASE_HEAD",
                                 "CHERRY_PICK_HEAD"].map { Array($0.utf8) }
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        firstIndex(bytes, needle) != nil
    }

    private static func firstIndex(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= bytes.count else { return nil }
        for start in 0...(bytes.count - needle.count) where bytes[start] == needle[0] {
            var offset = 1
            while offset < needle.count, bytes[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return start }
        }
        return nil
    }

    private static func hasSuffix(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard bytes.count >= needle.count else { return false }
        let start = bytes.count - needle.count
        for index in 0..<needle.count where bytes[start + index] != needle[index] { return false }
        return true
    }

    private static func equals(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], from: Int, to: Int) -> Bool {
        guard to - from == needle.count else { return false }
        for index in 0..<needle.count where bytes[from + index] != needle[index] { return false }
        return true
    }
}

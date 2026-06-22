import Foundation
import CoreServices

/// Watches a worktree subtree for file changes and fires `onChange` on the main
/// actor whenever a file under it is written — so the editor window can recompute
/// the blue "Agent edits" diff and the tree markers as the agent works.
///
/// Uses the CoreServices FSEvents API: recursive, unlike a `DispatchSource` which
/// watches a single descriptor. FSEvents' own `latency` coalesces bursts, so it
/// doubles as the debounce. Writes under `.git/` are ignored to skip commit churn.
final class WorktreeWatcher {
    private let path: String
    private let latency: TimeInterval
    private let onChange: @MainActor @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.lgtm.worktree-watcher")

    init(root: URL, latency: TimeInterval = 0.75,
         onChange: @escaping @MainActor @Sendable () -> Void) {
        self.path = root.standardizedFileURL.path
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
        // @convention(c): captures nothing; reaches `self` through `context.info`.
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: paths)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Called on `queue` for each coalesced batch. Skip batches that are purely
    /// `.git` internals (commits, index writes); fire for real working-tree edits.
    private func handle(paths: [String]) {
        let relevant = paths.contains { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }
        guard relevant else { return }
        let cb = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { cb() } }
    }

    deinit { stop() }
}

import Foundation
import Darwin   // open/close + O_EVTONLY for the marker watcher

// MARK: - Attention watcher
//
// Watches the marker file notify-attention.sh writes when Claude Code is
// blocked waiting on the user. A kqueue-backed DispatchSource fires the moment
// the file changes, so the alert is effectively instant rather than waiting on
// the 10s poll. The hook rewrites the file in place (`> file`), keeping the
// inode, so a plain `.write`/`.extend` is the common path; `.delete`/`.rename`
// (an atomic replace, or the file going away) re-arm the watch on a fresh fd.
//
// @unchecked Sendable: every member is touched only from `queue`, a single
// serial queue, so the mutable `source` is never raced — but that confinement
// is a runtime invariant the compiler can't see, hence unchecked.
final class AttentionWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.jp7.awakebar.attention")
    private var source: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() { queue.async { [weak self] in self?.arm() } }

    private func arm() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Not created yet (the hook hasn't fired). Retry; one cheap syscall.
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.rearm()
            } else {
                self.onChange()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        // The file exists now: check it once, both to catch a write that landed
        // between open() and resume(), and to surface a marker that was written
        // while no watch was armed (e.g. just after launch).
        onChange()
    }

    private func rearm() {
        source?.cancel()   // the cancel handler closes the old fd
        source = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
    }
}

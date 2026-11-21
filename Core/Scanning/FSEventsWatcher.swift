import CoreServices
import Foundation

struct IndexedFileEvent: Sendable {
    let path: String
    let flags: UInt32
    let fileID: UInt64?

    static let unreliable = Self(path: "", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), fileID: nil)

    var invalidatesLivePairing: Bool {
        flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                        kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped |
                        kFSEventStreamEventFlagRootChanged) != 0
    }
    var isDirectFileRename: Bool {
        flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 &&
        flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
    }
}

struct IndexedFileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let volume: Data
    let resource: Data

    // Prove each parent is materialized and not a symlink before asking
    // about its child; a dataless directory may hydrate merely on descent.
    private static func hasSafeRecordedParents(_ file: URL, inside root: URL) -> Bool {
        guard let relative = RecoveryScope.recordedRelativePath(file: file, inside: root,
                                                               checkResolvedPaths: false) else { return false }
        var parent = root.standardizedFileURL
        func isReadyDirectory(_ url: URL) -> Bool {
            var entry = stat()
            return lstat(url.path, &entry) == 0 &&
                (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
                entry.st_flags & UInt32(SF_DATALESS) == 0
        }
        guard isReadyDirectory(parent),
              parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path
        else { return false }
        for component in relative.split(separator: "/").dropLast() {
            parent.appendPathComponent(String(component), isDirectory: true)
            guard isReadyDirectory(parent) else { return false }
        }
        return true
    }

    /// Only an adjunct to both live rename halves and matching destination identity.
    /// ENOENT with unknown provider status is not persistent evidence of missing media.
    static func oldEntryAbsentForLiveMove(at file: URL, inside root: URL) -> Bool {
        guard hasSafeRecordedParents(file, inside: root) else { return false }
        var entry = stat()
        guard lstat(file.path, &entry) != 0, errno == ENOENT else { return false }
        return !VideoCloudReadiness.isPlaceholder(at: file)
    }

    static func read(at file: URL, inside root: URL) -> IndexedFileIdentity? {
        guard hasSafeRecordedParents(file, inside: root) else { return nil }
        var node = stat()
        guard lstat(file.path, &node) == 0, (node.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              node.st_flags & UInt32(SF_DATALESS) == 0,
              !VideoCloudReadiness.isPlaceholder(at: file),
              let metadata = try? file.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey, .isAliasFileKey]),
              metadata.isAliasFile != true,
              let volume = metadata.volumeIdentifier as? Data, let resource = metadata.fileResourceIdentifier as? Data
        else { return nil }
        return .init(device: node.st_dev, inode: node.st_ino, volume: volume, resource: resource)
    }
}

struct IndexedRelocationHints {
    private var pending: [IndexedFileEvent] = []
    private var deadline: ContinuousClock.Instant?
    private var holdingForRecovery = false

    mutating func holdForRecovery(at now: ContinuousClock.Instant) {
        _ = retained(at: now)
        holdingForRecovery = true
    }

    mutating func resumeAfterRecovery(at now: ContinuousClock.Instant) {
        guard holdingForRecovery else { return }
        holdingForRecovery = false
        deadline = pending.isEmpty ? nil : now.advanced(by: .seconds(4))
    }

    mutating func append(_ batch: [IndexedFileEvent], now: ContinuousClock.Instant) {
        _ = retained(at: now)
        if batch.contains(where: \.invalidatesLivePairing) || pending.count + batch.count > 1024 {
            pending = [.unreliable]
            deadline = now.advanced(by: .seconds(4))
        } else if !pending.contains(where: \.invalidatesLivePairing) {
            if pending.isEmpty { deadline = now.advanced(by: .seconds(4)) }
            pending.append(contentsOf: batch)
        }
    }

    mutating func retained(at now: ContinuousClock.Instant) -> [IndexedFileEvent] {
        if !holdingForRecovery, let deadline, now >= deadline {
            pending.removeAll()
            self.deadline = nil
        }
        return pending
    }
}

enum IndexedMoveHint {
    static func destination(
        events: [IndexedFileEvent], oldPath: String, identity: IndexedFileIdentity, root: URL,
        currentIdentity: (URL) -> IndexedFileIdentity?
    ) -> URL? {
        guard !events.contains(where: \.invalidatesLivePairing),
              events.contains(where: { $0.path == oldPath && $0.fileID == identity.inode && $0.isDirectFileRename })
        else { return nil }
        let candidates = Set(events.filter {
            $0.path != oldPath && $0.fileID == identity.inode && $0.isDirectFileRename
        }.map(\.path))
        guard candidates.count == 1, let path = candidates.first, path.hasPrefix("/"),
              !events.contains(where: { $0.path == path && $0.fileID != identity.inode }) else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.path == path, VideoFileDiscovery.isSupportedVideoURL(file),
              RecoveryScope.recordedRelativePath(file: file, inside: root, checkResolvedPaths: false) != nil,
              currentIdentity(file) == identity else { return nil }
        return file
    }
}

final class FSEventsWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.larryisthere.tagivy.fsevents", qos: .utility)
    private let onChange: @Sendable ([IndexedFileEvent]) -> Void
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable ([IndexedFileEvent]) -> Void) {
        self.onChange = onChange
    }

    func start(watching rootURL: URL) {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagUseExtendedData
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, contextInfo, eventCount, paths, flags, _ in
                guard eventCount > 0, let contextInfo else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
                guard eventCount <= 1024 else {
                    watcher.onChange([.unreliable])
                    return
                }
                let values = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
                guard CFArrayGetCount(values) == eventCount else { watcher.onChange([.unreliable]); return }
                let events = (0..<eventCount).compactMap { index -> IndexedFileEvent? in
                    guard let item = CFArrayGetValueAtIndex(values, index) else { return nil }
                    let raw = Unmanaged<CFTypeRef>.fromOpaque(item).takeUnretainedValue()
                    guard CFGetTypeID(raw) == CFDictionaryGetTypeID() else { return nil }
                    let event = Unmanaged<NSDictionary>.fromOpaque(item).takeUnretainedValue()
                    guard let path = event["path"] as? String else { return nil }
                    return IndexedFileEvent(path: path, flags: flags[index],
                        fileID: (event["fileID"] as? NSNumber)?.uint64Value)
                }
                watcher.onChange(events.count == eventCount ? events : [.unreliable])
            },
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) == false { stop() }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

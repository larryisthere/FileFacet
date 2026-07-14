import CoreServices
import Foundation

final class FSEventsWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.larryisthere.video-tag-manager.fsevents", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable () -> Void) {
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
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, contextInfo, eventCount, _, _, _ in
                guard eventCount > 0, let contextInfo else { return }
                Unmanaged<FSEventsWatcher>.fromOpaque(contextInfo).takeUnretainedValue().onChange()
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

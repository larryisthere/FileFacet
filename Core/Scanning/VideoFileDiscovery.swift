import Foundation

enum VideoImportRootKind: Equatable, Sendable {
    case videoFile
    case directory
}

struct VideoImportRoot: Equatable, Sendable {
    let url: URL
    let kind: VideoImportRootKind
}

struct VideoImportPlan: Equatable, Sendable {
    let acceptedRoots: [VideoImportRoot]
    let roots: [VideoImportRoot]

    var acceptedInputCount: Int { acceptedRoots.count }
    var fileCount: Int { acceptedRoots.filter { $0.kind == .videoFile }.count }
    var folderCount: Int { acceptedRoots.filter { $0.kind == .directory }.count }
    var collapsedInputCount: Int { acceptedRoots.count - roots.count }
}

protocol VideoFileDiscovering: Sendable {
    func discoverVideoResult(at rootURL: URL) throws -> VideoDiscoveryResult
}

extension VideoFileDiscovering {
    func discoverVideos(at rootURL: URL) throws -> [DiscoveredVideo] {
        try discoverVideoResult(at: rootURL).videos
    }
}

struct VideoDiscoveryResult: Equatable, Sendable {
    let videos: [DiscoveredVideo]
    let failedCount: Int
}

struct VideoFileDiscovery: VideoFileDiscovering {
    static let supportedExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "webm",
    ]

    static func isSupportedVideoURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func importRoot(for url: URL) -> VideoImportRoot? {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.isFileURL,
              let values = try? standardizedURL.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isDirectoryKey,
                  .isSymbolicLinkKey,
                  .isPackageKey,
              ]),
              values.isSymbolicLink != true,
              values.isPackage != true else { return nil }
        if values.isDirectory == true {
            return VideoImportRoot(url: standardizedURL, kind: .directory)
        }
        guard values.isRegularFile == true, isSupportedVideoURL(standardizedURL) else { return nil }
        return VideoImportRoot(url: standardizedURL, kind: .videoFile)
    }

    static func importPlan(for urls: [URL]) -> VideoImportPlan {
        let acceptedRoots = urls.compactMap(importRoot)
        var seenPaths = Set<String>()
        let uniqueRoots = acceptedRoots.filter { root in
            seenPaths.insert(root.url.path).inserted
        }
        let roots = uniqueRoots.filter { candidate in
            uniqueRoots.contains { possibleParent in
                guard possibleParent.kind == .directory,
                      possibleParent.url != candidate.url else { return false }
                let parentComponents = possibleParent.url.pathComponents
                let candidateComponents = candidate.url.pathComponents
                return parentComponents.count < candidateComponents.count
                    && candidateComponents.starts(with: parentComponents)
            } == false
        }
        return VideoImportPlan(acceptedRoots: acceptedRoots, roots: roots)
    }

    func discoverVideoResult(at rootURL: URL) throws -> VideoDiscoveryResult {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .volumeIdentifierKey,
            .fileResourceIdentifierKey,
            .tagNamesKey,
        ]
        let rootTypeValues = try rootURL.resourceValues(forKeys: [.isRegularFileKey])
        if rootTypeValues.isRegularFile == true {
            guard Self.isSupportedVideoURL(rootURL) else {
                return VideoDiscoveryResult(videos: [], failedCount: 0)
            }
            let rootValues = try rootURL.resourceValues(forKeys: Set(keys))
            return VideoDiscoveryResult(
                videos: [discoveredVideo(
                    at: rootURL,
                    relativePath: "",
                    values: rootValues
                )],
                failedCount: 0
            )
        }

        let enumerationStatus = EnumerationStatus()
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationStatus.recordFailure()
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let rootComponents = rootURL.standardizedFileURL.pathComponents
        var discovered: [DiscoveredVideo] = []

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: Set(keys))
            } catch {
                enumerationStatus.recordFailure()
                continue
            }

            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }

            let fileExtension = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(fileExtension) else { continue }

            let fileComponents = fileURL.standardizedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else { continue }
            let relativePath = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard relativePath.isEmpty == false else { continue }

            discovered.append(discoveredVideo(
                at: fileURL,
                relativePath: relativePath,
                values: values
            ))
        }

        return VideoDiscoveryResult(
            videos: discovered.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            },
            failedCount: enumerationStatus.failedCount
        )
    }

    private func discoveredVideo(
        at fileURL: URL,
        relativePath: String,
        values: URLResourceValues
    ) -> DiscoveredVideo {
        DiscoveredVideo(
            relativePath: relativePath,
            filename: fileURL.lastPathComponent,
            fileExtension: fileURL.pathExtension.lowercased(),
            fileSize: Int64(values.fileSize ?? 0),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            volumeIdentifier: encodeIdentifier(values.volumeIdentifier),
            fileResourceIdentifier: encodeIdentifier(values.fileResourceIdentifier),
            finderTags: (values.tagNames ?? []).filter { $0.isEmpty == false },
            fallbackPathKey: fallbackPathKey(for: fileURL)
        )
    }

    private func encodeIdentifier(_ value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let data = value as? NSData { return data as Data }
        if let string = value as? String { return Data(string.utf8) }
        if let number = value as? NSNumber { return Data(number.stringValue.utf8) }
        return nil
    }

}

private final class EnumerationStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0

    var failedCount: Int {
        lock.withLock { failures }
    }

    func recordFailure() {
        lock.withLock { failures += 1 }
    }
}

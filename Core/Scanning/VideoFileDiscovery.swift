import Foundation

protocol VideoFileDiscovering: Sendable {
    func discoverVideos(at rootURL: URL) throws -> [DiscoveredVideo]
}

struct VideoFileDiscovery: VideoFileDiscovering {
    private static let supportedExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "webm",
    ]

    func discoverVideos(at rootURL: URL) throws -> [DiscoveredVideo] {
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
        ]
        let enumerationStatus = EnumerationStatus()
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationStatus.didFail = true
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let rootComponents = rootURL.standardizedFileURL.pathComponents
        var discovered: [DiscoveredVideo] = []

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(forKeys: Set(keys))

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

            discovered.append(
                DiscoveredVideo(
                    relativePath: relativePath,
                    filename: fileURL.lastPathComponent,
                    fileExtension: fileExtension,
                    fileSize: Int64(values.fileSize ?? 0),
                    creationDate: values.creationDate,
                    modificationDate: values.contentModificationDate,
                    volumeIdentifier: encodeIdentifier(values.volumeIdentifier),
                    fileResourceIdentifier: encodeIdentifier(values.fileResourceIdentifier)
                )
            )
        }

        guard enumerationStatus.didFail == false else {
            throw CocoaError(.fileReadUnknown)
        }

        return discovered.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
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
    var didFail = false
}

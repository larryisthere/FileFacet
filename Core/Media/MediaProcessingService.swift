import AVFoundation
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct MediaProcessingResult: Sendable {
    let duration: Double?
    let width: Int?
    let height: Int?
    let thumbnailID: String?
    let metadataStatus: VideoRecord.ProcessingStatus
    let thumbnailStatus: VideoRecord.ProcessingStatus
}

actor MediaProcessingService {
    private let thumbnailDirectory: URL
    private let maximumCacheBytes: Int64

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        maximumCacheBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    ) throws {
        let cacheDirectory = try cacheDirectory ?? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        thumbnailDirectory = cacheDirectory
            .appendingPathComponent(AppConfiguration.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        self.maximumCacheBytes = maximumCacheBytes
        try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try Self.prune(directory: thumbnailDirectory, maximumBytes: maximumCacheBytes, fileManager: fileManager)
    }

    func process(video: VideoRecord, fileURL: URL) async -> MediaProcessingResult {
        let asset = AVURLAsset(url: fileURL)
        var duration: Double?
        var width: Int?
        var height: Int?
        var metadataStatus: VideoRecord.ProcessingStatus = .failed

        do {
            let assetDuration = try await asset.load(.duration)
            if assetDuration.isNumeric {
                duration = max(0, assetDuration.seconds)
            }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformedSize = naturalSize.applying(transform)
                width = Int(abs(transformedSize.width).rounded())
                height = Int(abs(transformedSize.height).rounded())
            }
            metadataStatus = .completed
        } catch {
            metadataStatus = .failed
        }

        do {
            try Task.checkCancellation()
            let thumbnailID = video.id
            let destinationURL = thumbnailURL(for: thumbnailID)
            let thumbnailExists = FileManager.default.fileExists(atPath: destinationURL.path)
            if video.thumbnailStatus != .completed || thumbnailExists == false {
                let image: CGImage
                do {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 640, height: 360)
                    let requestedTime = CMTime(
                        seconds: min(max(duration ?? 0, 0), 1),
                        preferredTimescale: 600
                    )
                    (image, _) = try await generator.image(at: requestedTime)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logThumbnailFailure(stage: "avfoundation", error: error)
                    do {
                        image = try await generateQuickLookThumbnail(fileURL: fileURL)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        logThumbnailFailure(stage: "quicklook", error: error)
                        throw error
                    }
                }
                if thumbnailExists { try FileManager.default.removeItem(at: destinationURL) }
                try writeJPEG(image, to: destinationURL)
                try Self.prune(
                    directory: thumbnailDirectory,
                    maximumBytes: maximumCacheBytes,
                    fileManager: .default
                )
            }
            return MediaProcessingResult(
                duration: duration,
                width: width,
                height: height,
                thumbnailID: thumbnailID,
                metadataStatus: metadataStatus,
                thumbnailStatus: .completed
            )
        } catch {
            return MediaProcessingResult(
                duration: duration,
                width: width,
                height: height,
                thumbnailID: nil,
                metadataStatus: metadataStatus,
                thumbnailStatus: .failed
            )
        }
    }

    private func generateQuickLookThumbnail(fileURL: URL) async throws -> CGImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 640, height: 360),
            scale: 1,
            representationTypes: .thumbnail
        )
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation.cgImage
    }

    private func logThumbnailFailure(stage: String, error: Error) {
        let error = error as NSError
        AppLogger.library.error(
            "Thumbnail generation failed at \(stage, privacy: .public), domain: \(error.domain, privacy: .public), code: \(error.code, privacy: .public)"
        )
    }

    nonisolated func thumbnailURL(for identifier: String) -> URL {
        thumbnailDirectory.appendingPathComponent(identifier).appendingPathExtension("jpg")
    }

    func pruneCache(fileManager: FileManager = .default) throws {
        try Self.prune(
            directory: thumbnailDirectory,
            maximumBytes: maximumCacheBytes,
            fileManager: fileManager
        )
    }

    func removeThumbnails(identifiers: [String], fileManager: FileManager = .default) throws {
        for identifier in Set(identifiers) {
            let url = thumbnailURL(for: identifier)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func removeUnreferencedThumbnails(
        retaining identifiers: Set<String>,
        fileManager: FileManager = .default
    ) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: thumbnailDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension.lowercased() == "jpg" {
            guard identifiers.contains(url.deletingPathExtension().lastPathComponent) == false else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private static func prune(directory: URL, maximumBytes: Int64, fileManager: FileManager) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var entries = try urls.map { url -> (url: URL, size: Int64, date: Date) in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        guard totalBytes > maximumBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where totalBytes > maximumBytes {
            try fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

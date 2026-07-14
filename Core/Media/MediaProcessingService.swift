import AVFoundation
import Foundation
import ImageIO
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

    init(fileManager: FileManager = .default) throws {
        let cacheDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        thumbnailDirectory = cacheDirectory
            .appendingPathComponent(AppConfiguration.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
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
            if FileManager.default.fileExists(atPath: destinationURL.path) == false {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                let requestedTime = CMTime(seconds: min(max(duration ?? 0, 0), 1), preferredTimescale: 600)
                let (image, _) = try await generator.image(at: requestedTime)
                try writeJPEG(image, to: destinationURL)
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

    nonisolated func thumbnailURL(for identifier: String) -> URL {
        thumbnailDirectory.appendingPathComponent(identifier).appendingPathExtension("jpg")
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

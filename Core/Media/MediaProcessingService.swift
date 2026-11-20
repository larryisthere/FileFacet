@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ImageIO
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers

struct MediaProcessingResult: Sendable {
    let duration: Double?
    let width: Int?
    let height: Int?
    let thumbnailID: String?
    let generatedThumbnailID: String?
    let metadataStatus: VideoRecord.ProcessingStatus
    let thumbnailStatus: VideoRecord.ProcessingStatus
    let mediaSourceInfo: MediaSourceInfo?
    let contentFingerprint: Data?

    init(
        duration: Double?,
        width: Int?,
        height: Int?,
        thumbnailID: String?,
        metadataStatus: VideoRecord.ProcessingStatus,
        thumbnailStatus: VideoRecord.ProcessingStatus,
        mediaSourceInfo: MediaSourceInfo? = nil,
        contentFingerprint: Data? = nil,
        generatedThumbnailID: String? = nil
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.thumbnailID = thumbnailID
        self.generatedThumbnailID = generatedThumbnailID
        self.metadataStatus = metadataStatus
        self.thumbnailStatus = thumbnailStatus
        self.mediaSourceInfo = mediaSourceInfo
        self.contentFingerprint = contentFingerprint
    }
}

struct VideoMediaInspection: Sendable {
    let duration: Double?
    let width: Int?
    let height: Int?
}

actor MediaProcessingService {
    private let thumbnailDirectory: URL
    private let maximumCacheBytes: Int64
    private var lastPrunedAt = Date()

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

    func hasLocalMedia(at url: URL) -> Bool {
        !VideoCloudReadiness.isPlaceholder(at: url)
    }

    func needsProcessing(_ video: VideoRecord) -> Bool {
        if video.contentFingerprint == nil || video.metadataStatus == .pending || video.thumbnailStatus == .pending { return true }
        guard video.thumbnailStatus == .completed, let id = video.thumbnailID else { return false }
        return !FileManager.default.fileExists(atPath: thumbnailURL(for: id).path)
    }

    func process(video: VideoRecord, fileURL: URL) async -> MediaProcessingResult {
        let asset = AVURLAsset(url: fileURL)
        // A missing JPEG does not invalidate previously established content identity.
        let fingerprint = video.contentFingerprint ?? (try? contentFingerprint(for: fileURL))
        var duration = video.duration
        var width = video.width
        var height = video.height
        var mediaSourceInfo = video.mediaSourceInfo
        var metadataStatus = video.metadataStatus

        if video.metadataStatus != .completed {
            mediaSourceInfo = await loadMediaSourceInfo(asset: asset, fileURL: fileURL)
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
        }

        var generatedThumbnailID: String?
        do {
            try Task.checkCancellation()
            var thumbnailID = video.thumbnailID
            let thumbnailExists = thumbnailID.map { FileManager.default.fileExists(atPath: thumbnailURL(for: $0).path) } ?? false
            if video.thumbnailStatus != .completed || !thumbnailExists {
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
                try Task.checkCancellation()
                let newID = UUID().uuidString
                generatedThumbnailID = newID
                try writeJPEG(image, to: thumbnailURL(for: newID))
                thumbnailID = newID
                if Date().timeIntervalSince(lastPrunedAt) >= 60 {
                    try Self.prune(directory: thumbnailDirectory, maximumBytes: maximumCacheBytes, fileManager: .default)
                    lastPrunedAt = Date()
                }
            }
            return MediaProcessingResult(
                duration: duration,
                width: width,
                height: height,
                thumbnailID: thumbnailID,
                metadataStatus: metadataStatus,
                thumbnailStatus: .completed,
                mediaSourceInfo: mediaSourceInfo,
                contentFingerprint: fingerprint,
                generatedThumbnailID: generatedThumbnailID
            )
        } catch {
            if let generatedThumbnailID { try? FileManager.default.removeItem(at: thumbnailURL(for: generatedThumbnailID)) }
            return MediaProcessingResult(
                duration: duration,
                width: width,
                height: height,
                thumbnailID: nil,
                metadataStatus: metadataStatus,
                thumbnailStatus: .failed,
                mediaSourceInfo: mediaSourceInfo,
                contentFingerprint: fingerprint
            )
        }
    }

    func inspectVideo(fileURL: URL) async throws -> VideoMediaInspection {
        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let durationValue = try await asset.load(.duration)
        let duration = durationValue.isNumeric ? max(0, durationValue.seconds) : nil
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        let width = Int(abs(transformedSize.width).rounded())
        let height = Int(abs(transformedSize.height).rounded())
        guard width > 0, height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return VideoMediaInspection(
            duration: duration,
            width: width,
            height: height
        )
    }

    private func loadMediaSourceInfo(asset: AVAsset, fileURL: URL) async -> MediaSourceInfo {
        let container = containerInfo(fileURL: fileURL)
        let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        var videoDescription: CMFormatDescription?
        var videoTag: String?
        var videoCodec: String?
        var videoProfile: String?
        var bitDepth: Int?
        var colorTransfer: String?
        var colorPrimaries: String?
        var frameRate: Double?
        var videoBitRate: Double?
        var rotationDegrees: Double?

        if let videoTrack {
            videoDescription = try? await videoTrack.load(.formatDescriptions).first
            if let videoDescription {
                videoTag = sampleEntryTag(videoDescription)
                    ?? fourCharacterCode(CMFormatDescriptionGetMediaSubType(videoDescription))
                videoCodec = videoCodecName(tag: videoTag)
                let configuration = videoConfiguration(description: videoDescription, tag: videoTag)
                videoProfile = configuration.profile
                bitDepth = configuration.bitDepth
                colorTransfer = formatDescriptionString(
                    videoDescription,
                    key: kCMFormatDescriptionExtension_TransferFunction
                )
                colorPrimaries = formatDescriptionString(
                    videoDescription,
                    key: kCMFormatDescriptionExtension_ColorPrimaries
                )
            }
            if let value = try? await videoTrack.load(.nominalFrameRate), value > 0 {
                frameRate = Double(value)
            }
            if let value = try? await videoTrack.load(.estimatedDataRate), value > 0 {
                videoBitRate = Double(value)
            }
            if let transform = try? await videoTrack.load(.preferredTransform) {
                rotationDegrees = normalizedRotationDegrees(transform)
            }
        }

        var audioTag: String?
        var audioCodec: String?
        var audioProfile: String?
        var audioChannels: Int?
        var audioSampleRate: Double?
        var audioBitRate: Double?

        if let audioTrack {
            if let audioDescription = try? await audioTrack.load(.formatDescriptions).first {
                audioTag = sampleEntryTag(audioDescription)
                    ?? fourCharacterCode(CMFormatDescriptionGetMediaSubType(audioDescription))
                if let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee {
                    audioCodec = audioCodecName(formatID: basicDescription.mFormatID, tag: audioTag)
                    audioProfile = audioProfileName(formatID: basicDescription.mFormatID)
                    if basicDescription.mChannelsPerFrame > 0 {
                        audioChannels = Int(basicDescription.mChannelsPerFrame)
                    }
                    if basicDescription.mSampleRate > 0 {
                        audioSampleRate = basicDescription.mSampleRate
                    }
                } else {
                    audioCodec = audioCodecName(formatID: 0, tag: audioTag)
                }
            }
            if let value = try? await audioTrack.load(.estimatedDataRate), value > 0 {
                audioBitRate = Double(value)
            }
        }

        return MediaSourceInfo(
            containerFormat: container.format,
            containerBrand: container.brand,
            videoCodec: videoCodec,
            videoCodecTag: videoTag,
            videoProfile: videoProfile,
            frameRate: frameRate,
            videoBitRate: videoBitRate,
            bitDepth: bitDepth,
            colorTransfer: colorTransfer,
            colorPrimaries: colorPrimaries,
            rotationDegrees: rotationDegrees,
            audioCodec: audioCodec,
            audioCodecTag: audioTag,
            audioProfile: audioProfile,
            audioChannels: audioChannels,
            audioSampleRate: audioSampleRate,
            audioBitRate: audioBitRate
        )
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

    private func containerInfo(fileURL: URL) -> (format: String?, brand: String?) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_096), data.isEmpty == false else {
            return (nil, nil)
        }

        if let brand = isoBaseMediaBrand(in: data) {
            return (brand == "qt  " ? "QuickTime" : "MPEG-4", brand)
        }
        if data.count >= 12,
           String(data: data[0..<4], encoding: .ascii) == "RIFF",
           String(data: data[8..<12], encoding: .ascii) == "AVI " {
            return ("AVI", nil)
        }
        if data.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) {
            let header = String(decoding: data, as: UTF8.self).lowercased()
            if header.contains("webm") { return ("WebM", nil) }
            if header.contains("matroska") { return ("Matroska", nil) }
            return ("Matroska / WebM", nil)
        }
        return (nil, nil)
    }

    private func isoBaseMediaBrand(in data: Data) -> String? {
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = Int(readUInt32(data, at: offset))
            guard let type = asciiFourCharacterCode(data, offset: offset + 4) else { return nil }
            let headerSize: Int
            let boxSize: Int
            if size32 == 1 {
                guard offset + 16 <= data.count else { return nil }
                let extendedSize = readUInt64(data, at: offset + 8)
                guard extendedSize <= UInt64(Int.max) else { return nil }
                headerSize = 16
                boxSize = Int(extendedSize)
            } else {
                headerSize = 8
                boxSize = size32
            }
            guard boxSize >= headerSize else { return nil }
            if type == "ftyp" {
                guard offset + headerSize + 4 <= data.count else { return nil }
                return asciiFourCharacterCode(data, offset: offset + headerSize)
            }
            if boxSize == 0 || offset + boxSize > data.count { return nil }
            offset += boxSize
        }
        return nil
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func asciiFourCharacterCode(_ data: Data, offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 4)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    private func fourCharacterCode(_ value: FourCharCode) -> String? {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    private func sampleEntryTag(_ description: CMFormatDescription) -> String? {
        guard let data = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry
        ) as? Data, data.count >= 8 else {
            return nil
        }
        return asciiFourCharacterCode(data, offset: 4)
    }

    private func videoCodecName(tag: String?) -> String? {
        switch tag {
        case "avc1", "avc3": "H.264 / AVC"
        case "hvc1", "hev1": "HEVC / H.265"
        case "av01": "AV1"
        case "vp09": "VP9"
        case "mp4v": "MPEG-4 Visual"
        case "jpeg", "mjpg": "Motion JPEG"
        case "ap4h": "Apple ProRes 4444"
        case "apch": "Apple ProRes 422 HQ"
        case "apcn": "Apple ProRes 422"
        case "apcs": "Apple ProRes 422 LT"
        case "apco": "Apple ProRes 422 Proxy"
        default: tag
        }
    }

    private func audioCodecName(formatID: AudioFormatID, tag: String?) -> String? {
        switch formatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            "AAC"
        case kAudioFormatAC3: "Dolby Digital / AC-3"
        case kAudioFormatEnhancedAC3: "Dolby Digital Plus / E-AC-3"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAppleLossless: "Apple Lossless"
        case kAudioFormatLinearPCM: "Linear PCM"
        default:
            switch tag {
            case "mp4a": "AAC"
            case "ac-3": "Dolby Digital / AC-3"
            case "ec-3": "Dolby Digital Plus / E-AC-3"
            case "Opus": "Opus"
            default: tag
            }
        }
    }

    private func audioProfileName(formatID: AudioFormatID) -> String? {
        switch formatID {
        case kAudioFormatMPEG4AAC_HE: "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: "HE-AAC v2"
        case kAudioFormatMPEG4AAC_LD: "AAC-LD"
        case kAudioFormatMPEG4AAC_ELD: "AAC-ELD"
        case kAudioFormatMPEG4AAC: "AAC-LC"
        default: nil
        }
    }

    private func videoConfiguration(
        description: CMFormatDescription,
        tag: String?
    ) -> (profile: String?, bitDepth: Int?) {
        guard let atoms = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else {
            return (nil, nil)
        }
        switch tag {
        case "avc1", "avc3":
            guard let data = atoms["avcC"] as? Data, data.count >= 4 else { return (nil, nil) }
            let profileName = switch data[1] {
            case 66: "Baseline"
            case 77: "Main"
            case 88: "Extended"
            case 100: "High"
            case 110: "High 10"
            case 122: "High 4:2:2"
            case 144: "High 4:4:4"
            default: "Profile \(data[1])"
            }
            return ("\(profileName) · Level \(levelDescription(Int(data[3]), divisor: 10))", data[1] == 110 ? 10 : 8)
        case "hvc1", "hev1":
            guard let data = atoms["hvcC"] as? Data, data.count >= 19 else { return (nil, nil) }
            let profileID = data[1] & 0x1f
            let profileName = switch profileID {
            case 1: "Main"
            case 2: "Main 10"
            case 3: "Main Still Picture"
            default: "Profile \(profileID)"
            }
            let bitDepth = 8 + Int(data[17] & 0x07)
            return ("\(profileName) · Level \(levelDescription(Int(data[12]), divisor: 30))", bitDepth)
        case "av01":
            guard let data = atoms["av1C"] as? Data, data.count >= 3 else { return (nil, nil) }
            let profileID = (data[1] >> 5) & 0x07
            let profileName = switch profileID {
            case 0: "Main"
            case 1: "High"
            case 2: "Professional"
            default: "Profile \(profileID)"
            }
            let bitDepth = (data[2] & 0x20) != 0 ? 12 : ((data[2] & 0x40) != 0 ? 10 : 8)
            return (profileName, bitDepth)
        default:
            return (nil, nil)
        }
    }

    private func levelDescription(_ value: Int, divisor: Int) -> String {
        let major = value / divisor
        let remainder = value % divisor
        guard remainder > 0 else { return "\(major).0" }
        let decimal = Int((Double(remainder) / Double(divisor) * 10).rounded())
        return "\(major).\(decimal)"
    }

    private func formatDescriptionString(_ description: CMFormatDescription, key: CFString) -> String? {
        CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
    }

    private func normalizedRotationDegrees(_ transform: CGAffineTransform) -> Double {
        var degrees = atan2(transform.b, transform.a) * 180 / .pi
        degrees.formTruncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        let rounded = degrees.rounded()
        return rounded == 360 ? 0 : rounded
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


// Reads URL metadata only; never opens or requests download of the media file.
enum VideoCloudReadiness {
    static func isPlaceholder(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        var metadata = stat()
        let dataless = lstat(url.path, &metadata) == 0 && (metadata.st_flags & UInt32(SF_DATALESS)) != 0
        return isPlaceholder(status: values?.ubiquitousItemDownloadingStatus, dataless: dataless)
    }

    static func isPlaceholder(status: URLUbiquitousItemDownloadingStatus?, dataless: Bool) -> Bool {
        dataless || status == .notDownloaded
    }
}

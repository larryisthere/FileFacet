import Foundation

struct MediaSourceInfo: Codable, Equatable, Sendable {
    let containerFormat: String?
    let containerBrand: String?
    let videoCodec: String?
    let videoCodecTag: String?
    let videoProfile: String?
    let frameRate: Double?
    let videoBitRate: Double?
    let bitDepth: Int?
    let colorTransfer: String?
    let colorPrimaries: String?
    let rotationDegrees: Double?
    let audioCodec: String?
    let audioCodecTag: String?
    let audioProfile: String?
    let audioChannels: Int?
    let audioSampleRate: Double?
    let audioBitRate: Double?

    init(
        containerFormat: String? = nil,
        containerBrand: String? = nil,
        videoCodec: String? = nil,
        videoCodecTag: String? = nil,
        videoProfile: String? = nil,
        frameRate: Double? = nil,
        videoBitRate: Double? = nil,
        bitDepth: Int? = nil,
        colorTransfer: String? = nil,
        colorPrimaries: String? = nil,
        rotationDegrees: Double? = nil,
        audioCodec: String? = nil,
        audioCodecTag: String? = nil,
        audioProfile: String? = nil,
        audioChannels: Int? = nil,
        audioSampleRate: Double? = nil,
        audioBitRate: Double? = nil
    ) {
        self.containerFormat = containerFormat
        self.containerBrand = containerBrand
        self.videoCodec = videoCodec
        self.videoCodecTag = videoCodecTag
        self.videoProfile = videoProfile
        self.frameRate = frameRate
        self.videoBitRate = videoBitRate
        self.bitDepth = bitDepth
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.rotationDegrees = rotationDegrees
        self.audioCodec = audioCodec
        self.audioCodecTag = audioCodecTag
        self.audioProfile = audioProfile
        self.audioChannels = audioChannels
        self.audioSampleRate = audioSampleRate
        self.audioBitRate = audioBitRate
    }
}

struct VideoRecord: Equatable, Identifiable, Sendable {
    enum Availability: String, Sendable {
        case available
        case offline
        case unavailable
    }

    enum UnavailableReason: Sendable {
        case missingFromKnownLocation
        case accessLost
    }

    enum ProcessingStatus: String, Sendable {
        case pending
        case completed
        case failed
    }

    let id: String
    let libraryID: String
    let relativePath: String
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let duration: Double?
    let width: Int?
    let height: Int?
    let thumbnailID: String?
    let metadataStatus: ProcessingStatus
    let thumbnailStatus: ProcessingStatus
    let firstIndexedAt: Date
    let availability: Availability
    let unavailableReason: UnavailableReason?
    let invalidatedAt: Date?
    let mediaSourceInfo: MediaSourceInfo?
    let contentFingerprint: Data?
    let isCloudPlaceholder: Bool

    init(
        id: String,
        libraryID: String,
        relativePath: String,
        filename: String,
        fileExtension: String,
        fileSize: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        duration: Double?,
        width: Int?,
        height: Int?,
        thumbnailID: String?,
        metadataStatus: ProcessingStatus,
        thumbnailStatus: ProcessingStatus,
        firstIndexedAt: Date,
        availability: Availability,
        unavailableReason: UnavailableReason? = nil,
        invalidatedAt: Date? = nil,
        mediaSourceInfo: MediaSourceInfo? = nil,
        contentFingerprint: Data? = nil,
        isCloudPlaceholder: Bool = false
    ) {
        self.id = id
        self.libraryID = libraryID
        self.relativePath = relativePath
        self.filename = filename
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.duration = duration
        self.width = width
        self.height = height
        self.thumbnailID = thumbnailID
        self.metadataStatus = metadataStatus
        self.thumbnailStatus = thumbnailStatus
        self.firstIndexedAt = firstIndexedAt
        self.availability = availability
        self.unavailableReason = unavailableReason
        self.invalidatedAt = invalidatedAt
        self.mediaSourceInfo = mediaSourceInfo
        self.contentFingerprint = contentFingerprint
        self.isCloudPlaceholder = isCloudPlaceholder
    }

    func withAvailability(
        _ availability: Availability,
        unavailableReason: UnavailableReason? = nil,
        isCloudPlaceholder: Bool = false
    ) -> VideoRecord {
        VideoRecord(
            id: id,
            libraryID: libraryID,
            relativePath: relativePath,
            filename: filename,
            fileExtension: fileExtension,
            fileSize: fileSize,
            creationDate: creationDate,
            modificationDate: modificationDate,
            duration: duration,
            width: width,
            height: height,
            thumbnailID: thumbnailID,
            metadataStatus: metadataStatus,
            thumbnailStatus: thumbnailStatus,
            firstIndexedAt: firstIndexedAt,
            availability: availability,
            unavailableReason: unavailableReason,
            invalidatedAt: invalidatedAt,
            mediaSourceInfo: mediaSourceInfo,
            contentFingerprint: contentFingerprint,
            isCloudPlaceholder: isCloudPlaceholder
        )
    }
}

struct RemovedVideoRecord: Equatable, Sendable {
    let id: String
    let libraryID: String
    let relativePath: String
    let volumeIdentifier: Data?
    let fileResourceIdentifier: Data?
    let contentFingerprint: Data?
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let duration: Double?
    let width: Int?
    let height: Int?
    let thumbnailID: String?
    let metadataStatus: String
    let thumbnailStatus: String
    let availabilityStatus: String
    let firstIndexedAt: Date
    let updatedAt: Date
    let lastSeenScanID: String?
    let finderTagsImportedAt: Date?
    let mediaSourceInfo: MediaSourceInfo?
    let invalidatedAt: Date?

    init(
        id: String,
        libraryID: String,
        relativePath: String,
        volumeIdentifier: Data?,
        fileResourceIdentifier: Data?,
        contentFingerprint: Data? = nil,
        filename: String,
        fileExtension: String,
        fileSize: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        duration: Double?,
        width: Int?,
        height: Int?,
        thumbnailID: String?,
        metadataStatus: String,
        thumbnailStatus: String,
        availabilityStatus: String,
        firstIndexedAt: Date,
        updatedAt: Date,
        lastSeenScanID: String?,
        finderTagsImportedAt: Date?,
        mediaSourceInfo: MediaSourceInfo? = nil,
        invalidatedAt: Date? = nil
    ) {
        self.id = id
        self.libraryID = libraryID
        self.relativePath = relativePath
        self.volumeIdentifier = volumeIdentifier
        self.fileResourceIdentifier = fileResourceIdentifier
        self.contentFingerprint = contentFingerprint
        self.filename = filename
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.duration = duration
        self.width = width
        self.height = height
        self.thumbnailID = thumbnailID
        self.metadataStatus = metadataStatus
        self.thumbnailStatus = thumbnailStatus
        self.availabilityStatus = availabilityStatus
        self.firstIndexedAt = firstIndexedAt
        self.updatedAt = updatedAt
        self.lastSeenScanID = lastSeenScanID
        self.finderTagsImportedAt = finderTagsImportedAt
        self.mediaSourceInfo = mediaSourceInfo
        self.invalidatedAt = invalidatedAt
    }
}

struct RemovedVideoLocation: Equatable, Sendable {
    let videoID: String
    let sourceID: String
    let relativePath: String
    let lastVerifiedAt: Date
    let isAvailable: Bool
    let fallbackPathKey: Data?
    let lastKnownPath: String?
    var requiresRecoveryVerification: Bool = false
}

struct RemovedVideoTagRelation: Equatable, Sendable {
    let videoID: String
    let tagID: String
    let createdAt: Date
}

struct VideoRemovalSnapshot: Equatable, Sendable {
    let videos: [RemovedVideoRecord]
    let locations: [RemovedVideoLocation]
    let tagRelations: [RemovedVideoTagRelation]
}

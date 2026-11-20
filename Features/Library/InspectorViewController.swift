import AppKit

struct InspectorTagDraftSnapshot {
    let states: [String: TagAssignmentState]
    let creations: [TagCreationDraft]
}

enum InspectorBrowsingContext: Equatable {
    case library
    case unavailable
    case scanResults
}

@MainActor
final class InspectorViewController: NSViewController {
    private enum Mode {
        case tags
        case resolve
        case details
    }

    private enum DetailSection: Int, CaseIterable {
        case file
        case video
        case audio

        var title: String {
            switch self {
            case .file: String(localized: .detailSectionFile)
            case .video: String(localized: .detailSectionVideo)
            case .audio: String(localized: .detailSectionAudio)
            }
        }
    }

    private let stack = NSStackView()
    private let contentScrollView = NSScrollView()
    private let contentStack = InspectorContentStackView()
    private let actionContainer = NSStackView()
    private let draftStatusLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var discardButton = NSButton(
        title: String(localized: .actionCancel),
        target: self,
        action: #selector(discardTagChanges)
    )
    private lazy var applyButton = NSButton(
        title: String(localized: .actionApply),
        target: self,
        action: #selector(applyTagChanges)
    )
    private lazy var sectionControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: [
                String(localized: .inspectorTags),
                String(localized: .inspectorDetails),
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeSection(_:))
        )
        control.segmentStyle = .rounded
        control.selectedSegment = 0
        control.setAccessibilityLabel(String(localized: .accessibilityInspectorContent))
        return control
    }()
    private lazy var tagSearchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = String(localized: .tagSearch)
        field.target = self
        field.action = #selector(searchTags(_:))
        field.sendsSearchStringImmediately = true
        field.isHidden = true
        return field
    }()
    private let onApplyTagDraft: ([TagCreationDraft], [String: Bool], [String], @escaping (Bool) -> Void) -> Void
    private let loadTagStates: ([String], @escaping ([String: TagAssignmentState]) -> Void) -> Void
    private let filePath: (VideoRecord) -> String?
    private let offlineSourceName: (VideoRecord) -> String?
    private let onRelinkVideo: (VideoRecord) -> Void
    private let onRemoveVideos: ([String], @escaping (Bool) -> Void) -> Void
    private var selectedVideo: VideoRecord?
    private var selectedVideos: [VideoRecord] = []
    private var scannedCandidates: [ScannedVideoCandidate] = []
    private var tags: [TagRecord] = []
    private var tagStates: [String: TagAssignmentState] = [:]
    private var draftTagStates: [String: TagAssignmentState] = [:]
    private var draftTagCreations: [TagCreationDraft] = []
    private var tagStateVideoIDs: [String] = []
    private var loadedTagOrderIDs: [String] = []
    private var tagStateRequestRevision = 0
    private(set) var isApplyingTagChanges = false
    private var tagSearchText = ""
    private var newTagPopover: NSPopover?
    private var collapsedDetailSections: Set<DetailSection> = []
    private var browsingContext: InspectorBrowsingContext = .library
    private var relinkingVideoID: String?
    var onTagApplicationFinished: ((Bool) -> Void)?
    var onVideoRemoved: ((Int) -> Void)?
    var selectedVideoIDs: [String] { selectedVideos.map(\.id) }
    var hasPendingTagChanges: Bool { pendingTagAssignments.isEmpty == false }

    init(
        onApplyTagDraft: @escaping ([TagCreationDraft], [String: Bool], [String], @escaping (Bool) -> Void) -> Void,
        loadTagStates: @escaping ([String], @escaping ([String: TagAssignmentState]) -> Void) -> Void,
        filePath: @escaping (VideoRecord) -> String?,
        offlineSourceName: @escaping (VideoRecord) -> String?,
        onRelinkVideo: @escaping (VideoRecord) -> Void,
        onRemoveVideos: @escaping ([String], @escaping (Bool) -> Void) -> Void
    ) {
        self.onApplyTagDraft = onApplyTagDraft
        self.loadTagStates = loadTagStates
        self.filePath = filePath
        self.offlineSourceName = offlineSourceName
        self.onRelinkVideo = onRelinkVideo
        self.onRemoveVideos = onRemoveVideos
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        // The scroll document is frame-sized below; an autoresizing height constraint
        // would make fitting-size measurement compress long tag lists into the old frame.
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 9
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false
        contentScrollView.documentView = contentStack
        contentScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configureActionArea()
        stack.addArrangedSubview(sectionControl)
        stack.addArrangedSubview(tagSearchField)
        stack.addArrangedSubview(contentScrollView)
        stack.addArrangedSubview(actionContainer)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            sectionControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tagSearchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
        setSelection([])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateScrollDocumentSize()
    }

    func setSelection(_ videos: [VideoRecord]) {
        let previousVideoIDs = selectedVideos.map(\.id)
        selectedVideos = videos
        selectedVideo = videos.count == 1 ? videos[0] : nil
        if previousVideoIDs != videos.map(\.id) {
            closeNewTagPopover()
            tagStateRequestRevision += 1
            tagStates = [:]
            draftTagStates = [:]
            draftTagCreations = []
            tagStateVideoIDs = []
            loadedTagOrderIDs = []
            isApplyingTagChanges = false
        }
        renderSelection()
        scheduleInitialTagStateLoadIfNeeded()
    }

    func setScannedCandidates(_ candidates: [ScannedVideoCandidate]) {
        scannedCandidates = candidates
        renderSelection()
    }

    func setBrowsingContext(_ context: InspectorBrowsingContext) {
        guard browsingContext != context else { return }
        browsingContext = context
        closeNewTagPopover()
        sectionControl.isHidden = context == .scanResults
        sectionControl.setLabel(
            context == .unavailable
                ? String(localized: "inspector.resolve", defaultValue: "Resolve")
                : String(localized: .inspectorTags),
            forSegment: 0
        )
        sectionControl.selectedSegment = 0
        renderSelection()
        scheduleInitialTagStateLoadIfNeeded()
    }

    func setRelinkingVideoID(_ videoID: String?) {
        guard relinkingVideoID != videoID else { return }
        relinkingVideoID = videoID
        renderSelection()
    }

    func setTags(_ tags: [TagRecord]) {
        self.tags = tags
        renderSelection()
        scheduleInitialTagStateLoadIfNeeded()
    }

    func refreshTagAssignments() {
        let videoIDs = selectedVideos.map(\.id)
        guard mode == .tags,
              videoIDs.isEmpty == false,
              hasPendingTagChanges == false,
              isApplyingTagChanges == false else { return }
        tagStateRequestRevision += 1
        let requestRevision = tagStateRequestRevision
        loadTagStates(videoIDs) { [weak self] states in
            guard let self,
                  self.tagStateRequestRevision == requestRevision,
                  self.selectedVideos.map(\.id) == videoIDs else { return }
            self.tagStates = states
            self.draftTagStates = states
            self.tagStateVideoIDs = videoIDs
            self.loadedTagOrderIDs = self.tags
                .enumerated()
                .sorted { lhs, rhs in
                    let lhsIsSelected = (states[lhs.element.id] ?? .off) != .off
                    let rhsIsSelected = (states[rhs.element.id] ?? .off) != .off
                    if lhsIsSelected != rhsIsSelected {
                        return lhsIsSelected
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element.id)
            self.renderSelection()
        }
    }

    private func renderSelection() {
        loadViewIfNeeded()
        defer {
            updateTagSearchFieldVisibility()
            updateActionArea()
        }
        clearContent()
        contentStack.spacing = mode == .resolve ? 16 : 9
        if browsingContext == .scanResults {
            addScanCandidateDetails(scannedCandidates)
            updateScrollDocumentSize()
            return
        }
        let videos = selectedVideos

        if mode == .resolve {
            addResolveControls(for: videos)
            updateScrollDocumentSize()
            return
        }
        guard videos.isEmpty == false else {
            addSecondaryText(String(localized: .inspectorEmpty))
            updateScrollDocumentSize()
            return
        }
        guard mode == .details else {
            addTagControls()
            updateScrollDocumentSize()
            return
        }
        guard let video = selectedVideo else {
            addPrimaryText(String(localized: .selectionVideoCount(videos.count)))
            let totalBytes = videos.reduce(Int64(0)) { $0 + $1.fileSize }
            addField(
                title: String(localized: .detailTotalSize),
                value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            )
            updateScrollDocumentSize()
            return
        }

        addFilename(video.filename)
        let accessStatus: String
        switch video.accessPresentation {
        case .none:
            accessStatus = String(localized: .detailAccessAvailable)
        case .offline:
            if let sourceName = offlineSourceName(video), sourceName.isEmpty == false {
                accessStatus = String(localized: .detailAccessOfflineNamed(sourceName))
            } else {
                accessStatus = String(localized: .detailAccessOffline)
            }
        case .cloud, .accessNeedsVerification, .unavailable:
            accessStatus = video.accessPresentation.accessibilityLabel ?? String(localized: .detailAccessAvailable)
        }
        let media = video.mediaSourceInfo
        let lastKnownLocation = lastKnownLocationDisplay(for: video)
        let fileFields: [(String, String)] = [
                (
                    String(localized: .detailContainerFormat),
                    formattedContainer(media)
                ),
                (String(localized: .detailExtension), video.fileExtension.uppercased()),
                (
                    String(localized: .detailSize),
                    ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file)
                ),
                (String(localized: .detailDuration), formattedDuration(video.duration)),
                (String(localized: .detailCreated), formattedDate(video.creationDate)),
                (String(localized: .detailModified), formattedDate(video.modificationDate)),
                (String(localized: .detailAccessStatus), accessStatus),
                (video.availability == .unavailable
                    ? lastKnownLocation.title
                    : String(localized: .detailPath),
                 video.availability == .unavailable
                    ? lastKnownLocation.value
                    : filePath(video) ?? String(localized: .detailPathUnavailable)),
        ]
        addDetailSection(.file, fields: fileFields)
        addDetailSection(
            .video,
            fields: [
                (String(localized: .detailVideoCodec), valueOrUnavailable(media?.videoCodec)),
                (String(localized: .detailCodecTag), valueOrUnavailable(media?.videoCodecTag)),
                (String(localized: .detailCodecProfile), valueOrUnavailable(media?.videoProfile)),
                (String(localized: .detailResolution), formattedResolution(video)),
                (String(localized: .detailFrameRate), formattedFrameRate(media?.frameRate)),
                (String(localized: .detailBitRate), formattedBitRate(media?.videoBitRate)),
                (String(localized: .detailBitDepth), formattedBitDepth(media?.bitDepth)),
                (String(localized: .detailColorType), formattedColorInfo(media)),
                (String(localized: .detailRotation), formattedRotation(media?.rotationDegrees)),
            ]
        )
        addDetailSection(
            .audio,
            fields: [
                (String(localized: .detailAudioCodec), valueOrUnavailable(media?.audioCodec)),
                (String(localized: .detailCodecTag), valueOrUnavailable(media?.audioCodecTag)),
                (String(localized: .detailCodecProfile), valueOrUnavailable(media?.audioProfile)),
                (String(localized: .detailChannels), formattedChannels(media?.audioChannels)),
                (String(localized: .detailSampleRate), formattedSampleRate(media?.audioSampleRate)),
                (String(localized: .detailBitRate), formattedBitRate(media?.audioBitRate)),
            ]
        )
        updateScrollDocumentSize()
    }

    private var mode: Mode {
        if sectionControl.selectedSegment == 1 { return .details }
        return browsingContext == .unavailable ? .resolve : .tags
    }

    private func addScanCandidateDetails(_ candidates: [ScannedVideoCandidate]) {
        guard candidates.isEmpty == false else {
            addSecondaryText(String(
                localized: "scan.inspector.empty",
                defaultValue: "Select a video to view its file information."
            ))
            return
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            addPrimaryText(String(
                localized: "scan.inspector.selection",
                defaultValue: "\(candidates.count) Videos Selected"
            ))
            addField(
                title: String(localized: .detailTotalSize),
                value: ByteCountFormatter.string(
                    fromByteCount: candidates.reduce(Int64(0)) { $0 + $1.video.fileSize },
                    countStyle: .file
                )
            )
            return
        }
        addPrimaryText(candidate.video.filename)
        addField(
            title: String(localized: "scan.inspector.status", defaultValue: "Status"),
            value: String(localized: "scan.inspector.pending", defaultValue: "Waiting to Import")
        )
        let relativeFolder = (candidate.video.relativePath as NSString)
            .deletingLastPathComponent
        let location = relativeFolder.isEmpty
            ? candidate.sourceName
            : "\(candidate.sourceName) / \(relativeFolder)"
        addField(
            title: String(localized: .detailPath),
            value: location
        )
        addField(
            title: String(localized: .detailExtension),
            value: candidate.video.fileExtension.uppercased()
        )
        addField(
            title: String(localized: .detailSize),
            value: ByteCountFormatter.string(
                fromByteCount: candidate.video.fileSize,
                countStyle: .file
            )
        )
        addField(
            title: String(localized: .detailCreated),
            value: formattedDate(candidate.video.creationDate)
        )
        addField(
            title: String(localized: .detailModified),
            value: formattedDate(candidate.video.modificationDate)
        )
    }

    private func addResolveControls(for videos: [VideoRecord]) {
        guard videos.isEmpty == false else {
            addResolveTitle(String(
                localized: "unavailable.resolve.empty.title",
                defaultValue: "Select a video to resolve"
            ))
            addSecondaryText(String(
                localized: "unavailable.resolve.empty.detail",
                defaultValue: "Select a video to see its status and available actions."
            ))
            return
        }

        guard let video = selectedVideo else {
            addResolveTitle(String(
                format: String(
                    localized: "unavailable.resolve.selection.title",
                    defaultValue: "%lld Unavailable Videos Selected"
                ),
                videos.count
            ))
            addSecondaryText(String(
                localized: "unavailable.resolve.selection.detail",
                defaultValue: "Relinking requires confirming each original file individually. The current selection can only be removed in a batch."
            ))
            addUnavailableSelectionSummaryCard(videos)
            addResolveActions(showsRelink: false, selectedCount: videos.count)
            return
        }

        switch video.availability {
        case .unavailable:
            let lastKnownLocation = lastKnownLocationDisplay(for: video)
            addResolveTitle(String(
                localized: "detail.accessUnavailable",
                defaultValue: "Unavailable"
            ))
            addResolveFactCard(
                title: lastKnownLocation.title,
                value: lastKnownLocation.value,
                promise: String(
                    localized: "unavailable.retainedDetail",
                    defaultValue: "Original tags and media information will be preserved."
                )
            )
            addResolveActions(showsRelink: true, selectedCount: 1)
        case .offline:
            addResolveTitle(String(
                localized: "unavailable.resolve.offline.title",
                defaultValue: "Currently Offline"
            ))
            let source = offlineSourceName(video).flatMap { $0.isEmpty ? nil : $0 }
            addResolveFactCard(
                title: String(localized: "unavailable.resolve.source", defaultValue: "Source"),
                value: source.map {
                    String(
                        format: String(
                            localized: "unavailable.resolve.source.offline.named",
                            defaultValue: "“%@” is not connected"
                        ),
                        $0
                    )
                } ?? String(
                    localized: "unavailable.resolve.source.offline",
                    defaultValue: "The source is not connected"
                ),
                promise: String(
                    localized: "unavailable.resolve.offline.detail",
                    defaultValue: "It will restore automatically after the device is connected. Original tags and media information will be preserved."
                )
            )
            addResolveActions(showsRelink: false, selectedCount: 1)
        case .available:
            addSecondaryText(String(localized: .inspectorEmpty))
        }
    }

    private func lastKnownLocationDisplay(for video: VideoRecord) -> (title: String, value: String) {
        if let path = filePath(video), path.isEmpty == false {
            return (
                String(localized: "detail.lastKnownLocation", defaultValue: "Last Known Location"),
                path
            )
        }
        return (
            String(localized: "detail.lastKnownFile", defaultValue: "Last Known File"),
            video.filename
        )
    }

    private func addResolveTitle(_ value: String) {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        contentStack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func addResolveFactCard(title: String, value: String, promise: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        valueLabel.isSelectable = true

        let fact = NSStackView(views: [titleLabel, valueLabel])
        fact.orientation = .vertical
        fact.alignment = .leading
        fact.spacing = 3

        let promiseLabel = NSTextField(wrappingLabelWithString: promise)
        promiseLabel.font = .systemFont(ofSize: 11)
        promiseLabel.textColor = .secondaryLabelColor

        addResolveCard(views: [fact, promiseLabel])
    }

    private func addUnavailableSelectionSummaryCard(_ videos: [VideoRecord]) {
        let counts: [(String, Int)] = [
            (String(localized: "detail.accessUnavailable", defaultValue: "Unavailable"),
             videos.filter { $0.availability == .unavailable }.count),
            (String(localized: .videoOfflineBadge),
             videos.filter { $0.availability == .offline }.count),
        ].filter { $0.1 > 0 }
        let rows = counts.map { title, count -> [NSView] in
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.textColor = .secondaryLabelColor
            let countLabel = NSTextField(labelWithString: count.formatted())
            countLabel.alignment = .right
            return [titleLabel, countLabel]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        addResolveCard(views: [grid])
    }

    private func addResolveCard(views: [NSView]) {
        let card = InspectorResolveCardView()
        let cardStack = NSStackView(views: views)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 10
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        views.forEach {
            $0.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        }
        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func addResolveActions(showsRelink: Bool, selectedCount: Int) {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8

        if showsRelink {
            let isRelinking = selectedVideo.map { $0.id == relinkingVideoID } ?? false
            let relinkButton = InspectorResolvePrimaryButton(
                title: isRelinking
                    ? String(
                        localized: "unavailable.relink.checking",
                        defaultValue: "Checking the selected file…"
                    )
                    : String(
                        localized: "unavailable.relink.action",
                        defaultValue: "Relink Original…"
                    ),
                target: self,
                action: #selector(relinkSelectedVideo)
            )
            relinkButton.isEnabled = isRelinking == false
            group.addArrangedSubview(relinkButton)
            relinkButton.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }

        let removeTitle = selectedCount > 1
            ? String(
                format: String(
                    localized: "unavailable.remove.action.multiple",
                    defaultValue: "Remove %lld Videos from FileFacet…"
                ),
                selectedCount
            )
            : String(
                localized: "unavailable.remove.action",
                defaultValue: "Remove from FileFacet…"
            )
        let removeButton = NSButton(
            title: removeTitle,
            target: self,
            action: #selector(removeSelectedUnavailableVideos)
        )
        removeButton.isBordered = false
        removeButton.alignment = .center
        removeButton.font = .systemFont(ofSize: 12, weight: .medium)
        removeButton.contentTintColor = .systemOrange
        removeButton.isEnabled = selectedVideos.contains { $0.id == relinkingVideoID } == false
        group.addArrangedSubview(removeButton)
        removeButton.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        removeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        contentStack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    @objc private func relinkSelectedVideo() {
        guard let selectedVideo,
              selectedVideo.id != relinkingVideoID,
              selectedVideo.availability == .unavailable else { return }
        onRelinkVideo(selectedVideo)
    }

    @objc private func removeSelectedUnavailableVideos() {
        let videos = selectedVideos.filter { $0.availability != .available }
        guard browsingContext == .unavailable,
              videos.isEmpty == false,
              videos.count == selectedVideos.count,
              let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if videos.count > 1 {
            alert.messageText = String(
                format: String(
                    localized: "unavailable.remove.title.multiple",
                    defaultValue: "Remove %lld records from FileFacet?"
                ),
                videos.count
            )
            alert.informativeText = String(
                localized: "unavailable.remove.detail.multiple",
                defaultValue: "The original tags and media information for these records will be deleted from FileFacet. This will not affect original files that may exist on your Mac."
            )
        } else {
            alert.messageText = String(
                localized: "unavailable.remove.title",
                defaultValue: "Remove this record from FileFacet?"
            )
            alert.informativeText = String(
                localized: "unavailable.remove.detail",
                defaultValue: "The original tags and media information will be deleted from FileFacet. This will not affect the original file that may exist on your Mac."
            )
        }
        alert.addButton(withTitle: String(localized: .actionRemove))
        alert.addButton(withTitle: String(localized: .actionCancel))
        alert.buttons.first?.hasDestructiveAction = true
        let videoIDs = videos.map(\.id)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.onRemoveVideos(videoIDs) { [weak self] succeeded in
                guard succeeded else { return }
                self?.onVideoRemoved?(videoIDs.count)
            }
        }
    }

    private func addPrimaryText(_ value: String) {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        contentStack.addArrangedSubview(label)
    }

    private func addFilename(_ filename: String) {
        let label = NSTextField(wrappingLabelWithString: filename)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.isSelectable = true

        let image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: String(localized: .accessibilityCopyFilename)
        ) ?? NSImage()
        let copyButton = NSButton(image: image, target: self, action: #selector(copyFilename))
        copyButton.title = ""
        copyButton.imagePosition = .imageOnly
        copyButton.isBordered = false
        copyButton.controlSize = .small
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = String(localized: .accessibilityCopyFilename)
        copyButton.setAccessibilityLabel(String(localized: .accessibilityCopyFilename))
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let filenameRow = NSStackView(views: [label, copyButton])
        filenameRow.orientation = .horizontal
        filenameRow.alignment = .centerY
        filenameRow.spacing = 6
        contentStack.addArrangedSubview(filenameRow)
        filenameRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func addSecondaryText(_ value: String) {
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(label)
    }

    private func addField(title: String, value: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.isSelectable = true
        let fieldStack = NSStackView(views: [titleLabel, valueLabel])
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.spacing = 2
        contentStack.addArrangedSubview(fieldStack)
    }

    private func addDetailSection(_ section: DetailSection, fields: [(String, String)]) {
        let header = NSButton(
            title: section.title,
            target: self,
            action: #selector(toggleDetailSection(_:))
        )
        header.tag = section.rawValue
        header.isBordered = false
        header.bezelStyle = .inline
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.alignment = .left
        header.imagePosition = .imageLeading
        header.image = NSImage(
            systemSymbolName: collapsedDetailSections.contains(section) ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )
        header.contentTintColor = .secondaryLabelColor
        header.setAccessibilityLabel(section.title)

        let rows = fields.map { title, value -> [NSView] in
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 11)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            let valueLabel = NSTextField(wrappingLabelWithString: value)
            valueLabel.font = .systemFont(ofSize: 11)
            valueLabel.alignment = .right
            valueLabel.isSelectable = true
            valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [titleLabel, valueLabel]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.isHidden = collapsedDetailSections.contains(section)

        let group = NSStackView(views: [header, grid])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 7
        contentStack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        header.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        grid.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        contentStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    @objc private func toggleDetailSection(_ sender: NSButton) {
        guard let section = DetailSection(rawValue: sender.tag) else { return }
        if collapsedDetailSections.contains(section) {
            collapsedDetailSections.remove(section)
        } else {
            collapsedDetailSections.insert(section)
        }
        renderSelection()
    }

    private func formattedDuration(_ duration: Double?) -> String {
        guard let duration, duration.isFinite else {
            return String(localized: .detailMediaUnavailable)
        }
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return String(localized: .detailUnknown) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func valueOrUnavailable(_ value: String?) -> String {
        guard let value, value.isEmpty == false else {
            return String(localized: .detailMediaUnavailable)
        }
        return value
    }

    private func formattedContainer(_ media: MediaSourceInfo?) -> String {
        guard let format = media?.containerFormat, format.isEmpty == false else {
            return String(localized: .detailMediaUnavailable)
        }
        guard let brand = media?.containerBrand, brand.isEmpty == false else { return format }
        return "\(format) · \(brand)"
    }

    private func formattedResolution(_ video: VideoRecord) -> String {
        guard let width = video.width, let height = video.height else {
            return String(localized: .detailMediaUnavailable)
        }
        return "\(width) × \(height)"
    }

    private func formattedFrameRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else {
            return String(localized: .detailMediaUnavailable)
        }
        let number = value.formatted(.number.precision(.fractionLength(0...3)))
        return String(localized: .detailFramesPerSecond(number))
    }

    private func formattedBitRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else {
            return String(localized: .detailMediaUnavailable)
        }
        if value >= 1_000_000 {
            let number = (value / 1_000_000).formatted(.number.precision(.fractionLength(0...2)))
            return String(localized: .detailMegabitsPerSecond(number))
        }
        let number = (value / 1_000).formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: .detailKilobitsPerSecond(number))
    }

    private func formattedBitDepth(_ value: Int?) -> String {
        guard let value, value > 0 else {
            return String(localized: .detailMediaUnavailable)
        }
        return String(localized: .detailBitDepthValue(value))
    }

    private func formattedColorInfo(_ media: MediaSourceInfo?) -> String {
        guard let media else { return String(localized: .detailMediaUnavailable) }
        let transfer = media.colorTransfer ?? ""
        let colorType: String
        if transfer.localizedCaseInsensitiveContains("2084")
            || transfer.localizedCaseInsensitiveContains("PQ") {
            colorType = "HDR10"
        } else if transfer.localizedCaseInsensitiveContains("2100")
            || transfer.localizedCaseInsensitiveContains("HLG") {
            colorType = "HLG"
        } else if transfer.isEmpty == false || media.colorPrimaries != nil {
            colorType = "SDR"
        } else {
            return String(localized: .detailMediaUnavailable)
        }

        guard let primaries = media.colorPrimaries else { return colorType }
        let colorSpace: String?
        if primaries.localizedCaseInsensitiveContains("2020") {
            colorSpace = "BT.2020"
        } else if primaries.localizedCaseInsensitiveContains("709") {
            colorSpace = "BT.709"
        } else if primaries.localizedCaseInsensitiveContains("P3") {
            colorSpace = "Display P3"
        } else {
            colorSpace = nil
        }
        return [colorType, colorSpace].compactMap { $0 }.joined(separator: " · ")
    }

    private func formattedRotation(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return String(localized: .detailMediaUnavailable)
        }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))°"
    }

    private func formattedChannels(_ value: Int?) -> String {
        guard let value, value > 0 else {
            return String(localized: .detailMediaUnavailable)
        }
        let layout: String? = switch value {
        case 1: String(localized: .detailMono)
        case 2: String(localized: .detailStereo)
        case 6: String(localized: .detailSurroundFiveOne)
        default: nil
        }
        let count = String(localized: .detailChannelCount(value))
        return [layout, count].compactMap { $0 }.joined(separator: " · ")
    }

    private func formattedSampleRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else {
            return String(localized: .detailMediaUnavailable)
        }
        let number = (value / 1_000).formatted(.number.precision(.fractionLength(0...2)))
        return String(localized: .detailKilohertz(number))
    }

    private func addTagControls() {
        guard selectedVideos.isEmpty == false else { return }
        guard tagStateVideoIDs == selectedVideos.map(\.id) else {
            addSecondaryText(String(localized: .tagLoading))
            return
        }
        let orderedTagIDs = Set(loadedTagOrderIDs)
        let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let newlyAvailableTags = tags.filter { orderedTagIDs.contains($0.id) == false }
        let loadedTags = loadedTagOrderIDs.compactMap { tagsByID[$0] }
        let assignableTags = newlyAvailableTags + loadedTags
        let hasExactMatch = assignableTags.contains {
            $0.name.compare(tagSearchText, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        } || draftTagCreations.contains {
            $0.name.compare(tagSearchText, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if tagSearchText.isEmpty == false, hasExactMatch == false {
            addCreateTagButton(title: tagSearchText)
        }
        let visibleTags = assignableTags.filter {
            tagSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(tagSearchText)
        }
        let visibleCreations = draftTagCreations.reversed().filter {
            tagSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(tagSearchText)
        }
        for creation in visibleCreations {
            addPendingTagRow(creation)
        }
        for tag in visibleTags {
            let button = TagCheckbox(tag: tag, target: self, action: #selector(toggleTag(_:)))
            button.title = tag.name
            button.setButtonType(.switch)
            button.allowsMixedState = true
            switch draftTagStates[tag.id] ?? .off {
            case .off: button.state = .off
            case .mixed: button.state = .mixed
            case .on: button.state = .on
            }
            button.isEnabled = isApplyingTagChanges == false
            contentStack.addArrangedSubview(button)
        }
        if tagSearchText.isEmpty, assignableTags.isEmpty, draftTagCreations.isEmpty {
            addSecondaryText(String(localized: .tagEmpty))
        } else if tagSearchText.isEmpty == false,
                  visibleTags.isEmpty,
                  visibleCreations.isEmpty,
                  hasExactMatch {
            addSecondaryText(String(localized: .tagNoMatches))
        }
    }

    private func addCreateTagButton(title: String) {
        let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let button = NSButton(
            title: String(localized: .tagNewNamed(title)),
            target: self,
            action: #selector(createTagFromSearch(_:))
        )
        button.image = image
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.alignment = .left
        button.contentTintColor = .controlAccentColor
        button.toolTip = String(localized: .tagActionCreate)
        button.setAccessibilityLabel(String(localized: .accessibilityNewTagNamed(title)))
        button.isEnabled = isApplyingTagChanges == false
        contentStack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func addPendingTagRow(_ creation: TagCreationDraft) {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.state = .on
        checkbox.isEnabled = false

        let nameLabel = NSTextField(labelWithString: creation.name)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pathLabel = NSTextField(labelWithString: parentName(for: creation.parentID))
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.setContentHuggingPriority(.required, for: .horizontal)

        let pendingLabel = NSTextField(labelWithString: String(localized: .tagPending))
        pendingLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .semibold
        )
        pendingLabel.textColor = .controlAccentColor
        pendingLabel.setContentHuggingPriority(.required, for: .horizontal)

        let image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: .accessibilityRemovePendingTag)
        ) ?? NSImage()
        let removeButton = NSButton(image: image, target: self, action: #selector(removePendingTag(_:)))
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.controlSize = .small
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.identifier = NSUserInterfaceItemIdentifier(creation.id)
        removeButton.toolTip = String(localized: .accessibilityRemovePendingTag)
        removeButton.setAccessibilityLabel(
            String(localized: .accessibilityRemovePendingTagNamed(creation.name))
        )
        removeButton.isEnabled = isApplyingTagChanges == false

        let row = NSStackView(views: [checkbox, nameLabel, pathLabel, pendingLabel, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    @objc private func changeSection(_ sender: NSSegmentedControl) {
        closeNewTagPopover()
        guard mode == .tags else {
            renderSelection()
            return
        }
        showTagLoadingState()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .tags else { return }
            if self.tagStateVideoIDs == self.selectedVideos.map(\.id) {
                self.renderSelection()
            } else {
                self.refreshTagAssignments()
            }
        }
    }

    @objc private func toggleTag(_ sender: TagCheckbox) {
        guard selectedVideos.isEmpty == false, isApplyingTagChanges == false else { return }
        let previousState = draftTagStates[sender.tagRecord.id] ?? .off
        let nextState: TagAssignmentState = previousState == .on ? .off : .on
        draftTagStates[sender.tagRecord.id] = nextState
        sender.state = nextState == .on ? .on : .off
        updateActionArea()
    }

    @objc private func discardTagChanges() {
        discardPendingTagChanges()
    }

    @objc private func applyTagChanges() {
        applyPendingTagChanges { [weak self] succeeded in
            self?.onTagApplicationFinished?(succeeded)
        }
    }

    @objc private func searchTags(_ sender: NSSearchField) {
        tagSearchText = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renderSelection()
    }

    @objc private func createTagFromSearch(_ sender: NSButton) {
        showNewTagPopover(relativeTo: sender.bounds, of: sender, suggestedName: tagSearchText)
    }

    @objc private func removePendingTag(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, isApplyingTagChanges == false else { return }
        draftTagCreations.removeAll { $0.id == id }
        draftTagStates.removeValue(forKey: id)
        renderSelection()
    }

    var canBeginCreatingTag: Bool {
        mode == .tags && selectedVideos.isEmpty == false && isApplyingTagChanges == false
    }

    func beginCreatingTag() {
        guard canBeginCreatingTag else { return }
        sectionControl.selectedSegment = 0
        renderSelection()
        showNewTagPopover(
            relativeTo: tagSearchField.bounds,
            of: tagSearchField,
            suggestedName: tagSearchText
        )
    }

    private func showNewTagPopover(relativeTo rect: NSRect, of positioningView: NSView, suggestedName: String) {
        guard canBeginCreatingTag else { return }
        closeNewTagPopover()
        let controller = NewTagPopoverViewController(
            suggestedName: suggestedName,
            parentOptions: parentTagOptions
        )
        controller.onCancel = { [weak self] in self?.closeNewTagPopover() }
        controller.onStage = { [weak self] name, parentID in
            guard let self else { return String(localized: .tagCreateFailed) }
            let duplicateExists = self.tags.contains {
                $0.parentID == parentID
                    && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } || self.draftTagCreations.contains {
                $0.parentID == parentID
                    && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            guard duplicateExists == false else {
                return String(localized: .tagCreateDuplicate)
            }
            let creation = TagCreationDraft(id: UUID().uuidString, name: name, parentID: parentID)
            self.draftTagCreations.append(creation)
            self.draftTagStates[creation.id] = .on
            self.tagSearchText = ""
            self.tagSearchField.stringValue = ""
            self.closeNewTagPopover()
            self.renderSelection()
            return nil
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        newTagPopover = popover
        popover.show(relativeTo: rect, of: positioningView, preferredEdge: .maxY)
    }

    private func closeNewTagPopover() {
        newTagPopover?.performClose(nil)
        newTagPopover = nil
    }

    private var parentTagOptions: [NewTagParentOption] {
        tags
            .map { NewTagParentOption(id: $0.id, title: tagPath(for: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func tagPath(for tag: TagRecord) -> String {
        var names = [tag.name]
        var parentID = tag.parentID
        var visited = Set([tag.id])
        while let currentID = parentID,
              visited.insert(currentID).inserted,
              let parent = tags.first(where: { $0.id == currentID }) {
            names.insert(parent.name, at: 0)
            parentID = parent.parentID
        }
        return names.joined(separator: " › ")
    }

    private func parentName(for parentID: String?) -> String {
        guard let parentID, let parent = tags.first(where: { $0.id == parentID }) else {
            return String(localized: .tagCreateTopLevel)
        }
        return tagPath(for: parent)
    }

    @objc private func copyFilename() {
        guard let filename = selectedVideo?.filename else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filename, forType: .string)
    }

    private func scheduleInitialTagStateLoadIfNeeded() {
        guard mode == .tags,
              selectedVideos.isEmpty == false,
              tagStateVideoIDs != selectedVideos.map(\.id) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.refreshTagAssignments()
        }
    }

    private func showTagLoadingState() {
        clearContent()
        if selectedVideos.isEmpty {
            addSecondaryText(String(localized: .inspectorEmpty))
        } else {
            addSecondaryText(String(localized: .tagLoading))
        }
        updateScrollDocumentSize()
        updateTagSearchFieldVisibility()
        updateActionArea()
    }

    func discardPendingTagChanges() {
        guard isApplyingTagChanges == false else { return }
        closeNewTagPopover()
        draftTagCreations = []
        draftTagStates = tagStates
        renderSelection()
    }

    func takePendingTagChanges() -> InspectorTagDraftSnapshot? {
        guard hasPendingTagChanges, isApplyingTagChanges == false else { return nil }
        let snapshot = InspectorTagDraftSnapshot(
            states: draftTagStates,
            creations: draftTagCreations
        )
        discardPendingTagChanges()
        return snapshot
    }

    func restorePendingTagChanges(_ snapshot: InspectorTagDraftSnapshot) {
        guard isApplyingTagChanges == false else { return }
        draftTagStates = snapshot.states
        draftTagCreations = snapshot.creations
        renderSelection()
    }

    func applyPendingTagChanges(completion: @escaping (Bool) -> Void) {
        let assignments = pendingTagAssignments
        let creations = draftTagCreations
        let videoIDs = selectedVideos.map(\.id)
        guard assignments.isEmpty == false || creations.isEmpty == false else {
            completion(true)
            return
        }
        guard videoIDs.isEmpty == false, isApplyingTagChanges == false else {
            completion(false)
            return
        }
        closeNewTagPopover()
        isApplyingTagChanges = true
        updateActionArea()
        onApplyTagDraft(creations, assignments, videoIDs) { [weak self] succeeded in
            guard let self else { return }
            self.isApplyingTagChanges = false
            if succeeded {
                self.draftTagCreations = []
                self.tagStates = [:]
                self.draftTagStates = [:]
                self.tagStateVideoIDs = []
                self.loadedTagOrderIDs = []
            }
            self.renderSelection()
            completion(succeeded)
        }
    }

    private var pendingTagAssignments: [String: Bool] {
        var assignments: [String: Bool] = [:]
        for tag in tags {
            let savedState = tagStates[tag.id] ?? .off
            let draftState = draftTagStates[tag.id] ?? .off
            guard savedState != draftState else { continue }
            switch draftState {
            case .on: assignments[tag.id] = true
            case .off: assignments[tag.id] = false
            case .mixed: break
            }
        }
        for creation in draftTagCreations {
            assignments[creation.id] = true
        }
        return assignments
    }

    private func configureActionArea() {
        actionContainer.orientation = .vertical
        actionContainer.alignment = .leading
        actionContainer.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator
        actionContainer.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: actionContainer.widthAnchor).isActive = true

        draftStatusLabel.font = .systemFont(ofSize: 11)
        draftStatusLabel.textColor = .secondaryLabelColor
        actionContainer.addArrangedSubview(draftStatusLabel)
        draftStatusLabel.widthAnchor.constraint(equalTo: actionContainer.widthAnchor).isActive = true

        discardButton.controlSize = .regular
        discardButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        applyButton.controlSize = .regular
        applyButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = [.command]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, discardButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        actionContainer.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: actionContainer.widthAnchor).isActive = true
    }

    private func updateActionArea() {
        guard isViewLoaded else { return }
        let tagContentAvailable = mode == .tags
            && selectedVideos.isEmpty == false
            && tagStateVideoIDs == selectedVideos.map(\.id)
        actionContainer.isHidden = tagContentAvailable == false
        guard tagContentAvailable else { return }
        let assignments = pendingTagAssignments
        let isDirty = assignments.isEmpty == false || draftTagCreations.isEmpty == false
        discardButton.isEnabled = isDirty && isApplyingTagChanges == false
        applyButton.isEnabled = isDirty && isApplyingTagChanges == false
        if isApplyingTagChanges {
            draftStatusLabel.stringValue = String(localized: .tagDraftApplying)
            return
        }
        guard isDirty else {
            draftStatusLabel.stringValue = String(localized: .tagDraftInstruction)
            return
        }
        let creations = draftTagCreations.count
        let additions = assignments.values.filter { $0 }.count
        let removals = assignments.values.filter { $0 == false }.count
        var parts: [String] = []
        if creations > 0 {
            parts.append(String(localized: .tagDraftCreate(creations)))
        }
        if additions > 0 {
            parts.append(String(localized: .tagDraftAdd(additions)))
        }
        if removals > 0 {
            parts.append(String(localized: .tagDraftRemove(removals)))
        }
        draftStatusLabel.stringValue = String(
            localized: .tagDraftPending(AppLocalization.list(parts))
        )
    }

    private func updateTagSearchFieldVisibility() {
        guard isViewLoaded else { return }
        tagSearchField.isHidden = browsingContext == .scanResults
            || mode != .tags
            || selectedVideos.isEmpty
    }

    private func clearContent() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func updateScrollDocumentSize() {
        guard isViewLoaded else { return }
        let width = contentScrollView.contentSize.width
        guard width > 0 else { return }
        contentStack.setFrameSize(NSSize(width: width, height: contentStack.frame.height))
        let fittingHeight = max(1, contentStack.fittingSize.height)
        contentStack.setFrameSize(NSSize(width: width, height: fittingHeight))
        contentStack.layoutSubtreeIfNeeded()
    }

}

private final class InspectorContentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class InspectorResolveCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.13)
            : NSColor.black.withAlphaComponent(0.18)).cgColor
        layer?.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent(isDark ? 0.11 : 0.09).cgColor
    }
}

private final class InspectorResolvePrimaryButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .large
        font = .systemFont(ofSize: 13, weight: .semibold)
        alignment = .center
        contentTintColor = .white
        focusRingType = .default
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        displayIfNeeded()
        super.mouseDown(with: event)
        isPressed = false
        needsDisplay = true
    }

    override func updateLayer() {
        let alpha = isPressed ? 0.72 : (isHovered ? 0.88 : 1)
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
    }
}

private final class TagCheckbox: NSButton {
    let tagRecord: TagRecord
    init(tag: TagRecord, target: AnyObject?, action: Selector?) {
        self.tagRecord = tag
        super.init(frame: .zero)
        self.target = target
        self.action = action
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct NewTagParentOption {
    let id: String
    let title: String
}

@MainActor
private final class NewTagPopoverViewController: NSViewController {
    var onCancel: (() -> Void)?
    var onStage: ((String, String?) -> String?)?

    private let suggestedName: String
    private let parentOptions: [NewTagParentOption]
    private let nameField = NSTextField()
    private let parentPopup = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(suggestedName: String, parentOptions: [NewTagParentOption]) {
        self.suggestedName = suggestedName
        self.parentOptions = parentOptions
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 300, height: 190)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let titleLabel = NSTextField(labelWithString: String(localized: .tagCreateTitle))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        nameField.stringValue = suggestedName
        nameField.placeholderString = String(localized: .tagCreateNamePlaceholder)
        nameField.target = self
        nameField.action = #selector(stageTag)
        addFormRow(title: String(localized: .tagCreateName), control: nameField, to: stack)

        parentPopup.addItem(withTitle: String(localized: .tagCreateTopLevelNoParent))
        for option in parentOptions {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.id
            parentPopup.menu?.addItem(item)
        }
        addFormRow(title: String(localized: .tagCreateParent), control: parentPopup, to: stack)

        let noteLabel = NSTextField(
            wrappingLabelWithString: String(localized: .tagCreateNote)
        )
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteLabel)
        noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        errorLabel.font = .systemFont(ofSize: 10)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let cancelButton = NSButton(
            title: String(localized: .actionCancel),
            target: self,
            action: #selector(cancel)
        )
        let stageButton = NSButton(
            title: String(localized: .actionStageDraft),
            target: self,
            action: #selector(stageTag)
        )
        stageButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, stageButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    private func addFormRow(title: String, control: NSView, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
    }

    @objc private func cancel() {
        onCancel?()
    }

    @objc private func stageTag() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else {
            showError(String(localized: .tagValidationEnterName))
            return
        }
        let parentID = parentPopup.selectedItem?.representedObject as? String
        if let error = onStage?(name, parentID) {
            showError(error)
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        nameField.selectText(nil)
    }
}

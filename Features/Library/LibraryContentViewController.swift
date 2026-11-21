import AppKit
@preconcurrency import QuickLookThumbnailing

@MainActor
final class LibraryContentViewController: NSViewController {
    let ruleBarViewController: LibraryRuleBarViewController
    let videoGridViewController: VideoGridViewController
    let scanResultsViewController: ScanResultsViewController

    var onRecover: (() -> Void)?
    var onStopRecovery: (() -> Void)?
    var onDismissRecovery: (() -> Void)?
    private var recoveryStatus = RecoveryStatus()
    private var showsScanResults = false
    private let recoveryBar = NSStackView()
    private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
    private let recoveryButton = NSButton()
    private let recoveryClose = NSButton()
    private let recoveryProgress = NSProgressIndicator()
    private var recoveryHeight: NSLayoutConstraint?

    func setRecoveryStatus(_ status: RecoveryStatus) {
        loadViewIfNeeded()
        recoveryStatus = status
        updateRecoveryBar()
    }

    private func updateRecoveryBar() {
        let status = recoveryStatus
        let hasEntry = status.candidateCount > 0 && (status.showEntry || showsScanResults)
        let visible = status.running || status.message != nil || hasEntry
        recoveryBar.isHidden = !visible
        recoveryHeight?.constant = visible ? 64 : 0
        recoveryClose.isHidden = status.message == nil || status.running
        recoveryProgress.isHidden = !status.running
        recoveryButton.isHidden = !status.running && !hasEntry
        recoveryButton.isEnabled = status.running || status.canStart
        recoveryButton.title = status.running
            ? String(localized: "recovery.stop", defaultValue: "Stop Recovery")
            : String(localized: "recovery.action", defaultValue: "Restore Access")
        if status.running {
            recoveryLabel.stringValue = String(localized: "recovery.progress", defaultValue: "Checking original videos: \(status.completed) of \(status.total)")
            if status.deferred > 0 {
                recoveryLabel.stringValue += " " + String(localized: "recovery.deferred.progress",
                    defaultValue: "Waiting for files: \(status.deferred).")
            }
            recoveryProgress.maxValue = Double(max(1, status.total))
            recoveryProgress.doubleValue = Double(status.completed)
        } else {
            recoveryLabel.stringValue = status.message ?? String(localized: "recovery.scope", defaultValue: "\(status.candidateCount) videos can be checked for recovery.")
        }
    }

    @objc private func performRecoveryAction() {
        if recoveryStatus.running { onStopRecovery?() } else { onRecover?() }
    }
    @objc private func dismissRecovery() { onDismissRecovery?() }

    init(
        ruleBarViewController: LibraryRuleBarViewController,
        videoGridViewController: VideoGridViewController,
        scanResultsViewController: ScanResultsViewController
    ) {
        self.ruleBarViewController = ruleBarViewController
        self.videoGridViewController = videoGridViewController
        self.scanResultsViewController = scanResultsViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        addChild(ruleBarViewController)
        addChild(videoGridViewController)
        addChild(scanResultsViewController)

        let ruleBar = ruleBarViewController.view
        let grid = videoGridViewController.view
        let scanResults = scanResultsViewController.view
        ruleBar.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        scanResults.translatesAutoresizingMaskIntoConstraints = false
        recoveryBar.translatesAutoresizingMaskIntoConstraints = false
        recoveryBar.orientation = .horizontal
        recoveryBar.alignment = .centerY
        recoveryBar.spacing = 12
        recoveryBar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        recoveryLabel.font = .systemFont(ofSize: 13)
        recoveryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recoveryButton.target = self
        recoveryButton.action = #selector(performRecoveryAction)
        recoveryButton.bezelStyle = .rounded
        recoveryClose.title = String(localized: "recovery.dismiss", defaultValue: "Dismiss")
        recoveryClose.target = self
        recoveryClose.action = #selector(dismissRecovery)
        recoveryClose.bezelStyle = .rounded
        recoveryProgress.isIndeterminate = false
        recoveryProgress.style = .bar
        recoveryProgress.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let recoveryViews: [NSView] = [recoveryLabel, recoveryProgress, recoveryButton, recoveryClose]
        recoveryViews.forEach { recoveryBar.addArrangedSubview($0) }
        container.addSubview(recoveryBar)
        recoveryHeight = recoveryBar.heightAnchor.constraint(equalToConstant: 0)
        recoveryHeight?.isActive = true
        NSLayoutConstraint.activate([
            recoveryBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            recoveryBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            recoveryBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor)
        ])
        container.addSubview(ruleBar)
        container.addSubview(grid)
        container.addSubview(scanResults)

        NSLayoutConstraint.activate([
            ruleBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ruleBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ruleBar.topAnchor.constraint(equalTo: recoveryBar.bottomAnchor),
            ruleBar.heightAnchor.constraint(equalToConstant: 44),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: ruleBar.bottomAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scanResults.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scanResults.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scanResults.topAnchor.constraint(equalTo: recoveryBar.bottomAnchor),
            scanResults.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        scanResults.isHidden = true
        view = container
        updateRecoveryBar()
    }

    func setShowsScanResults(_ showsScanResults: Bool) {
        loadViewIfNeeded()
        self.showsScanResults = showsScanResults
        updateRecoveryBar()
        ruleBarViewController.view.isHidden = showsScanResults
        videoGridViewController.view.isHidden = showsScanResults
        scanResultsViewController.view.isHidden = showsScanResults == false
    }
}

@MainActor
final class ScanResultsViewController: NSViewController,
    NSCollectionViewDataSource,
    NSCollectionViewDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("ScanCandidateItem")

    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let statusView = NSView()
    private let statusSpinner = NSProgressIndicator()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(labelWithString: "")
    private let dismissStatusButton = NSButton()
    private let statusSeparator = NSBox()
    private let accessView = NSView()
    private let accessLabel = NSTextField(labelWithString: "")
    private let chooseFoldersButton = NSButton()
    private let selectionView = NSView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let selectAllButton = NSButton()
    private let importButton = NSButton()
    private let emptyStack = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let emptyActionButton = NSButton()
    private var statusHeightConstraint: NSLayoutConstraint?
    private var statusTitleBusyLeadingConstraint: NSLayoutConstraint?
    private var statusTitleIdleLeadingConstraint: NSLayoutConstraint?
    private var accessHeightConstraint: NSLayoutConstraint?
    private var selectionHeightConstraint: NSLayoutConstraint?
    private var candidates: [ScannedVideoCandidate] = []
    private var filteredCandidates: [ScannedVideoCandidate] = []
    private var selectedCandidateIDs = Set<String>()
    private var searchText = ""
    private var isWorking = false
    private let thumbnailStore = ScanCandidateThumbnailStore()

    var onImportSelected: (([String]) -> Void)?
    var onChooseFolders: (() -> Void)?
    var onCloseResults: (() -> Void)?
    var onSelectionChanged: (([ScannedVideoCandidate]) -> Void)?

    override func loadView() {
        let container = NSView()
        configureStatusView()
        configureAccessView()
        configureSelectionView()
        configureCollectionView()
        configureEmptyState()

        for subview in [statusView, accessView, selectionView, scrollView, emptyStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        let statusHeight = statusView.heightAnchor.constraint(equalToConstant: 0)
        let accessHeight = accessView.heightAnchor.constraint(equalToConstant: 0)
        let selectionHeight = selectionView.heightAnchor.constraint(equalToConstant: 44)
        statusHeightConstraint = statusHeight
        accessHeightConstraint = accessHeight
        selectionHeightConstraint = selectionHeight
        NSLayoutConstraint.activate([
            statusView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusView.topAnchor.constraint(equalTo: container.topAnchor),
            statusHeight,
            accessView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            accessView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            accessView.topAnchor.constraint(equalTo: statusView.bottomAnchor),
            accessHeight,
            selectionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            selectionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            selectionView.topAnchor.constraint(equalTo: accessView.bottomAnchor),
            selectionHeight,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: selectionView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -18),
            emptyStack.widthAnchor.constraint(lessThanOrEqualToConstant: 390),
        ])
        statusView.isHidden = true
        accessView.isHidden = true
        emptyStack.isHidden = true
        view = container
        updateControls()
    }

    func showScanning(title: String, detail: String) {
        loadViewIfNeeded()
        thumbnailStore.clear()
        isWorking = true
        candidates = []
        filteredCandidates = []
        selectedCandidateIDs.removeAll()
        configureStatus(title: title, detail: detail, isBusy: true)
        accessView.isHidden = true
        accessHeightConstraint?.constant = 0
        collectionView.reloadData()
        updateControls()
    }

    func showImporting(
        title: String,
        detail: String,
        results: LibraryScanResults
    ) {
        apply(results: results, working: true)
        configureStatus(title: title, detail: detail, isBusy: true)
    }

    func showResults(_ results: LibraryScanResults) {
        apply(results: results, working: false)
        if let notice = results.notice {
            configureStatus(title: notice.title, detail: notice.detail, isBusy: false)
        } else {
            statusView.isHidden = true
            statusHeightConstraint?.constant = 0
        }
    }

    func setSearchText(_ value: String) {
        searchText = value
        refilterCandidates()
    }

    func reset() {
        loadViewIfNeeded()
        thumbnailStore.clear()
        candidates = []
        filteredCandidates = []
        selectedCandidateIDs.removeAll()
        searchText = ""
        isWorking = false
        statusView.isHidden = true
        statusHeightConstraint?.constant = 0
        accessView.isHidden = true
        accessHeightConstraint?.constant = 0
        collectionView.reloadData()
        updateControls()
    }

    private func apply(results: LibraryScanResults, working: Bool) {
        loadViewIfNeeded()
        isWorking = working
        candidates = results.candidates
        let candidateIDs = Set(candidates.map(\.id))
        selectedCandidateIDs.formIntersection(candidateIDs)
        let unavailableCount = results.uncheckedFolderCount + results.failedFolderCount
        if unavailableCount > 0 {
            accessLabel.stringValue = unavailableCount == 1
                ? String(
                    localized: "scan.access.unchecked.one",
                    defaultValue: "1 folder could not be fully checked."
                )
                : String(
                    localized: "scan.access.unchecked.many",
                    defaultValue: "\(unavailableCount) folders could not be fully checked."
                )
            accessView.isHidden = false
            accessHeightConstraint?.constant = 42
            chooseFoldersButton.isHidden = results.uncheckedFolderCount == 0
        } else {
            accessView.isHidden = true
            accessHeightConstraint?.constant = 0
        }
        refilterCandidates()
        updateControls()
    }

    private func refilterCandidates() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredCandidates = candidates
        } else {
            filteredCandidates = candidates.filter {
                $0.video.filename.localizedCaseInsensitiveContains(query)
                    || $0.video.relativePath.localizedCaseInsensitiveContains(query)
            }
        }
        collectionView.reloadData()
        restoreCollectionSelection()
        updateControls()
    }

    private func configureStatusView() {
        statusView.wantsLayer = true
        statusView.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.035).cgColor
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        statusDetail.font = .systemFont(ofSize: 11)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.lineBreakMode = .byTruncatingTail
        dismissStatusButton.title = String(localized: .actionDone)
        dismissStatusButton.bezelStyle = .rounded
        dismissStatusButton.controlSize = .small
        dismissStatusButton.target = self
        dismissStatusButton.action = #selector(dismissStatus)
        statusSeparator.boxType = .separator
        for subview in [statusSpinner, statusTitle, statusDetail, dismissStatusButton, statusSeparator] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            statusView.addSubview(subview)
        }
        let busyLeading = statusTitle.leadingAnchor.constraint(
            equalTo: statusSpinner.trailingAnchor,
            constant: 10
        )
        let idleLeading = statusTitle.leadingAnchor.constraint(
            equalTo: statusView.leadingAnchor,
            constant: 14
        )
        statusTitleBusyLeadingConstraint = busyLeading
        statusTitleIdleLeadingConstraint = idleLeading
        NSLayoutConstraint.activate([
            statusSpinner.leadingAnchor.constraint(equalTo: statusView.leadingAnchor, constant: 14),
            statusSpinner.centerYAnchor.constraint(equalTo: statusView.centerYAnchor),
            statusSpinner.widthAnchor.constraint(equalToConstant: 16),
            busyLeading,
            statusTitle.topAnchor.constraint(equalTo: statusView.topAnchor, constant: 8),
            statusTitle.trailingAnchor.constraint(lessThanOrEqualTo: dismissStatusButton.leadingAnchor, constant: -8),
            statusDetail.leadingAnchor.constraint(equalTo: statusTitle.leadingAnchor),
            statusDetail.topAnchor.constraint(equalTo: statusTitle.bottomAnchor, constant: 2),
            statusDetail.trailingAnchor.constraint(lessThanOrEqualTo: dismissStatusButton.leadingAnchor, constant: -8),
            dismissStatusButton.trailingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: -14),
            dismissStatusButton.centerYAnchor.constraint(equalTo: statusView.centerYAnchor),
            statusSeparator.leadingAnchor.constraint(equalTo: statusView.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: statusView.trailingAnchor),
            statusSeparator.bottomAnchor.constraint(equalTo: statusView.bottomAnchor),
        ])
    }

    private func configureAccessView() {
        accessView.wantsLayer = true
        accessView.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        accessLabel.font = .systemFont(ofSize: 11)
        accessLabel.textColor = .secondaryLabelColor
        chooseFoldersButton.title = String(
            localized: "scan.access.chooseFolders",
            defaultValue: "Choose Folders…"
        )
        chooseFoldersButton.bezelStyle = .rounded
        chooseFoldersButton.controlSize = .small
        chooseFoldersButton.target = self
        chooseFoldersButton.action = #selector(chooseFolders)
        for subview in [accessLabel, chooseFoldersButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            accessView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            accessLabel.leadingAnchor.constraint(equalTo: accessView.leadingAnchor, constant: 14),
            accessLabel.centerYAnchor.constraint(equalTo: accessView.centerYAnchor),
            accessLabel.trailingAnchor.constraint(lessThanOrEqualTo: chooseFoldersButton.leadingAnchor, constant: -8),
            chooseFoldersButton.trailingAnchor.constraint(equalTo: accessView.trailingAnchor, constant: -14),
            chooseFoldersButton.centerYAnchor.constraint(equalTo: accessView.centerYAnchor),
        ])
    }

    private func configureSelectionView() {
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.font = .systemFont(ofSize: 12)
        selectAllButton.bezelStyle = .rounded
        selectAllButton.controlSize = .small
        selectAllButton.target = self
        selectAllButton.action = #selector(toggleSelectAll)
        importButton.bezelStyle = .rounded
        importButton.controlSize = .small
        importButton.keyEquivalent = "\r"
        importButton.target = self
        importButton.action = #selector(importSelected)
        for subview in [selectionLabel, selectAllButton, importButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            selectionView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            selectionLabel.leadingAnchor.constraint(equalTo: selectionView.leadingAnchor, constant: 14),
            selectionLabel.centerYAnchor.constraint(equalTo: selectionView.centerYAnchor),
            selectAllButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -8),
            selectAllButton.centerYAnchor.constraint(equalTo: selectionView.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: selectionView.trailingAnchor, constant: -14),
            importButton.centerYAnchor.constraint(equalTo: selectionView.centerYAnchor),
        ])
    }

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 182, height: 148)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ScanCandidateCollectionViewItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView
    }

    private func configureEmptyState() {
        let image = NSImageView(image: NSImage(
            systemSymbolName: "folder.badge.checkmark",
            accessibilityDescription: nil
        ) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        image.symbolConfiguration = .init(pointSize: 30, weight: .light)
        emptyTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyTitle.alignment = .center
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        emptyDetail.maximumNumberOfLines = 3
        emptyActionButton.title = String(
            localized: "scan.sidebar.close",
            defaultValue: "Close Scan Results"
        )
        emptyActionButton.bezelStyle = .rounded
        emptyActionButton.target = self
        emptyActionButton.action = #selector(closeResults)
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        [image, emptyTitle, emptyDetail, emptyActionButton].forEach(emptyStack.addArrangedSubview)
        emptyDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
    }

    private func configureStatus(title: String, detail: String, isBusy: Bool) {
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        statusSpinner.isHidden = isBusy == false
        if isBusy {
            statusTitleIdleLeadingConstraint?.isActive = false
            statusTitleBusyLeadingConstraint?.isActive = true
            statusSpinner.startAnimation(nil)
        } else {
            statusTitleBusyLeadingConstraint?.isActive = false
            statusTitleIdleLeadingConstraint?.isActive = true
            statusSpinner.stopAnimation(nil)
        }
        dismissStatusButton.isHidden = isBusy
        statusView.isHidden = false
        statusHeightConstraint?.constant = 52
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let total = candidates.count
        let selectedCount = selectedCandidateIDs.count
        selectionView.isHidden = total == 0
        selectionHeightConstraint?.constant = total == 0 ? 0 : 44
        selectionLabel.stringValue = String(
            localized: "scan.selection.summary",
            defaultValue: "\(selectedCount) of \(total) selected"
        )
        selectAllButton.title = total > 0 && selectedCount == total
            ? String(localized: "scan.selection.clear", defaultValue: "Deselect All")
            : String(localized: "scan.selection.all", defaultValue: "Select All")
        importButton.title = selectedCount == 0
            ? String(localized: "scan.import.selected", defaultValue: "Import Selected")
            : selectedCount == 1
                ? String(localized: "scan.import.count.one", defaultValue: "Import 1 Video")
                : String(
                    localized: "scan.import.count.many",
                    defaultValue: "Import \(selectedCount) Videos"
                )
        selectAllButton.isEnabled = isWorking == false && total > 0
        importButton.isEnabled = isWorking == false && selectedCount > 0
        collectionView.isSelectable = isWorking == false
        let showsEmpty = total == 0 && isWorking == false
        emptyStack.isHidden = showsEmpty == false
        scrollView.isHidden = showsEmpty
        if showsEmpty {
            emptyTitle.stringValue = String(
                localized: "scan.pending.empty.title",
                defaultValue: "No Videos Waiting to Import"
            )
            emptyDetail.stringValue = String(
                localized: "scan.pending.empty.detail",
                defaultValue: "Review the folder status above, then scan again or close these results."
            )
        }
        notifySelectionChanged()
    }

    private func restoreCollectionSelection() {
        let indexes = IndexSet(filteredCandidates.enumerated().compactMap { index, candidate in
            selectedCandidateIDs.contains(candidate.id) ? index : nil
        })
        collectionView.selectionIndexes = indexes
    }

    private func notifySelectionChanged() {
        onSelectionChanged?(candidates.filter { selectedCandidateIDs.contains($0.id) })
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        filteredCandidates.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: Self.itemIdentifier,
            for: indexPath
        ) as? ScanCandidateCollectionViewItem ?? ScanCandidateCollectionViewItem()
        item.configure(
            candidate: filteredCandidates[indexPath.item],
            thumbnailStore: thumbnailStore
        )
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        for indexPath in indexPaths where indexPath.item < filteredCandidates.count {
            selectedCandidateIDs.insert(filteredCandidates[indexPath.item].id)
        }
        updateControls()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        for indexPath in indexPaths where indexPath.item < filteredCandidates.count {
            selectedCandidateIDs.remove(filteredCandidates[indexPath.item].id)
        }
        updateControls()
    }

    @objc private func toggleSelectAll() {
        if selectedCandidateIDs.count == candidates.count {
            selectedCandidateIDs.removeAll()
        } else {
            selectedCandidateIDs = Set(candidates.map(\.id))
        }
        restoreCollectionSelection()
        updateControls()
    }

    @objc private func importSelected() {
        onImportSelected?(Array(selectedCandidateIDs))
    }

    @objc private func chooseFolders() {
        onChooseFolders?()
    }

    @objc private func closeResults() {
        onCloseResults?()
    }

    @objc private func dismissStatus() {
        statusView.isHidden = true
        statusHeightConstraint?.constant = 0
    }
}

@MainActor
private final class ScanCandidateThumbnailStore {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 240
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func image(
        for candidate: ScannedVideoCandidate,
        size: CGSize,
        scale: CGFloat
    ) async -> NSImage? {
        let key = candidate.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: candidate.fileURL,
            size: size,
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            try Task.checkCancellation()
            let image = representation.nsImage
            let cost = representation.cgImage.bytesPerRow * representation.cgImage.height
            cache.setObject(image, forKey: key, cost: cost)
            return image
        } catch {
            return nil
        }
    }

    func clear() {
        cache.removeAllObjects()
    }
}

private final class ScanCandidateCollectionViewItem: NSCollectionViewItem {
    private let thumbnailContainer = NSView()
    private let iconView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var representedCandidateID: String?
    private var thumbnailTask: Task<Void, Never>?

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        representedCandidateID = nil
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 2
        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.cornerRadius = 6
        thumbnailContainer.layer?.backgroundColor = NSColor.quaternaryLabelColor
            .withAlphaComponent(0.12).cgColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.font = .systemFont(ofSize: 10)
        sizeLabel.textColor = .secondaryLabelColor
        thumbnailContainer.addSubview(iconView)
        [thumbnailContainer, filenameLabel, detailLabel, sizeLabel].forEach(container.addSubview)
        NSLayoutConstraint.activate([
            thumbnailContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            thumbnailContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            thumbnailContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            thumbnailContainer.heightAnchor.constraint(equalToConstant: 88),
            iconView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: 6),
            iconView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -6),
            iconView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor, constant: 6),
            iconView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -6),
            filenameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            filenameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            filenameLabel.topAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: filenameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: filenameLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 2),
            sizeLabel.leadingAnchor.constraint(equalTo: filenameLabel.leadingAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: filenameLabel.trailingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 2),
        ])
        view = container
        updateSelectionAppearance()
    }

    func configure(
        candidate: ScannedVideoCandidate,
        thumbnailStore: ScanCandidateThumbnailStore
    ) {
        loadViewIfNeeded()
        thumbnailTask?.cancel()
        representedCandidateID = candidate.id
        iconView.image = NSImage(
            systemSymbolName: "film",
            accessibilityDescription: candidate.video.filename
        )?.withSymbolConfiguration(.init(pointSize: 30, weight: .light))
        iconView.contentTintColor = .secondaryLabelColor
        filenameLabel.stringValue = candidate.video.filename
        let relativeFolder = (candidate.video.relativePath as NSString)
            .deletingLastPathComponent
        detailLabel.stringValue = relativeFolder.isEmpty
            ? candidate.sourceName
            : "\(candidate.sourceName) / \(relativeFolder)"
        sizeLabel.stringValue = ByteCountFormatter.string(
            fromByteCount: candidate.video.fileSize,
            countStyle: .file
        )
        view.setAccessibilityLabel(candidate.video.filename)
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        thumbnailTask = Task { @MainActor [weak self] in
            let image = await thumbnailStore.image(
                for: candidate,
                size: CGSize(width: 360 / scale, height: 202 / scale),
                scale: scale
            )
            guard Task.isCancelled == false,
                  let self,
                  representedCandidateID == candidate.id,
                  let image else { return }
            iconView.contentTintColor = nil
            iconView.image = image
        }
    }

    private func updateSelectionAppearance() {
        guard isViewLoaded else { return }
        view.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        view.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            : NSColor.clear.cgColor
    }
}

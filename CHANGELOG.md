# Changelog

This file records user-visible changes across Tagivy and earlier FileFacet releases.

## [Unreleased]

## [1.0.14] - 2026-11-21

### Fixed

- Restoring access to a video at its original path no longer reads the video contents. Originals that only exist in iCloud can be associated without downloading them.
- Restore access from an enclosing folder and continue checking other records when a file location does not respond.

## [1.0.13] - 2026-11-21

### Changed

- The macOS app is now called Tagivy.
- Tagivy uses a new macOS app identity and starts with a separate local library. Existing FileFacet tags, preferences, thumbnails, and folder permissions are not imported automatically. Keep FileFacet if you still need your previous library.

## [1.0.12] - 2026-11-21

### Fixed

- Retried verification of protected videos after FileFacet regained authorized access, while preserving file identity checks.
- Kept the thumbnail badge and Inspector in sync when original files are unavailable, awaiting access verification, or not downloaded.
- Skipped known cloud placeholders during source recovery without requesting downloads.

## [1.0.11] - 2026-11-20

### Changed

- Replaced thumbnail status text badges with compact system icons, distinguishing iCloud originals that are not downloaded from unavailable videos and offline drives.
- Kept existing covers visible for iCloud placeholders and skipped those files during thumbnail generation without requesting downloads.

## [1.0.10] - 2026-11-20

### Fixed

- Kept background thumbnail work from being discarded by scans when the video and its source have not changed.
- Resumed thumbnail generation automatically when a temporarily unavailable video location becomes accessible again.

## [1.0.9] - 2026-09-21

### Added

- Added Restore Access to reconnect unavailable videos after confirming their original folders, with content verification, progress, and cancellation.

### Changed

- Kept All Videos and Recently Added first with Command-1 and Command-2. Untagged and Unavailable Videos appear only when nonempty and have no numeric shortcuts.
- Kept folders authorized for recovery separate from new-video scan scope.

### Fixed

- Verified original content before automatically reconnecting lost file associations through existing folder access.
- Prevented outdated background media results from replacing newer metadata or thumbnails.
- Prioritized visible videos when rebuilding missing thumbnails, reused existing media information, and reduced repeated cache scans.
- Loaded thumbnails in the background and updated individual cards to improve responsiveness and clear hover highlights promptly.
- Fixed relinking readable original videos rejected by AVFoundation's playability flag while retaining content and media checks.

## [1.0.8] - 2026-08-30

### Added

- Added on-demand scans for new videos in previously selected folders, with temporary Quick Look previews, selectable results, and optional folder access recovery for individually imported videos.

### Changed

- Completed scan sessions now close their temporary sidebar category and reveal every video added during the session in Recently Added; sessions containing an existing record reveal the handled videos in All Videos.
- Aligned tag-draft metadata, filter fields, and related action buttons with the native macOS text hierarchy.

### Fixed

- Fixed the Quick Look panel remaining visible with an empty selection after video playback ended and the user pressed Escape.
- Fixed scan results remaining onscreen when the user selected the already-active library category, compressed folder-import choices, and inconsistent singular scan feedback.
- Fixed long Inspector tag lists briefly compressing their row spacing while calculating the scrollable content size.

## [1.0.7] - 2026-08-07

### Added

- Added video-grid grouping by added, created, or modified date, duration, file size, and resolution, with independent group ordering, counts, collapsible sticky headers, and a direct clear control.
- Recently Added now temporarily groups videos by newest added date and restores the previous grouping preference when leaving the category.

### Fixed

- Sidebar names now use the available space up to their right-aligned counts, while counts remain fully visible in both selected and unselected rows.

## [1.0.6] - 2026-08-07

### Added

- Added a unified Unavailable Videos category for temporarily offline and inaccessible videos, with `Command-1` through `Command-4` shortcuts for the four preset library categories.
- Inaccessible videos can now be relinked to an original file or removed from FileFacet while retaining their tags, cached thumbnail, and media information until the user decides.

### Changed

- Completed imports now select and reveal every video handled by the batch: new-only batches open Recently Added, while batches containing existing records open All Videos.
- Recently Added now uses a fixed newest-first system ordering without changing user sorting in other categories; manually changing categories also starts at the top with no video selected.
- Finished notifications now include a close control, and removal undo expires when the browsing context changes, a new import begins, or the notification is dismissed.
- Videos confirmed outside their known location or moved to the Trash now leave active library results and remain available for recovery; relinking only proceeds automatically when the complete content fingerprint matches.

## [1.0.5] - 2026-07-31

### Added

- Added a visible rule bar for combining filename, tag, untagged, date, duration, file-size, and resolution filters with “match all” or “match any” relationships.
- Added sorting by filename, added, created, or modified date, duration, file size, and resolution.
- Added saved Smart Collections with live result counts, rule preview, revert, update, save-as, inline rename, and deletion.
- Added `Command-F` for filename search and `Shift-Command-F` for adding a filter condition.
- The Inspector now groups container, video-codec, audio-codec, profile, rate, depth, color, and rotation source information while keeping cached details available for offline videos.

### Changed

- Search, filters, and sorting now remain within the selected system category or tag scope, and filter editors apply their draft once after confirmation.
- Thumbnail generation now falls back to Quick Look when AVFoundation cannot extract a frame; files unsupported by both macOS media paths continue to use the generic video icon.

### Fixed

- Pressing Escape now cancels inline renaming for tags and Smart Collections, while Return or focus loss saves a valid name consistently.

## [1.0.4] - 2026-07-31

### Added

- Folder imports can now create hierarchical FileFacet tags from the directory structure, with an optional root tag for each selected folder.
- Added a shared folder-import preference for the File menu, `Shift-Command-I`, and Finder drops, including “Ask Every Time” and an option to remember the chosen method.
- Videos on disconnected external drives now remain visible, searchable, and taggable with their cached thumbnails and metadata. FileFacet marks them as offline, provides a dedicated Offline collection, and restores file access automatically when an authorized drive reconnects.

### Changed

- Finder aliases, symbolic links, and macOS packages are skipped consistently when importing folders.

## [1.0.3] - 2026-07-30

### Added

- Added complete English and Simplified Chinese localization across menus, the library, import flows, tag management, settings, App Lock, errors, tooltips, and accessibility labels.
- FileFacet now follows the language configured in macOS, including the per-app language setting, and falls back to English for unsupported languages.

### Fixed

- Corrected library video-count subtitles and English singular/plural feedback for overlapping imports, removing videos, and restoring videos.

## [1.0.2] - 2026-07-18

### Changed

- “Import Videos and Folders…” accepts multiple videos, multiple folders, or a mixture in one selection, using the same import scope and processing rules as drag and drop.
- Sidebar tags can be sorted manually, by name, or by unique video count in descending order. Parent counts include all descendants, tag hierarchy remains editable while automatic sorting is active, and switching back to manual sorting restores the saved order.

## [1.0.1] - 2026-07-17

### Changed

- Published the source under the MIT License and added public build instructions, privacy boundaries, and a security-reporting entry point.
- Added GitHub Actions build checks and the GitHub Release publishing workflow.

### Fixed

- Fixed the sidebar tag group failing to collapse and expand again.

## [1.0.0] - 2026-07-16

### Initial Release

- Import videos from multiple folders, or drag multiple videos, multiple folders, or a mixture into the content area. The unified library recognizes files that were already imported.
- Import Finder tags once when a video first enters the library, then manage top-level and hierarchical tags independently in FileFacet.
- Create, rename, move, merge, and batch-select tags, assign them by dragging, apply edits later, and undo the last change.
- Browse a native three-column layout with a video grid, search, built-in categories, tag filters, details, and a remembered thumbnail size.
- Preview with Quick Look, open videos in the default player, reveal them in Finder, and copy file paths or names.
- Remove one or more videos from the library with the context menu or `Command-Delete`, keep the original files, and undo the removal.
- Keep removal undo available across imports. If the same original video was reimported, undo merges the records and restores its tags. Expired undo cleanup removes unreferenced thumbnails and file authorizations, while failed removals preserve pending tag edits.
- Protect the library with an optional authentication setting, privacy cover, idle locking, and macOS system authentication.
- Open Settings with the app menu or `Command-,` in a dedicated main-window workspace. The app-menu About command opens the About section and shows the current version and build.
- Maintain imported video locations and deletion state silently; newly discovered videos always require manual import.

### Fixed

- Fixed the inline field disappearing immediately after creating a tag from the sidebar.
- Fixed dragging multiple selected tags moving only one tag.
- Fixed an old search query remaining active after import and hiding videos after selecting another tag.
- Unified import progress, cancellation, and results below the content title so completed results no longer occupy the window title.
- Added stage and batch progress for multi-file drops, while continuing with remaining files after one file fails.
- Used the system copy or prohibited cursor while videos are dragged over the content area, keeping the grid fully visible.
- Fixed temporary sandbox URLs from Finder drops being mistaken for failures to establish persistent access.
- Merged overlapping parent folders, child folders, and contained files, with separate feedback for empty folders, processing failures, and unreadable items.

# Changelog

This file records the user-visible changes in FileFacet releases.

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

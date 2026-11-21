# Tagivy — Local-first Video Tagging for macOS

> Tagivy has a new macOS app identity. An existing FileFacet library, settings, thumbnails and folder permissions are not imported automatically. Keep FileFacet and its data if you need that library.

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/app-icon-256@2x.png" width="128" alt="Tagivy macOS video tag manager app icon">
</p>

English | [简体中文](README.zh-CN.md)

Tagivy is a native, local-first macOS video tag manager for organizing videos across multiple folders with hierarchical tags. Your original files stay in place and remain read-only.

[Download the latest release](https://github.com/larryisthere/FileFacet/releases/latest) · [Browse all releases](https://github.com/larryisthere/FileFacet/releases)

> Tagivy supports English and Simplified Chinese and follows the language configured for the app in macOS.

<p align="center">
  <img src="docs/assets/readme/filefacet-video-tag-manager.png" alt="Tagivy local-first macOS video tag manager with a hierarchical tag tree, searchable video grid, and batch tag editing">
</p>

## Who Tagivy is for

Tagivy is designed for people who keep videos locally and want a flexible way to organize them without changing their folder structure:

- Creators managing footage across projects and storage locations
- People organizing personal or private video collections
- Anyone who needs tags for people, sources, purposes, status, or other overlapping categories
- Mac users who want an app-specific hierarchy beyond Finder's flat tags

## Why Tagivy

- **One library across folders** — import individual videos, multiple folders, or a mixture of both into one searchable library.
- **Folder structure to tags** — optionally turn nested folders into hierarchical tags while importing, with control over whether each selected folder becomes a root tag.
- **On-demand new-video scans** — check previously selected folders for videos that have not entered Tagivy yet, preview the results, and import all or only the items you choose.
- **Offline external libraries** — keep browsing, searching, and tagging indexed videos while an external drive is disconnected, then restore file access automatically when it reconnects.
- **Hierarchical video tags** — build multi-level tag trees, batch-edit assignments, merge tags, add colors, and organize tags with drag and drop.
- **Smart filters and collections** — combine tags, filename, dates, media properties, and sorting, then save a reusable Smart Collection with live results.
- **Files stay where they are** — Tagivy reads original videos without moving, renaming, modifying, or deleting them.
- **Local-first and private** — the library index, tags, access permissions, and thumbnails stay on your Mac. Tagivy makes no network requests by default.
- **Native macOS workflow** — use Quick Look, open videos in your default player, reveal files in Finder, and protect the library with optional system authentication.

If Tagivy fits your workflow, [star the repository](https://github.com/larryisthere/FileFacet) to support its development and find it again.

## How it works

1. Choose **File > Import Videos and Folders…** or drag videos and folders into Tagivy.
2. For folder imports, choose direct import or create hierarchical tags from the directory structure. Tagivy can remember this preference.
3. Use the toolbar or **File > Scan for New Videos** to review videos added later to those folders, then import all or only the selected results.
4. Existing Finder tags are imported once when a video first enters the library.
5. Create hierarchical tags, apply them to one or many videos, and combine filename, tag, date, duration, file-size, or resolution filters.
6. Save a useful combination as a Smart Collection, or keep it as a temporary view.
7. Preview with Quick Look, open a video in your default player, or reveal it in Finder.

Repeated imports are safe: the same file keeps a single library record, including when parent folders, child folders, and individual videos overlap.

## Features

### Organize

- Multi-level tags with custom order, name sorting, and video-count sorting
- Optional hierarchical tag creation from folder structure during import
- Single- and multi-video tagging with selected, unselected, and mixed states
- Drag videos onto tags or tags onto videos
- Tag creation, renaming, reparenting, merging, colors, and single-step undo
- One-time Finder tag import into independent Tagivy tags

### Find and browse

- Temporary filename search with `Command-F`
- Combined filename, tag, untagged, date, duration, file-size, and resolution filters
- Visible all/any condition relationships that remain within the selected category or tag scope
- Sorting by filename, dates, duration, file size, or resolution
- Saved Smart Collections with live counts, preview, revert, update, save-as, rename, and deletion
- Recursive parent-tag filtering
- Untagged and recently added collections
- On-demand scans with temporary Quick Look previews, selectable results, and automatic reveal of completed imports
- A conditional Offline collection for videos whose external drive is disconnected
- Video thumbnails plus grouped file, video-codec, and audio-codec source information
- Quick Look, default-player playback, Finder reveal, and path copying

### Protect your library

- Optional app lock using macOS system authentication
- Privacy shield when the library is locked
- Configurable idle locking
- Local storage for the index, tags, bookmarks, and thumbnails
- Read-only access to original videos

### Keep locations current

- Stable file identity prevents duplicate records across imported sources
- Background maintenance follows supported moves and renames
- Cached thumbnails, metadata, and tags remain available while an external drive is offline
- Authorized external-drive locations restore automatically after reconnection
- Missing and deleted files are reconciled without changing the originals

## Download and install

### Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel Mac

### Installation

1. Open the [latest GitHub Release](https://github.com/larryisthere/FileFacet/releases/latest).
2. Download the `Tagivy-<version>-<build>-macOS-universal.zip` asset.
3. Unzip it and move `Tagivy.app` to your Applications folder.
4. Open Tagivy and import the videos or folders you want to organize.

Public release builds are Universal Apps signed with Developer ID and notarized by Apple. Each release also includes a SHA-256 checksum.

## Supported video formats

- MP4
- MOV
- M4V
- MKV
- AVI
- WebM

Media playback and preview availability can depend on the codecs supported by the installed macOS version and the user's selected apps. Tagivy falls back to a generic video icon when both AVFoundation and Quick Look cannot decode a frame.

## Privacy and file safety

- Tagivy makes no network requests by default.
- Tags, the file index, access permissions, and thumbnails are stored locally.
- Logs exclude full file paths, filenames, tag contents, and bookmark data.
- Original videos are opened with read-only access.
- Removing a video from the Tagivy library leaves the original file untouched.

The optional app lock protects access to Tagivy. It does not encrypt the original video files.

## Frequently asked questions

### Does Tagivy move or modify my videos?

No. Tagivy indexes videos in their existing locations and keeps read-only access to the originals.

### Does Tagivy write to Finder tags?

No. Finder tags are read once when a video first enters the library. Imported tags then become independent Tagivy tags, so later edits in either system do not change the other.

### Can I import from multiple folders?

Yes. Videos, folders, and mixed selections share one library, tag tree, search scope, and filtering space. Folder imports can remain direct or create hierarchical tags from their directory structure. The selected folder itself is excluded from the tag tree by default and can optionally become a root tag.

### Does Tagivy upload library data?

No. Tagivy makes no network requests by default, and library data stays on the Mac.

### What happens when a video moves?

Tagivy uses file identity and authorized source locations to maintain the library record when supported moves or renames are detected.

### What happens when an external drive is disconnected?

Indexed videos remain in the library with their cached thumbnails, metadata, and Tagivy tags. Offline videos are clearly marked and can still be searched or reorganized. Actions that need the original file stay unavailable until the authorized drive reconnects, when Tagivy restores access automatically.

## Build from source

Building Tagivy requires Xcode 16 or a compatible newer version.

```bash
xcodebuild \
  -project VideoTagManager.xcodeproj \
  -scheme VideoTagManager \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The local development script is `./script/build_and_run.sh`. It builds, signs, and launches the app, so configure your development signing in Xcode before using it.

Ruby and Bundler are only required for the Fastlane release workflow documented in [docs/release.md](docs/release.md).

## Project structure

- `App/` — application lifecycle and window coordination
- `Core/` — database, file access, scanning, media, and security services
- `Features/` — library, settings, and app-lock interfaces
- `Tests/` — automated checks for core models and services
- `docs/product/` — current requirements and acceptance records
- `docs/architecture/` — accepted architecture decisions
- `docs/release.md` — local, GitHub, and App Store release workflows

Automated checks validate only their stated assertions. Product logic, interaction, and UI remain subject to user acceptance.

## Contributing and security

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Report vulnerabilities privately by following [SECURITY.md](SECURITY.md).

## License

Tagivy is available under the [MIT License](LICENSE).

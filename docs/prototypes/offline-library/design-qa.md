# 不可用视频原型 Design QA

- Source visual truth: `../manual-video-import/index.html`
- Supporting visual truth: `../folder-structure-tags/index.html`
- Implementation: `index.html`
- Intended viewport: desktop macOS window, minimum width 1020 CSS px
- State: normal library, external disk offline, unavailable file, mixed unavailable results, multi-selection and recovery
- Source capture: unavailable
- Implementation screenshot: unavailable
- Pixel dimensions and density normalization: unavailable

## Product scope

This prototype covers the accepted product direction for one unified unavailable-video entry:

1. The sidebar always shows `所有视频`, `未打标签`, `最近添加` and `不可用视频` in a fixed order.
2. Holding Command temporarily replaces the four counts with `⌘1` through `⌘4`; releasing Command or losing focus restores the latest counts.
3. `Command-1` through `Command-4` switch the four preset categories, including while an input has focus.
4. Videos on an offline external disk remain in active library results and also appear under `不可用视频`.
5. A file confirmed outside healthy known locations or moved into the Trash leaves active results and remains under `不可用视频` with its thumbnail, tags and media information.
6. Access loss and a file leaving its known location share the user-visible `无法访问` state; offline videos continue to use `离线`.
7. The unavailable category replaces `标签｜详细信息` with `处理｜详细信息`, defaults to `处理`, and restores the normal Inspector modes after leaving the category.
8. The resolve pane gives unavailable records a full-width relink action and shows one status, the last-known location, one preservation promise and two actions. Offline records explain automatic recovery; multi-selection only offers batch removal.
9. Right-clicking an unavailable record opens a state-specific menu with relink when supported and removal for all unavailable states.
10. Reconnecting a disk restores only offline records. Relinking restores an unavailable record, while confirmed removal deletes retained FileFacet records in the prototype state.
11. Relinking enters a disabled verification state, then produces one of four visible outcomes: verified success, an uncertain match requiring user confirmation, an existing-record conflict with `查看已有视频`, or another failure with `重试`.
12. An uncertain match shows the original and selected file differences, defaults to `重新选择`, and requires an explicit `仍然连接` before changing the retained record.
13. Relink result notifications reuse the content-area status bar, expose an independent close button, and end when the user switches preset browsing context.

The real file chooser, database migration, persistent state transitions, batch removal and system menu registration have been implemented and accepted in the currently executable user scenarios. External-device offline and recovery behavior remains a device acceptance item.

## Visual continuity

- Reuses the accepted three-pane macOS window proportions, system sidebar density, semantic colors and shared prototype shell.
- Keeps all four preset categories visible so their positions and shortcuts remain stable.
- Uses the count column itself for transient shortcut hints, preserving row width and label alignment.
- Uses the existing repository-owned fictional poster assets as realistic cached thumbnails.
- Applies the same unavailable scrim to retained cards, with `离线` and `无法访问` badges matching the three-state product model.
- Keeps retained media fields in the existing details structure and makes resolve actions a dedicated Inspector mode, so they never compete with the tag-editing footer or depend on detail scrolling.
- Uses full-width primary actions in the narrow Inspector and lowers the visual weight of destructive removal.
- Keeps implementation terms such as persistent-access recovery and cached thumbnails out of user-facing resolve copy.
- Hides tag editing only while browsing the unavailable worklist; ordinary library contexts retain `标签｜详细信息`.
- Uses an in-prototype removal dialog instead of a browser-native confirmation prompt.
- Keeps relink feedback in the always-visible content status bar; window titles and subtitles are not used as feedback surfaces.
- Adds prototype controls for reviewing relink success, existing-record conflict and retryable failure without depending on a real file chooser.
- Adds a window-level comparison dialog for evidence that cannot safely establish content identity; filename, path and media attributes do not silently approve a relink.

## Static verification

- Browser rendering and visual comparison are intentionally not performed under the project verification boundary.
- Inline JavaScript syntax parses successfully.
- All document IDs are unique, and every `getElementById` reference resolves.
- Shared prototype CSS and JavaScript are referenced once per prototype page.
- CSS braces are balanced.
- `git diff --check` passes.

## Findings

- Browser-rendered layout, clipping, dark mode, segmented-control switching, custom context-menu placement, Command-key event delivery and interactive hit areas remain unverified.
- VoiceOver behavior for dynamically switching Inspector modes remains unverified by automated tooling.
- Real external-volume transitions and recovery remain device acceptance items because no external device was available during this acceptance round.

final result: prototype and currently executable implementation scenarios accepted; browser-rendered visual comparison and external-device recovery remain unavailable

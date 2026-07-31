# 离线资料库原型 Design QA

- Source visual truth: `../manual-video-import/index.html`
- Supporting visual truth: `../folder-structure-tags/index.html`
- Implementation: `index.html`
- Intended viewport: desktop macOS window, minimum width 1020 CSS px
- State: normal library, external disk offline, offline filtering and automatic recovery
- Source capture: unavailable
- Implementation screenshot: unavailable
- Pixel dimensions and density normalization: unavailable

## Product scope

This prototype intentionally covers one minimum viable path:

1. An external disk becomes unavailable.
2. Cached thumbnails, filenames, media information and tags remain browsable and searchable.
3. A lightweight badge marks affected videos.
4. The system-provided `离线` category appears only while offline videos exist.
5. The existing inspector's `详细信息` segment shows offline state as one ordinary field.
6. Reconnecting the disk removes the category and badges and restores the normal access field, without adding a global recovery message.

Permission recovery, manual relinking, source management, optional thumbnail caching and failure-detail lists remain outside this prototype.

## Visual continuity

- Reuses the accepted three-pane macOS window proportions, system sidebar density, semantic colors and bottom prototype controls.
- Uses the existing repository-owned fictional poster assets as realistic cached thumbnails.
- Keeps offline cards in the normal grid without extra borders or a separate staging surface.
- Adds a 50% black scrim over offline thumbnail images so they read as temporarily unavailable while retaining their original color; the badge, filename, duration, selection and hover feedback remain fully legible.
- Matches the AppKit video item: 150–180 px prototype width, 8 px inner padding, 0.55-height thumbnail, centered filename and duration beneath the thumbnail.
- Matches the existing inspector structure: `标签 / 详细信息` segmented control, searchable checkbox list, vertical detail fields and tag-draft action area.
- Removes the prototype-only inspector heading, access card, tag pills, Finder action and toolbar open buttons.
- Adds information only where it changes the user's next action: card badge, conditional system category and one standard inspector detail field.

## Static verification

- Browser rendering and visual comparison are intentionally not performed under the project verification boundary.
- Inline JavaScript syntax parses successfully.
- All document IDs are unique, and every `getElementById` reference resolves.
- All eight local thumbnail assets and both related prototype links resolve.
- `git diff --check` and trailing-whitespace checks pass.

## Findings

- Browser-rendered layout, clipping, dark mode and interactive hit areas remain unverified.
- Real external-volume removal and reconnection behavior remains an implementation-stage device acceptance item.

final result: user accepted on 2026-07-31; browser-rendered visual comparison remains unavailable

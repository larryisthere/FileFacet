# 文件夹导入方式原型 Design QA

- Source visual truth: `../manual-video-import/index.html`
- Supporting visual truth: `../deferred-tag-editing/index.html`, `../tag-sorting/index.html`
- Implementation: `index.html`
- Intended viewport: desktop macOS window, minimum width 1020 CSS px
- State: existing import flow plus folder-method Sheet and import preference
- Source capture: unavailable
- Implementation screenshot: unavailable
- Pixel dimensions and density normalization: unavailable

## Full-view comparison evidence

The project verification boundary does not authorize opening or operating the App or prototype, and the prior in-app browser attempt rejected local `file://` navigation. A browser-rendered comparison cannot be claimed.

## Focused region comparison evidence

Unavailable for the same reason. Source-level implementation reuses the existing prototype's macOS window proportions, three-pane layout, compact controls, system-picker Sheet, status feedback, typography stack and color tokens.

## Static verification

- The inline JavaScript compiles successfully.
- Every `getElementById` reference resolves to a unique document element.
- `git diff --check` passes.
- Related prototype links resolve to existing local HTML files.

## Primary interactions implemented

- File menu and `Shift-Command-I` open the existing system-picker simulation.
- Selecting only video files starts the existing import flow without showing the folder-method Sheet.
- Selecting or dropping a folder shows the folder-method Sheet while the preference is `每次询问`.
- The Sheet offers direct import or directory-tag creation, plus an option to persist the choice.
- Directory-tag creation offers a default-off option to include each selected folder itself as a root tag.
- The Sheet explains both mappings with concrete examples: `日本 › 东京` and `旅行素材 › 日本 › 东京`.
- Root-level videos inherit the selected-folder tag when root inclusion is enabled.
- A saved default lets menu, shortcut and folder drop continue directly without showing the Sheet.
- Settings exposes one shared three-state preference: ask every time, direct import, or import with directory tags.
- Settings also exposes the shared default for including selected folders as root tags; direct import disables the irrelevant control.
- Settings can restore `每次询问` after the Sheet has been suppressed.
- Direct import and directory-tag import share the same progress and completion surfaces.
- Empty inspector tag groups are omitted.
- Directory-tag completion reports new videos, existing-video updates, created tags and omitted items in one summary.
- Original videos remain read-only; Finder tags coexist with directory tags.

## Findings

- Browser-rendered layout, typography, clipping, dark-mode appearance and interaction hit areas remain unverified.
- Console errors during real browser interaction remain unverified.

## Comparison history

No visual comparison iteration was run under the current verification boundary.

final result: blocked

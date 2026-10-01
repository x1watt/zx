# ZX Explorer UI Improvement Plan

**Status:** Planning only. No UI or cache implementation has started.

## Goal

Make ZX comfortable as a daily file manager first, with archive browsing and ZX-specific tools close at hand. The interface should feel immediate, visually calm and consistent on desktop and narrow screens. Keep the existing archive formats, filesystem operations, keyboard shortcuts and platform integration working.

## What the review found

- The app already browses normal folders and archives through a shared explorer, with places, breadcrumbs, details/grid views, a preview pane, selection actions, drag-and-drop and responsive phone layout.
- `ZxArchive` operations and filesystem listing/search/copy work run in isolates. The app already has lazy list/grid builders and a transient Flutter image cache for local raster files, but archive items do not get grid thumbnails and thumbnails do not persist between launches.
- A click in an icon/touch view resolves its item by scanning the current rows (`_fsEntry` and the archive handler's local `item` lookup). Full-page listening to filesystem/archive selection changes also rebuilds much of the shell. The archive folder tree recomputes and sorts folders during traversal/build. These are concrete candidates for the perceived button/click delay, especially in large folders.
- The visual language is functional Material 3, but the header, action bar, sidebar, list, grid, preview and phone layout do not yet read as one deliberately prioritized file-manager surface.
- The project already exposes the pieces needed for an archive-backed cache: `.zx` create/open/read/add/delete/compact operations; `ZxItem.sha256` where available; isolate-backed extraction; and app data paths. `.zx` updates append generations, so cache growth and compaction must be part of the design rather than an afterthought.

## Design direction

- **Explorer first:** make the current location and files the visual focus. Keep navigation, search and view controls in a compact top band; place common file actions in a contextual toolbar; move infrequent archive/database functions into clearly named menus and context menus.
- **Progressive disclosure:** folders and ordinary files behave like a familiar file manager. Show archive identity and quick actions (open, extract, test, create/update) when relevant, without making every folder view look like an archive utility.
- **One visual system:** define spacing, row/tile sizes, border and surface treatments, selected/hover/focus states, icon sizes, typography and light/dark color tokens, then apply them consistently to desktop and narrow layouts. Keep dense details mode available for power users.
- **Responsive, not merely compressed:** desktop keeps optional places and preview panes with resizable/collapsible boundaries; narrow mode prioritizes path, search, file content and selection actions. Make empty, loading, error, read-only and long-running-operation states clear and non-blocking.

## Concrete implementation sequence

### 1. Establish interaction and rendering baselines

- Profile a debug/profile build with small and large directories, a large archive listing, grid thumbnails, rapid selection and search. Record tap-to-visible-feedback/frame timings and frame/build costs before changing behavior.
- Add temporary or test-only timing/instrumentation around shell rebuilds, list filtering/sorting, tree construction, thumbnail cache misses and archive cache operations; remove noisy diagnostics before completion.
- Confirm the current Flutter/Dart toolchain and establish the app checks: `flutter analyze`, `flutter test`, and focused explorer/integration tests. Do not use compression benchmarks as a substitute for UI responsiveness measurements.

### 2. Remove avoidable input-to-feedback work

- Build path-to-entry maps with each filesystem/archive listing (or equivalent cached lookup) so click, open and context-menu handlers are O(1), not a scan through visible rows.
- Keep selection changes local to the view/action/status widgets that need them. Avoid rebuilding navigation, sidebar places, preview and the entire shell for each selection; preserve current model APIs and their test seams.
- Cache folder-tree child lists/visible nodes for a listing generation and invalidate them only on navigation, expansion or archive refresh. Avoid repeated `folders(path)` sorting while building each node.
- Audit other work on tap paths (row conversion, repeated statistics, context-menu creation). Move expensive computation off the synchronous pointer event; show immediate pressed/selected feedback before any awaited operation or dialog.
- Preserve stale-result cancellation and loading feedback for asynchronous navigation/search; ensure keyboard focus and double-click/tap semantics remain unchanged.

### 3. Redesign the explorer surface

- Refine `buildTheme` and shared UI components to establish the visual system: consistent surface hierarchy, restrained accent use, predictable hover/focus/selection feedback, readable contrast, and polished light/dark themes.
- Simplify the desktop header into navigation/path, search and view/menu controls with clear separation. Make archive-aware actions contextual and group them by frequency; retain the full ZX feature set in menus and context menus.
- Improve file rows and icon tiles: clearer name/type hierarchy, comfortable but efficient spacing, useful metadata, deliberate selected/hover/drop states, and consistent icon/thumbnail framing. Keep sortable details columns and the current power-user keyboard behavior.
- Rebalance the sidebar, archive tree and preview pane so they support rather than compete with the file list. Retain resize behavior and add a straightforward way to hide optional panes when useful.
- Rework the narrow layout around thumb-friendly navigation and selection actions, including readable path/search states and enough room for long names. Review empty/loading/error states throughout.
- Update the welcome screen and settings presentation to match the explorer design, while preserving existing settings and preferences.

### 4. Add persistent thumbnails stored in a `.zx` cache archive

- Add a thumbnail service behind the app layer, using a dedicated app-owned archive such as `<dataHome>/zx/thumbnails.zx`; never place cache data in the user's browsed folders or in the archive being previewed. Add only the minimal path/service injection needed to keep tests isolated.
- Start with the raster formats the grid already recognizes. Make a single canonical thumbnail rendition (for example, 256 device-independent pixels at a versioned encoding) so grid, phone and preview consumers can reuse it. Do not add video/SVG decoding as part of the first pass.
- Derive cache identity from content SHA-256 when the archive provides it (notably `.zx`). Otherwise use a stable source identity plus cheap change signals (canonical path, size, modified time; archive path/entry path and available CRC/size/generation). Include a thumbnail-format/version token in the key. Avoid hashing every local image merely to show a tile.
- On a hit, asynchronously read the small encoded thumbnail from the `.zx` cache via `ZxArchive.readBytes`; display it through an image provider keyed by its cache key so Flutter can reuse decoded images. On a miss, read/extract the source without blocking the UI isolate, decode at a bounded target size, encode a small raster thumbnail, then enqueue a batched archive update. For archive entries use the existing isolate-backed archive read/extract APIs; do not synchronously decode archive bytes in a pointer callback.
- Make thumbnail generation lazy/visible-first, bounded in concurrency, deduplicated for repeated requests, cancelable when a folder/view is abandoned, and tolerant of unsupported/corrupt/oversized images. Fall back immediately to the current file icon. Apply limits to source size, decoded dimensions and output size to avoid memory spikes.
- Serialize cache writes (including across app instances where supported), batch additions, and treat cache failures as non-fatal to browsing. Keep thumbnails and a small manifest/index in the `.zx` archive. Enforce a documented size budget and least-recently-used eviction; because `.zx` is append-only across updates, compact after eviction/periodic thresholds and recover cleanly from a corrupt or interrupted cache. Recreate the cache rather than blocking the explorer if it cannot be opened.
- Add tests for cache hit/miss, invalidation after a source changes, identical-content reuse where a SHA is available, archive-entry thumbnails, cancellation/fallback, eviction/compaction, and isolated temporary paths. Measure first-open and warm-open rendering separately.

### 5. Validate and tune the end-to-end experience

- Add/adjust widget tests for desktop and narrow layouts, action availability, focus/selection feedback, keyboard navigation, view switching and thumbnail placeholders/hits.
- Run `flutter analyze`, the full `flutter test` suite and relevant Linux integration tests against filesystem folders and representative archives, including `.zx` and nested archives. Keep existing app tests green or update only expectations intentionally changed by the new design.
- Repeat the baseline interaction profiling. Confirm that tap-to-feedback is immediate, scrolling remains smooth with many rows/tiles, thumbnail work is bounded, cache hits avoid archive decoding, and cache misses do not freeze navigation. Fix regressions before calling the UI refresh complete.
- Review accessibility basics: contrast, tooltips/labels, keyboard reachability, focus visibility, touch targets and text scaling.

## Completion criteria

- Common file actions show visible feedback immediately; selection/click handlers do no full-list lookup, archive decode, synchronous disk operation or thumbnail generation.
- Large listings remain lazy and responsive; sidebar/tree and selection updates do not trigger unrelated expensive rebuilds.
- Local and supported archive images show persistent, correctly invalidated thumbnails from an app-owned `.zx` archive, with safe icon fallback and bounded cache growth.
- Desktop and narrow layouts share a coherent visual hierarchy, and existing filesystem, archive, nested archive, ZX-specific and keyboard workflows continue to pass tests.

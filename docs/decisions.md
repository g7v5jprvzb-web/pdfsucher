# Decisions

## 2026-11-12 — SQLite: system library is sufficient (Task 0.2)

- Linked SQLite at runtime (macOS system `libsqlite3`, `import SQLite3`): **3.51.0**
- FTS5 (`ENABLE_FTS5`): **yes**
- `trigram` tokenizer: **yes**
- `remove_diacritics 1` on trigram (`'Vertragsänderung' MATCH 'anderung'`): **yes**
- Consequence: the system SQLite is used; **no amalgamation is embedded**. Verified by
  `SQLiteCapabilityTests` (`fts5Available`, `trigramWithDiacriticsAvailable`), which will
  fail loudly if a future OS drops these capabilities.

## 2026-11-12 — Phase 0 review outcomes (contract notes for Phases 1–4)

- `ViewerModel` is class-bound (`AnyObject, Observable`) so views holding `any ViewerModel` can
  mutate it. Phase 4: use `Binding(get:set:)` on the existential; `@Bindable` does not work on it.
- `SQLiteConnection` sets a 5 s busy timeout. Phase 1: `IndexStore` may delete and rebuild the
  index only on `SQLITE_NOTADB` (26), `SQLITE_CORRUPT` (11) or a schema-version mismatch, never on
  other errors such as `SQLITE_BUSY`.
- Phase 1: keep `transaction` bodies to SQL only (extract text before), because the connection
  serialises all callers, including searches, for the whole transaction.
- Phase 1: rows are keyed by column name, so alias computed columns
  (e.g. `bm25(pages_words) AS score`).
- Text binds and reads use explicit byte lengths, so text containing NUL round-trips intact.
- `PDFFixtures.makePDF` throws `textDoesNotFit` instead of silently cutting off text that does
  not fit one A4 page (12 pt Helvetica); Task 1.4's generator must keep pages within that limit.
- Public memberwise inits on the shared value types are deliberate additions to the plan's
  interface blocks (the plan omitted them; other modules could not build values without them).

## 2026-11-12 — Phase 3: page identity is the exact URL (contract note for Phases 1, 2, 4, 5)

- `PageRef`, `PageSelection` and `Merger` compare URLs exactly (`URL ==`), not by file identity.
  `/docs/A.pdf`, `/docs/./A.pdf` and a relative URL to the same file are three different pages,
  so ticking "the same" page via two spellings would put it twice into a merged PDF.
- Therefore every `PageRef.url` and every grid-order URL must be taken from `DocumentHit.url`,
  never rebuilt elsewhere. Remaining risk for Phase 5: single-file mode (open-panel URL, possibly
  NFD) and folder mode (`root + relativePath`, NFC) can yield two URLs for the same file if the
  selection is kept across a mode switch.
- Documents selected in an earlier search but missing from the current grid are merged after the
  grid's documents, in Finder order of their path (`localizedStandardCompare`).
- `DefaultFileName` drops invisible format characters (soft hyphen, bidi overrides, BOM) but keeps
  zero-width joiners and tag characters (emoji flags), replaces `/ : \ * ? " < > |` and control characters with `-`, and limits the
  term to 120 UTF-8 bytes.

## 2026-11-12 — Phase 3: Merger/Printer notes (for Phases 4 and 5)

- **Plan gap:** `OutputError.writeFailed(URL)` carries no reason, but the spec's error table asks for
  "Fehlermeldung mit Grund". `Merger.write` logs the underlying error (`os.Logger`, subsystem
  `local.pdfsucher`, category `output`); the UI can only say *that* writing failed. Extending the
  error with a reason would change a planned public type, so it is left to Phase 5 / Chris.
- `Merger` is a stateless `Sendable` struct: create it inside the background task that merges.
  `makeDocument` returns a non-Sendable `PDFDocument`; do not pass it across actors.
- `Merger.write` replaces an existing destination via `FileManager.replaceItemAt` (keeps
  permissions, extended attributes, Finder tags; atomic). Writing over one of the source files works.
- Internal links in merged pages point to the merged copy of their target page (first occurrence)
  and are removed if the target page is not part of the merge.
- Owner-password restrictions (no copying/printing/assembly) of source PDFs are not enforced;
  password-locked PDFs fail with `cannotOpen`.
- `Printer.printOperation` is `@MainActor` and synchronous (plan signature), so it builds the merged
  document on the main thread; a very large selection briefly blocks the UI before the dialog opens.
- `Printer.printOperation` sets `jobTitle = "Auswahl"`; Phase 4/5 should set it from
  `DefaultFileName` (without ".pdf") so "Als PDF sichern" in the print dialog suggests the same name.

## 2026-11-12 — SearchKit (Phase 2) rules and contract notes

- **Query syntax** (`QueryParser`): `"…"`, `„…“`, `“…”`, `»…«` start/end a phrase. Inside a
  token, any non-word character separates word parts (word characters: `[\p{L}\p{M}\p{N}]`).
  `E-Mail` → phrase `["e","mail"]` (the FTS5 tokenizer sees it the same way); `Ver*trag` →
  prefix `ver` AND suffix `trag`; `(Vertrag*)` keeps its wildcard. With „Wortteile finden“ on,
  a multi-part token without `*` is treated as `*token*` (outer parts open, ANDed).
- **Matching** (`PageMatcher`): phrase words may be separated by any non-word characters (plan
  said `\s+`); overlapping hits of different terms are merged and counted once; one term's hits
  are counted without overlap. Implemented as a literal UTF-16 search with boundary checks, not
  `NSRegularExpression` (4–5× faster; the semantics are documented as regex equivalents).
- **ß**: Swift folding gives `ss`, FTS5 (`unicode61`, `trigram`) keeps `ß`. `FTSQueryBuilder`
  therefore ORs `ss`/`ß` spellings and handles an `s` at an open term edge; strings the trigram
  index cannot match (< 3 code points) are left to the matcher.
- **Greek/Cyrillic**: Swift folding strips their diacritics (й → и, ά → α), FTS5 does not, so
  such terms are left out of the FTS query and checked by the matcher (scan if nothing remains).
  `SupersetTests` (seeded random texts/queries) guards "FTS only narrows, the matcher decides".
- **Open for Phase 1**: FTS5 `unicode61` treats private-use characters (e.g. Symbol-font bullets
  U+F0B7 from Word exports) as word characters, the matcher as separators, so „\u{F0B7}Vertrag“
  is not found by `Vertrag` in folder mode. Cleanest fix: the TextNormalizer maps private-use
  characters to a space.
- **IndexReading contract SearchService relies on** (Phase 1): `match` returns all rows (no
  LIMIT) for documents of any status; `bm25` is raw FTS5 (more negative = better, 0 in
  `allPages`); `text` is the normalized stored text. A `SQLiteError` from `match` makes
  SearchService fall back to `allPages()`; other errors are thrown.
- **Performance**: `SearchBenchmark` (release only: `PDFSUCHER_BENCH=1 swift test -c release
  --no-parallel --package-path Packages/PDFSucherKit --filter SearchBenchmark`) checks the
  §9 target with every one of 20,000 pages (~3 KB) as a candidate: 55–170 ms on a 16-core Mac.
  It does not include the FTS query itself (Phase 1 / Phase 5 measure that).
- **Single PDF**: `SingleDocumentSearch` caches the last document's text (key: URL +
  modification date), checks Task cancellation per page and throws
  `SingleDocumentSearchError.noText(url)` for PDFs without text (scan hint, spec §6).
- **Phase 5 follow-ups**: re-run `searchEndToEnd`-style tests against the real `IndexStore`
  (SearchKit tests use a stand-in `TestIndex` with the spec schema); assert
  `TextSourceError.unreadable/.locked` through `SingleDocumentSearch` with the real
  `PDFKitTextSource`; highlights on `PDFPage.string` need their own mapping because the
  index text is normalized.

## 2026-11-12 — Phase 4 contract notes (ViewerUI)

- `GridSettings` is `@MainActor` (it is exposed through the `@MainActor` `ViewerModel` and drives
  SwiftUI). Phase 5: construct it on the main actor, e.g. inside `AppModel`.
- `ThumbnailCache.thumbnail(for:size:highlightKey:highlightRanges:)` takes a
  `HighlightRanges = @Sendable (String) -> [Range<String.Index>]` instead of `PageMatcher` (so Phase 4
  does not depend on Phase 2). The closure receives `PDFPage.string` and must return indices into that
  string. Phase 5: pass `{ PageMatcher(query).ranges(in: $0) ?? [] }` and a `highlightKey` that changes
  whenever the query or „Wortteile finden“ changes. `ContentShell` and `PageDetailView` take the same
  closure, built from the model's `ParsedQuery`.
- `ThumbnailCache` returns `nil` for every "no thumbnail" case (missing, unreadable, locked, page out
  of range, cancelled). The tile checks the file itself to show „Datei nicht mehr vorhanden“.
- Phase 5 (`AppModel`): reset `focusedPage` when a new result no longer contains it
  (`!FocusNavigator.contains(focusedPage, in: hits)`), and return `""` as `summary` for an empty query
  (`ViewerText.summary(hits:)` says „Keine Treffer“ for `[]`, while the grid shows „Suchbegriff eingeben“).
- Keyboard shortcuts set inside the views: ⌘O / ⇧⌘O (open menu), ⌘P / ⌘S (selection bar), ⌘[ / ⌘]
  (detail ‹ ›). Phase 5: if `.commands` adds menu items with the same keys, remove them from the views
  (in-window `Menu` item shortcuts may not fire while the menu is closed).
- UI-test identifiers: `searchField`, `summary`, `resultGrid`, `documentRow`, `selectionCount`.

## 2026-11-12 — Phase 1 (IndexKit) decisions

- **Two SQLite connections in `IndexStore`** (writer + reader, WAL). Searches read the last
  committed state and never wait for an indexing transaction (a 50-file batch held the single
  connection for 1–2 s during a first index). All calls hold a shared read/write lock while they
  use a connection; recovery takes it exclusively so old handles are closed before files go.
- **Damage found during use** (`SQLITE_CORRUPT`/`SQLITE_NOTADB` from any call): the store deletes
  and recreates the file, sets `wasRebuilt`, and throws `IndexStoreError.corruptIndexRebuilt`.
  `deleteIndex()` treats it as success. A failed rebuild (disk full) is retried on the next call.
  No `PRAGMA quick_check` at open (it reads the whole file; seconds on large indexes).
- **Wipe during an indexing run** (damage rebuild from any call, or `deleteIndex`): `Indexer.update`
  notices it via the store's reset counter and indexes again (at most twice), so the index ends up
  complete; progress restarts at `(0, total, nil)`.
- **Phase 5 contract:** on `corruptIndexRebuilt` from any call, show the „Index neu aufgebaut“
  notice and start `Indexer.update` (a search right after sees an empty or partial index until it
  finishes). Before `deleteIndex()`, cancel and await the running Indexer, then re-index if wanted.
  Use exactly one `IndexStore` per folder per process (reuse it when the same folder is reopened):
  a rebuild by one instance leaves other instances on the deleted file.
- **`deleteIndex()` checkpoints the WAL** (`wal_checkpoint(TRUNCATE)` after `VACUUM`), so deleted
  text is gone from disk immediately, not only when the app quits (spec §10).
- **Concurrent `Indexer.update` calls run one after another**, each with its own progress and
  report.
- **Extraction parallelism is `activeProcessorCount - 1`** (min. 1), not the full core count:
  PDFKit extraction is synchronous on the cooperative pool; one thread stays free.
- **Unreachable paths keep their documents**: `FolderScanner.scanDetailed` reports unreadable
  subdirectories and symlinks with a missing target (e.g. unmounted volume) in
  `unreachablePaths`; the Indexer does not remove documents at or below them.
- **Stored text offsets ≠ `PDFPage.string` offsets** (whitespace collapsed, hyphenated words
  joined, ligatures expanded). For highlights (Tasks 4.2/4.3, Chris wants words split across a
  line break highlighted too) use `TextNormalizer.normalizeMapped(page.string)`: its `text` equals
  the stored page text, so the PageMatcher finds the same matches as the search; then
  `originalRange(for: NSRange)` gives the `NSRange` in `page.string` for `page.selection(for:)`.
  A joined word maps to both line parts (`Ver-\ntrag`). Ranges are UTF-16 (NSString) offsets.
- **Directory walk is breadth-first, names sorted, real directories before symlinked ones**, so a
  directory reachable twice is listed under its shallowest real path regardless of listing order.
  `relativePath` is NFC.

## 2026-11-12 — Phase 5: integration (AppModel)

- **AppModel lives in a package target `AppCore`** (not in `App/`), so it is tested with `swift test`
  like the kits (`AppCoreTests`). `App/` keeps only the window, the settings scene and
  `SystemEnvironment` (open/save panels, print dialog, Preview, confirmation), which `AppModel`
  reaches through the `AppEnvironment` protocol.
- **`FolderIndexing`** (`search`, `update`, `deleteIndex`, `wasRebuilt`) is AppModel's view of one
  folder's index; the real `FolderIndex` combines `IndexStore` + `Indexer` + `SearchService`.
  `FolderIndex.shared(root:)` keeps exactly one instance per standardized folder path and process.
- **`ViewerModel` gained `notice: String?`** (hint beside the index status: damaged index, PDF
  without text, unreadable PDF) **and `alertMessage: String?`** (error alert, e.g. saving failed).
- Index status: `.building(0, 0)` until the first progress value; `.upToDate` or `.problems` when the
  run ends; `.unreachable` when the run fails and the folder is not an existing directory (search
  keeps using the stored index). A finished run repeats the current search.
- Damaged index: a search throwing `IndexStoreError.corruptIndexRebuilt` shows an empty result plus
  the notice „Index war beschädigt und wird neu aufgebaut“ and starts the indexer (unless one runs;
  the Indexer restarts itself after a wipe). A rebuild at open (`wasRebuilt`) shows the same notice
  once per index instance. The notice disappears when an indexing run finishes.
- Sort changes re-sort the current hits (no query); „Wortteile finden“ changes re-query at once.
- The window is a single `Window` scene (one model per process).
- **Save errors name the reason (Chris, Task 5.2):** `OutputError.writeFailed(URL, reason: String)`;
  `reason` is the underlying error's `localizedDescription`, or „PDFKit konnte die Datei nicht
  schreiben“ when `PDFDocument.write` fails. Alert: „Speichern fehlgeschlagen: <Dateiname> – <Grund>“;
  the selection stays. The app's development language is German (`developmentLanguage: de`), so
  system error texts are German even when English comes first in the user's languages (checked:
  „„a.txt“ konnte nicht bewegt werden, da du nicht über die erforderlichen Zugriffsrechte … verfügst.“).
- **Highlighting words split across a line break (Chris, Task 5.3):** `AppCore.Highlighter` runs the
  PageMatcher on `TextNormalizer.normalizeMapped(page.string).text` (the same text the index search
  matched) and maps each match back with `originalRange(for:)`. A mapped range that spans a line
  break is split into one range per line, trimmed of whitespace (`Ver-` and `trag`), so tiles and the
  large view mark each part on its own line. The `HighlightRanges` interface from Phase 4 stays
  unchanged (ranges into `page.string`); no NSRange variant was needed.
- **Columns mode (Chris, Task 5.4):** `GridSettings.columnsMode` (`.fixed`/`.automatic`, key
  `grid.columnsMode`, default `.fixed`); `columns` stays 1…10. `GridLayout.metrics` gives tile size
  and tiles per row: fixed = `tileSize` as before; automatic = tile height from the row height, width
  from the A4 ratio (capped at the available width), tiles per row = `GridLayout.columns(available:
  tileWidth:spacing:)` (≥ 1, not capped at 10; superseded by the cap of 10 in Task 5.6 below). Tiles grow and shrink with window and row count in
  both modes. Toolbar: „Seiten pro Reihe: n“ + slider 1–10 + „Automatisch“ (slider disabled there,
  label shows the fitting number via the non-persisted `GridSettings.automaticColumns`); the settings
  window offers the same choice.
- **Full volume (review of Task 5.2):** `PDFDocument.write(to:)` reported success on a nearly full
  volume and left a truncated file, which then replaced the user's file. `Merger.write` now writes
  `dataRepresentation()` itself, checks size and page count of the temporary file before moving it
  into place, and maps common causes to short reasons: „Kein Schreibrecht für den Ordner „X““,
  „Volume voll“, „Volume ist schreibgeschützt“, „Ordner „X“ existiert nicht (mehr)“, „Die gespeicherte
  Datei ist unvollständig“; anything else uses the system text. Opt-in test with a real 2 MB disk image:
  `PDFSUCHER_DISKFULL=1 scripts/test.sh --filter realFullVolume` (fails with the old write path).
  German system texts were checked with a probe binary carrying `CFBundleDevelopmentRegion = de`;
  `swift test` itself runs without an app bundle and gets English system texts.
- Highlight details (review of Task 5.3): the hyphen of a split word is marked with its first part
  (`Ver-`, as Chris asked: „Trennstrich mit markieren“); overlapping mapped ranges are joined (several
  matches inside one ligature are drawn once); invisible characters the normalizer drops inside a
  match (ZWSP, soft hyphen) stay inside the marked range, which has no visible effect.
- **Fixed pages per row fill the width (Chris, Task 5.4, option A):** in fixed mode exactly n pages fill
  the available width (`GridLayout.fillingTileSize`: width = (width − (n−1)·spacing) / n, height by the
  A4 ratio); rows and window height do not matter, and the grid scrolls vertically (a tile may be taller
  than the window when n is small). The row count applies only in automatic mode
  (`GridSettings.rowsApply`); the rows stepper in the toolbar and the settings window is disabled in
  fixed mode, with a help text saying so. Before, fixed mode also fitted the tiles into the row height,
  which made them tiny in wide windows (screenshot 01 of the first UI run).
- **UI smoke test:** the identifier `documentRow` covers the whole row (header and tiles, children
  contained), so a row's checkboxes are found inside it. The sandboxed UI test runner may not write into
  the project, so `ScreenshotTests` keeps the images as attachments; export them with
  `xcrun xcresulttool export attachments`.
- **Typing delay 50 ms (Chris, Task 5.5):** `GridSettings.debounceMs` (key `search.debounceMs`, choices
  `debounceChoices = [50, 150]`, default 50; any other stored or set value becomes 50). Settings window,
  section „Suche“: „Wartezeit nach dem Tippen“ 50 ms (Standard) / 150 ms. `AppModel(debounce:)` is now
  optional: `nil` (the app) follows the setting at the time of each keystroke (`typingDelay`), tests pass
  a fixed value. With 50 ms every measured end-to-end input meets the 200 ms target (docs/performance.md).
- Review of option A: tiles are no longer capped by the row height, so `ThumbnailCache` renders at most
  `maxRenderPixelSide` = 2048 px on the long side (about 12 MB) and draws larger tiles scaled up;
  only point sizes above 20,000 pt are rejected (before, tiles above 4096 pt showed „nicht verfügbar“).
  The grid width leaves out an always-visible (legacy) vertical scroller, so the n-th tile is not
  clipped. The grid scrolls vertically only when the focus moves to another document, to the row's top.
  The row container carries the row header as its accessibility label.
- **Final review (Task 5.6):** „Suche läuft…“ (spec §4.2) shows in the status line while a search runs
  longer than 200 ms (`ViewerModel.isSearching`, set after the typing delay, cleared when the result is
  shown or the search is replaced). When the indexer itself reports a damaged (wiped) index, one new
  run is started so „wird neu aufgebaut“ is true; a second damage report in a row shows „Indexieren
  fehlgeschlagen: …“ instead of looping. NFC/NFD: Foundation file URLs on macOS use the decomposed
  file system form and compare equal, so a page ticked in folder and in single-file mode is one
  selection entry (regression test, no code change needed).
- **Chris (Task 5.6), three review points fixed for 1.0:**
  1. Saving or printing with a ticked page whose file is gone, unreadable or now too short keeps the
     spec behaviour (message names the file, selection stays); the alert additionally offers
     „Fehlende Seiten aus Auswahl entfernen“ (`ViewerModel.alertOffersRemovingMissingPages`,
     `removeMissingPagesFromSelection()`), which unticks exactly those pages (`Merger.unavailable`, same
     checks as merging, run off the main thread). Other save errors offer no such button.
  2. Opening (`openIndex`, incl. a damage rebuild) and deleting an index run off the main thread. An
     index open that finishes after a newer open of a folder or file is dropped (`openRequest`).
  3. „Index löschen …“ is disabled while no folder is open, help text „Erst einen Ordner öffnen“
     (`AppModel.canDeleteIndex`).
- **Rare letters (final review B, Task 5.6):** query terms with æ/ø/ʒ/ʼ (after folding, so also ǽ, ǣ,
  ǿ, ǯ), Cherokee letters or a combining mark skip the FTS5 lookup and are checked by the PageMatcher
  on the stored text (as Greek/Cyrillic already did): unicode61 folds them differently than Swift.
  Such terms are slower (full scan, ~50 ms on 22,000 pages, see `*ab*` in performance.md); German
  words are unaffected. Known limitation: a combining mark that does not compose with its letter
  (e.g. „x̅y“, U+0305) is removed from the query by folding before this check, while unicode61 splits
  the indexed word there, so such a word is not found (`combiningMarkInsideWordKnownLimitation`).
- **Minimum tile size in automatic mode (final review B, Task 5.6):** each row needs a fixed ~68 pt for
  header, caption and spacing, so many rows on a low grid gave 0×0 tiles and „Seiten pro Reihe: 148“.
  Tiles are now at least `GridLayout.minTileWidth` = 72 pt wide (≈ 102 pt high): the caption holds the
  checkbox (~20 pt with spacing) and „S. 1234“ (~45 pt); in the first screenshots captions were already
  cut to „S…“ at ~55 pt. When the space is too small for the chosen rows, fewer rows are visible (the
  row count is an upper bound) and the grid scrolls; tiles are never wider than the window. The tiles
  per row then stay realistic (e.g. 14 at 1,180 pt). `GridLayout.metrics(…, maxAutomaticColumns:)`
  can cap the count (prepared for Chris' pending decision about at most 10; not set yet). Superseded below in Task 5.6:
  cap 10 active, minimum width 80 pt.
- Review B minor: the keyboard-focused tile carries the accessibility trait „selected“; a click on a
  tile of another document no longer scrolls the grid (only keyboard and ‹ › moves do).
- **Printing off the main thread (Chris, Task 5.6; replaces the Phase 3 note „Printer synchronous on
  the main actor“):** `printSelection` merges the pages in a background task
  (`PrintDocument.build`, a `@unchecked Sendable` hand-over of the new `PDFDocument`, which the builder
  no longer touches) and only creates and shows the `NSPrintOperation` on the main actor
  (`Printer.printOperation(for: PDFDocument)`). Meanwhile `isPreparingPrint` shows „Druck wird
  vorbereitet…“ in the selection bar and disables „Drucken …“; a second call while preparing does
  nothing. Printing waits for a running save or „Fehlende Seiten entfernen“, so it prints the cleaned
  selection.
  Review: while printing is prepared, „Als PDF …“ is disabled and `saveSelection` does nothing (the
  print sheet would otherwise attach to the save panel); `runPrint` attaches the sheet to the visible
  main document window (identifier prefix „main“ from the `Window` scene id, never a panel or the
  settings window) and falls back to an app-modal print dialog. The window identifier is not checked by
  an automated test.
- **At most 10 per row in automatic mode (Chris, Task 5.6):** `GridLayout.maxAutomaticColumns = 10`
  (default of `metrics(…, maxAutomaticColumns:)`). When more tiles would fit, 10 tiles fill the width
  and grow accordingly (A4 ratio, same as fixed mode with 10); the grid then scrolls vertically, so the
  row count is no longer exact in very wide windows. Below 10 nothing changes.
- **Tick and page number on the tile (Chris, Task 5.6):** checkbox and „S. n“ sit top left on the
  tile as an overlay on `.regularMaterial` (readable over the page), added after the tile's click
  gestures so ticking does not also count as a click on the page; the overlay is clipped to the tile.
  Rows no longer reserve a caption line: `DocumentRow.overhead` = header 24 + 4 + scroller 12 = 40 pt
  (was 60), so automatic tiles get taller for the same row count, and a ticked page is visible without
  scrolling in fixed mode. **Minimum tile width re-justified: 80 pt** (≈ 113 pt high, replaces the
  72 pt above): the overlay needs checkbox ~14 + spacing ~4 + „S. 1234“ ~44 + padding 8 + inset 8 ≈
  78 pt inside the tile. Narrower tiles only occur in fixed mode with many pages in a narrow window;
  there the overlay is clipped.

## 2026-11-12 — 1.1: zoom levels ⌘1–⌘4 (spec 1.1 §13)

- ⌘1 „Seitenbreite“ = 100 % of the preview width; ⌘2/⌘3/⌘4 = 75 / 50 / 35 % of that width (Claude's choice,
  confirmed by the coordinator). Adjustable per level in Settings → „Vorschau“, 10–100 % in 5 % steps.
- The width is the displayed page width (rotation applied), so landscape pages fill the width too.
- A level stays a level while the window is resized (like „Ganze Seite“); +/− leave it and continue in % steps.

## 2026-11-12 — 1.1: highlights on small tiles (spec 1.1 §14)

- Threshold 280 pt of the drawn tile width (Claude's choice): below it highlights are enlarged
  (min 24 × 16 screen pt + 3 pt margin, clipped to the page, overlaps merged) and a 4 pt stripe marks
  each hit's height at the tile's left edge. Geometry is a pure function (`HighlightGeometry`), reusable
  for OCR boxes in 1.2. Colour `highlight.color`, default sRGB 1/1/0; opacities 45 % / 70 % / 100 %.

## 2026-11-12 — 1.1: small decisions taken during implementation (spec 1.1 addendum)

- **Several sources (§4):** `DocumentHit.id` is the full path; hits carry `sourceRoot` and `pageCount`.
  `LoadedSourceRef` lives in SearchKit (ViewerUI shows it), `SourceList` (overlap rules) in AppCore. Paths are
  compared standardized and with symlinks resolved; case exactly. Ties in sorting fall back to the full path;
  „Ordner“ groups by source first.
- Index status: one folder keeps the 1.0 text „Index: wird aufgebaut (n/m)“; from two folders on
  „Index Ordner i/n: n/m“. Status „nicht erreichbar“ if any folder is unreachable; the problem list prefixes
  paths with „<Ordner>/“ when there are several folders. An indexing failure or damage hint of one folder
  stays until that folder succeeds or is removed.
- Saved sources missing at launch (or whose index cannot be opened) stay remembered until „Alle entfernen“,
  so an unplugged disk comes back; the hint repeats while they are missing. 1.0 `lastFolderPath` is migrated.
- `AppModel.open(folder:)` / `open(file:)` stay as „replace all sources“ helpers (UI-test launch, 1.0 tests);
  the UI only adds and removes.
- „Index löschen …“ asks with the folder name or „aller N Ordner“; a folder removed after it was picked
  deletes nothing (never „all“).
- **Browsing (§12):** rows of files not yet indexed show „Seiten werden gelesen …“ until indexing reaches
  them; while a folder is indexed the scan fills in files not stored yet; refreshes at most once per second.
- **Toolbar:** three lines (search · view controls · status); the view controls did not fit next to the status.
- **Shortcuts (§10):** a shortcut stores the unshifted key with ⇧ as a modifier (⌘+ is the „+“ key on the
  German layout; ⇧⌘= and ⌘= also mean ⌘+ on US layouts). Plain Tab, ⌫, Esc and arrow keys are not
  assignable, also in the classic mode (they operate the window). Besides the nine fixed shortcuts of the spec
  the standard ⌘C/⌘V/⌘X/⌘A/⌘Z/⇧⌘Z/⌘H/⌥⌘H/⌘M/⌃⌘F count as taken and ⌥⌘Esc as macOS. A menu item gets a
  key equivalent only with ⌘/⌃/⌥; a plain key is named in the title („Häkchen setzen/entfernen (↩︎)“, in
  the Edit menu).
- **Keyboard (§7/§9):** classic mode: Space always ticks in the grid (as in 1.0), Return through its
  binding. With „Tab überspringt das Suchfeld“ ⇧Tab from the search field goes to the preview. Keys while
  an input method composes are left to it. Dead keys typed with the focus in the grid lose their accent
  (use ⌘F or click the field). The search field is an AppKit field whose editor does not accept dropped
  files, so a drop onto it adds a source.
- **Highlights (§14):** the stripe sits at the left edge of the page as drawn in page coordinates; on pages
  rotated by 90° it follows the page's own left edge.

## 2026-11-12 — 1.1: early search results (coordinator, spec 1.1 §5)

- `IndexStore.matchBatches` streams FTS matches in rowid order (no sort; a document's pages are contiguous).
  `SearchService.search(…, onPartial:)` reports once, after the first 3,000 candidate pages, the complete
  documents among them (verified, same page hits as in the final result).
- `AppModel`: a search still running after 100 ms shows the early documents of all sources (sorted, focus
  kept, „Suche läuft…“ stays); the final list replaces them once. Searches that finish within 100 ms show
  only their final list. Early results of an older query are dropped.
- Merging and sorting of search results and of the browse list run off the main actor; browse refreshes
  during indexing scan the folder once per indexing run and do not show „Suche läuft…“.
- Measured (docs/performance.md): first rows ≤ 160 ms for every input; the complete list of searches hitting
  almost every page of 3 × 1,000 PDFs 188–220 ms.
## 1.2 OCR-Index (Paket O1, Branch `ocr-index`)

- **R1 – Vision-Schnittstelle (Task 1, 2026-11-12, Chris' Mac, macOS 26):** Vergleich auf vier
  gerenderten Testbildern (Deutsch 64 pt mit Umlauten, Englisch 64 pt, Deutsch 18 pt mit 12 Zeilen,
  zwei Spalten), alle mit de-DE + en-US, genau, Sprachkorrektur an
  (`PDFSUCHER_R1=1 scripts/test.sh --filter R1ComparisonTests`):

  | Bild | RecognizeTextRequest | RecognizeDocumentsRequest | VNRecognizeTextRequest (Rev. 3) |
  |---|---|---|---|
  | Deutsch 64 pt | 100 %, 0,30 s | 100 %, 0,21 s | 100 %, 0,17 s |
  | Englisch 64 pt | 100 %, 0,16 s | 100 %, 0,15 s | 100 %, 0,07 s |
  | Deutsch 18 pt | 100 %, 0,30 s | 100 %, 0,25 s | 100 %, 0,23 s |
  | Zwei Spalten | 96 %, 0,20 s | 96 %, 0,20 s | 96 %, 0,14 s |

  Alle drei lieferten wortgleichen Text (dieselbe Erkennung; die 4 % sind ein „Ubergabe“ ohne Umlaut
  in allen dreien). Die Dokument-Erkennung bringt zusätzlich Absätze, Tabellen und Listen, die wir
  nicht brauchen. **Entscheidung:** `VNRecognizeTextRequest` Revision 3: gleiche Erkennung, am
  schnellsten, und synchron wie die Schnittstelle `OCRRecognizer.recognize(_:) throws` aus §12.
  Ein Aufruf blockiert seinen Thread für die ganze Erkennung (0,1–1 s je Seite); deshalb laufen im
  Indexer höchstens zwei, auf eigenen Threads statt im kooperativen Pool (siehe Phase 2). Wortrahmen kommen aus `VNRecognizedText.boundingBox(for:)`; fehlt einer,
  wird der Zeilenrahmen anteilig nach Zeichen geteilt.
- **Erkannter Text:** Zeilen in Vision-Lesereihenfolge, mit Zeilenumbruch verbunden und dann mit
  `TextNormalizer` normalisiert wie PDF-Text (Trennstriche am Zeilenende werden also genauso
  zusammengezogen). Bekannte Grenze: bei mehrspaltigen Seiten kann ein Trennstrich am Ende einer
  Spalte mit der ersten Zeile der nächsten verbunden werden, wenn Vision sie so hintereinander
  liefert. Wörter werden dort getrennt, wo der Normalisierer Leerzeichen setzt; ein Wortrahmen ganz
  außerhalb des Bildes wird verworfen. Für die Wortbereiche gibt es neu `NormalizedText.normalizedRange(forOriginal:)`
  (Umkehrung von `originalRange(for:)`).
- **§12-Ergänzung ohne Bruch:** `IndexReading.ocrWords` hat eine Standard-Implementierung `[]` in
  einer Protokoll-Erweiterung, damit bestehende Test-Fakes und SearchKit unverändert bauen.
  `IndexProgress` bekommt `phase: IndexPhase` (`.text`/`.ocr`) mit Standardwert `.text` im init.
- **Speicher (Task 3), Schema 2:** zusätzlich zu §4 die Spalte `page_text.needs_ocr`
  (Warteschlange der Phase 2, überlebt Abbruch und Neustart). Die im Plan vorgesehene Spalte
  `documents.ocr_pending` ist nach Review entfallen (doppelter Zustand; die Warteschlange liegt
  allein in `needs_ocr`). `source = 'ocr'` heißt „OCR lief auf
  dieser Seite“; findet sie nichts, bleibt die Seite wie sie war (kurzer Textlayer < 20 Zeichen,
  oder nach „neu ausführen“ das alte Ergebnis samt Wortrahmen, damit Text und Rahmen
  zusammenpassen). Ist eine PDF-Seite nicht renderbar, wird nur diese Seite abgeschlossen; nur ein
  beschädigtes Bild bekommt Status `error`. Veraltete Aufträge erkennt der Speicher an Pfad, Größe
  und Datum. Ein Dokument mit wartenden Seiten behält den
  Status aus Phase 1 (Bilder: `no_text`, eine leere Seite), sodass SearchKit (zeigt nur `ok`) es erst
  nach der Erkennung anzeigt; gemischte PDFs sind sofort mit ihren Textseiten auffindbar.
  `storeOCR`/`markOCRUnreadable` geben `false` zurück und ändern nichts, wenn der Auftrag veraltet
  ist (Dokument entfernt, Größe/Datum geändert, Seite schon erledigt). „Neu ausführen“ =
  `resetOCR()`: alle Seiten mit `source = 'ocr'` (auch beschädigte Bilder) warten wieder; der alte
  Text bleibt bis zum neuen Ergebnis durchsuchbar. `ocrCounts()` zählt Seiten/Bilder mit erkannten
  Wörtern. Der Update-Trigger der FTS-Tabellen feuert nur noch bei Änderung von `text`.
- **Phase 2 (Task 4/5, nach Gesamtreview):** Phase 1 merkt Seiten mit < 20 Zeichen **immer** für
  die Erkennung vor, auch ohne `OCRSource`. So werden auch Indexe, die mit Schema 2 vor der
  Verdrahtung (1.1-Builds) entstehen, später erkannt, obwohl ihre Dateien unverändert sind. Ohne
  `OCRSource` listet der Indexer nur PDFs und erkennt nichts. `IndexReport.noText` nennt Scan-PDFs
  wie in 1.0, außer Phase 2 läuft im selben Aufruf. Die App soll trotzdem immer `VisionOCRSource()`
  übergeben und „Texterkennung“ über `OCRSettings.recognizeText` steuern. `ocrSettings` sind pro
  Indexer fest: für geänderte Einstellungen einen neuen Indexer anlegen (`FolderIndex` hält heute
  einen pro Ordner, das muss die Verdrahtung berücksichtigen).
  `update(progress:)` = Phase 1, danach Phase 2 im selben Aufruf (Fortschritt mit `phase: .ocr`,
  gezählt in Seiten; Bild = 1 Seite); `IndexReport.ocr` (`OCRReport`) berichtet erkannt / kein Text /
  nicht lesbar / auf nächsten Lauf verschoben. `recognizePending(progress:)` = nur Phase 2 (nach
  `store.resetOCR()`). Höchstens 2 Erkennungen gleichzeitig, jede auf einem eigenen Thread mit
  QoS `.utility` (Vision blockiert seinen Aufrufer; der kooperative Pool bleibt frei).
  **Priorität `.utility` statt `.background`** (Task 6, gemessen): `.background` lässt Apple Silicon
  nur die Effizienzkerne nutzen und war ~4× langsamer (37 statt 161 Scan-Seiten/Minute, 72 statt
  290 Fotos/Minute); 3.400 Scan-Seiten hätten ~1,5 h statt ~20 min gedauert. `.utility` liegt
  weiterhin unter normaler Priorität, und bei 2 von 16 Kernen bleibt der Mac bedienbar. Jede Seite
  wird sofort gespeichert; beim Abbruch werden laufende Erkennungen noch gespeichert, dann
  `CancellationError`. Vision-Fehler lassen die Seite in der Warteschlange (nächster Lauf).
  Nicht erreichbare Dateien (gelöscht, keine Rechte, Netzlaufwerk weg) gelten nicht als beschädigt:
  `VisionOCRSource` wirft dann `VisionOCRSourceError.unavailable`, die Seite bleibt in der
  Warteschlange. Wird der Index während Phase 2 gelöscht oder neu aufgebaut, startet sie keine neuen
  Seiten mehr, und `update` beginnt von vorn. `OCRReport.noText` nennt nur Dateien, die nicht mehr
  warten. **Für die Verdrahtung in AppCore:** Phase 2 hält den Indexer belegt; für neue Dateien
  während einer langen Erkennung das laufende `update` abbrechen und neu starten (verliert nichts).
  Bilder warten nach Phase 1 als Dokument mit einer leeren Seite und Status `no_text`, erscheinen
  also erst nach der Erkennung in Treffern; `IndexReport.noText` (Phase 1) nennt keine Dateien,
  die noch auf OCR warten.
- **Wortrahmen und Drehung:** Bei Bildern beziehen sich die Rahmen auf das aufrecht gedrehte Bild
  (EXIF-Ausrichtung angewendet), bei Scan-Seiten auf die Seite wie angezeigt (Crop-Box, /Rotate
  angewendet). Gerendert wird mit 300 dpi, höchstens 6.000 px an der langen Seite (auch bei
  Großformat-Seiten, sonst Speicher im GB-Bereich). DNG: `CIRAWFilter` mit `scaleFactor` auf
  6.000 px; nicht automatisch getestet (keine DNG erzeugbar, §10), nur „kaputte .dng → nicht
  lesbar“.

## 2026-11-12 — OCR 1.2, package O2 (OCR output: highlights, thumbnails, image pages)

- **Location:** new target `MediaKit` (depends on IndexKit for `OCRWord`) holds `HighlightBoxes` and
  `ImageThumbnails`. `ImagePages` lives in `OutputKit`, because `Merger`/`Printer` need it; OutputKit
  stays independent of IndexKit. `OCRWord`/`DocumentKind` are added to `IndexKit/Models.swift` word for
  word as spec §12, with the same `import CoreGraphics` and the same position and MARK line
  (before `IndexReading`) as branch `ocr-index`, so git merges the identical hunks into one
  declaration. `ocr-index` adds more types right after it (`extension DocumentKind`, `OCRSettings`),
  which gives a small conflict whose ocr-output side is empty: take the ocr-index side.
  Check after merging that `OCRWord` is declared only once.
- **HighlightBoxes:** proportional slices are measured in UTF-16 units of the stored text (the API only
  has ranges, not the text). Spaces/line breaks between words get no rectangle; one rectangle per word
  and range, exact duplicates dropped; order = ranges, then words as given.
- **ImageThumbnails (after review):** an embedded preview (JPEG/DNG from cameras) is used when its
  long side is at least `maxPixel`, so DNG tiles do not develop the whole RAW each time; a smaller
  preview (often 160 px) would be blurry, so then the full image is decoded (ImageIO subsamples
  JPEG/HEIC, fast). Reads the primary image (HEIC may hold several). EXIF orientation is applied, so
  tiles show photos upright; never scaled up. DNG speed is not measured (no DNG fixture, spec §10):
  check with Chris' real DNG. **Contract for O1/integration:** OCR word boxes must refer to the same
  upright image (Vision with the file's orientation), otherwise highlights on rotated photos land in
  the wrong place.
- `TestSupport.ImageFixtures` renders text into PNG/JPEG/HEIC with an optional EXIF orientation tag.
- **ImagePages / Merger / Printer:** a `PageRef` is an image if its extension is one of
  `png jpg jpeg heic dng` (case-insensitive, `ImagePages.isImage`); only `pageIndex` 0 exists
  (`pageOutOfRange` otherwise), unreadable images give `cannotOpen`, and `Merger.unavailable` lists
  both. `Printer` gets image pages through `Merger`, no own code. Page: A4 in points
  595.28 × 841.89, landscape only if the upright image is wider than tall (square → portrait),
  aspect-fit inside 10 mm = 28.35 pt, centred, small images scaled up to the margins.
- **Embedded resolution and compression:** at most 3508 px on the long side (A4 at 300 dpi), so a
  50-MP photo does not blow up the PDF. PNG and images with transparency stay lossless (screenshots with text;
  JPEG would paint transparent areas black); other JPEG, HEIC, DNG are embedded as JPEG quality 0.9 (`/DCTDecode`), otherwise Quartz would store raw pixels (tens of MB per
  photo). The same image ticked twice gives two pages (each ref is decoded again).
- `ImagePages.makePage` builds the page in a one-page in-memory PDF (Core Graphics); the returned
  `PDFPage` stays valid after that document is gone (tested by rendering it afterwards).
- **Availability check (review):** `Merger.unavailable` decodes each image as a 64-px preview, the
  same decoder path as `makePage`, so „Fehlende Seiten entfernen“ removes exactly the images that
  would make saving fail. ImageIO decodes truncated files partially (missing rows grey); such files
  are accepted by both, consistently (tested for PNG, JPEG, HEIC).
- **Final review:** whether an image has transparency is read from the file
  (`kCGImagePropertyHasAlpha`), because ImageIO decodes every HEIC with an alpha channel; otherwise
  iPhone photos would be embedded as raw pixels. Known, accepted: the availability check develops a
  DNG from RAW (slow for many DNGs; unmeasured, no DNG fixture); overlapping but different match
  ranges inside one word give overlapping highlight rectangles (rare). For the UI wiring: ViewerUI
  will need MediaKit (and thereby IndexKit); a helper mapping the normalized top-left boxes into
  PDFKit page space (crop box, rotation) for scan PDFs is still to be written.

## 2026-11-12 — 1.2 integration (OCR in app and UI)

- **Merge:** `ocr-index` and `ocr-output` merged into main after v1.1.0. `IndexKit/Models.swift` combines both:
  the 1.1 `matchBatches`/`allPagesBatches` and the O1/O2 OCR types (taking only the ocr-index side would have
  dropped the 1.1 early-results interface).
- **Queue:** phase 1 (text, images listed) of every folder runs before any phase 2 (`recognizePending`), so a new
  folder is never stuck behind a long photo recognition; a phase-1 request (new folder, re-index, settings)
  cancels a running recognition (finished pages kept) and it resumes afterwards. Single files (PDF or image) use
  the same queue. ✕ „Texterkennung anhalten“ until „Fortsetzen“, OCR off→on, a new source or the next start.
- **Status:** „Texterkennung 120/3.400“ („… Ordner 2/3: …“ with several folders). With recognition on, phase 1's
  „ohne Text“ (scans waiting for OCR) is not reported; only what recognition found no text in.
- **Single files:** recognized pages are kept in memory for the session (no index for single files) and belong to
  the file version they were made from; a changed file is recognized again.
- **Highlights:** `OCRMapping.pageRect` maps normalized top-left boxes into PDF page space (crop box, /Rotate),
  verified against PDFKit's `transform(for: .cropBox)`; word slices from `HighlightBoxes` feed the 1.1
  `HighlightGeometry`. Pages recognized without words keep the marks of their text layer. The large preview
  marks OCR pages with highlight annotations, tagged with the page they belong to.
- **Images in the UI:** shown as a one-page in-memory PDF (`PDFPage(image:)` of the upright image), so zoom and
  marks work unchanged; tiles decode at the tile's size and are not kept as documents; the preview decodes at
  4,000 px off the main actor. 100 % zoom of an image means one point per decoded pixel (not its true size).
- **Copy:** status „· n Dateien nicht lesbar · m Dateien ohne erkannten Text“; notices „Bild kann nicht gelesen
  werden“, „Im Bild wurde kein Text erkannt“, „Texterkennung ist aus: Bilder und Scans werden nicht durchsucht“.

### 1.2 Abschluss: kleinere Review-Punkte (2026-11-13)

- Eine einzelne Datei, die während einer Ordner-Erkennung hinzukommt, wird zuerst erkannt. Die Ordner-Erkennung macht danach dort weiter, wo sie stand.
- „Nicht lesbar“ und „ohne erkannten Text“ werden nach jedem Erkennungslauf aus dem ganzen Index gelesen (`Indexer.problems`), nicht nur aus den Seiten dieses Laufs. Ein unterbrochener Lauf verwirft seinen Bericht, also gingen Funde sonst verloren. Nach einem Neustart erscheinen die Listen wieder, sobald ein Lauf stattfindet.
- Suchtreffer eines einzeln hinzugefügten Bildes tragen `isImage` und zeigen deshalb das Fotosymbol.
- Wurde eine einzelne Datei seit ihrer Erkennung verändert (Größe oder Datum laut `FileStamp`), liefert `ocrText` nil, bis sie neu erkannt ist. So bleiben keine alten Wortkästen auf der neuen Fassung stehen.
- Vision läuft für einzelne Dateien auf einem eigenen Thread mit QoS `.utility` (`SingleFileOCR.recognizeOnThread`), wie in Phase 2. So blockiert Vision keinen Thread des kooperativen Pools.

## 2026-11-13 — 1.2.1: Pfeiltasten beim ersten Start (Fehler von Chris)

- **Ursache:** `KeyRouting.decide` gab Pfeiltasten immer unverändert weiter (`passThrough`). Sie wirkten nur über das `onKeyPress` des Rasters, und das setzt voraus, dass das Raster den SwiftUI-Fokus hat. Beim ersten Start hat aber kein Bereich diesen Fokus: weder ein Klick noch Tab noch Return hat ihn bis dahin ins Raster gebracht. Das Fenster gibt ihn höchstens dem Suchfeld. Getippter Text kommt trotzdem an, entweder über Tippen-sucht-sofort oder direkt im Suchfeld. ↓ landete aber im Leeren bzw. im Suchfeld. Nach einem Klick ins Raster blieb der Fokus dort, deshalb ging es „danach immer“. Der bestehende UI-Test klickte vorher ins Raster und deckte den Fall deshalb nicht ab.
- **Regel (Entscheidung des Koordinators):**
  - ↑/↓ ohne Zusatztaste wirken aus dem Suchfeld oder ohne fokussierten Bereich immer im Raster (`KeyDecision.navigate`): Das Raster bekommt den Fokus. Ist noch nichts gewählt, wird die erste Trefferseite gewählt (`FocusNavigator.next(from: nil, …)`).
  - ←/→ verhalten sich genauso, außer wenn das Suchfeld ausdrücklich fokussiert ist (Klick, ⌘F, Tab; `SearchFieldHandle.focusIsExplicit`). Dann bewegen sie den Cursor im Text.
  - Mit ⇧, ⌘ oder ⌥ behalten Pfeiltasten im Suchfeld ihre Textbedeutung, zum Beispiel ⇧← zum Markieren. Im Raster und in der Vorschau ändert sich nichts.
  - Die Regel gilt in beiden Tastaturmodi (Tippen-sucht-sofort an und aus).
- **Woran „ausdrücklich“ erkannt wird:** `Field.becomeFirstResponder` prüft, ob das aktuelle Ereignis ein Mausklick in diesem Fenster ist. Ein Klick zählt dort, weil das Fenster das Feld schon vor `mouseDown` zum First Responder macht. Außerdem zählt `explicitFocusPending` (gesetzt von ⌘F und Tab). Der Start-Fokus des Fensters gilt als nicht ausdrücklich.

## 2026-11-13 — 1.2.1: Nachfrage beim Hinzufügen, Fenster und Ansicht merken

- **Titel des Sheets:** Ein neues Objekt erscheint als „„Name“ hinzufügen?“, der Name also in deutschen Anführungszeichen. Gezählt werden nur Objekte, die wirklich neu hinzukämen. „Nicht mehr fragen“ wird bei Abbrechen nicht gemerkt.
- **Zweiter Drop bei offenem Sheet:** Die neuen Objekte kommen zu den wartenden dazu, das Sheet bleibt dasselbe (Review I1).
- **Ersetzen schlägt fehl:** Kann keines der neuen Objekte geladen werden, etwa weil ein Index sich nicht öffnen lässt, kommen die alten Quellen zurück, auch die gemerkten, ebenso die Häkchen. Die Fehlermeldung erscheint trotzdem. Das entspricht ⌘O in 1.0 (Review I2).
- **Pfeiltasten:**
  - Ein Klick ins Suchfeld zählt immer als ausdrücklich, auch wenn das Feld schon den Start-Fokus hatte. Dafür beobachtet ein Monitor das Mausklick-Ereignis (Review I3).
  - Ist kein SwiftUI-Bereich fokussiert und hat ein AppKit-Steuerelement oder die PDF-Ansicht die Tastatur, behalten sie ihre Pfeiltasten. Beispiele sind Tastaturnavigation in der Werkzeugleiste und ein Klick in die Vorschau (Review I4).
- **Trenner:** Ein eigener Trenner ersetzt VSplitView/HSplitView, weil diese ihre Lage nicht hergeben. Der Anteil der Vorschau wird je Lage gespeichert und liegt zwischen 0,1 und 0,9. Beide Bereiche behalten ihre Mindestgröße: Vorschau 160/240 pt, Raster 160/320 pt.
- **Fenster:**
  - Das Hauptfenster wird nach dem Aufbau mit dem gespeicherten Rahmen versehen. Der Rahmen wird auf die Mindestgröße des Fensters gebracht und, falls nötig, auf den Hauptbildschirm geholt.
  - Gespeichert wird beim Bewegen, am Ende einer Größenänderung und beim Schließen, nicht im Vollbild.
  - Vom Einstellungsfenster wird nur die obere linke Ecke gespeichert, die Größe ergibt sich aus dem Reiter.
- **Zurückgestellt (Review-Minors):**
  - Während des Ziehens am Trenner wird bei jedem Schritt gespeichert.
  - Beim Start kann das Fenster kurz springen, weil SwiftUI zuerst den eigenen Rahmen setzt.
  - Mit Tastaturnavigation zählt Tab ins Suchfeld nicht als ausdrücklich.

## 2026-11-13 — 1.2.2: Suchverlauf und Schriftgröße der Werkzeugleiste

- **Auslöser ohne die Kachel-Dateien:** Ein anderer Thread (tile-cache) ändert gerade ThumbnailTile, ResultGridView, DocumentRow und ThumbnailCache. „Klick auf eine Kachel“ und „Häkchen“ hängen deshalb an `AppModel.focusedPage` und `AppModel.selection`, nicht an den Kacheln. Die Pfeiltasten setzen `focusedPage` ebenfalls, der Auslöser „Pfeil ins Raster“ ist damit abgedeckt. Setzt die App `focusedPage` selbst auf eine andere Seite, etwa nach einer Umsortierung, speichert sie den Begriff ebenfalls. Das schadet nicht: Die Suche war da schon angekommen.
- **Pause mit Treffern:** Gemessen wird ab dem angezeigten Ergebnis. Jeder Tastendruck bricht die Wartezeit ab.
- **Präfixe:** Nur der neueste Eintrag kann als Tipp-Präfix ersetzt werden, und nur innerhalb von 10 s.
- **Schreibweise:** Der Vergleich ignoriert Groß- und Kleinschreibung. Die neueste Schreibweise bleibt.
- **„Suchverlauf speichern“ aus:** Der vorhandene Verlauf wird gelöscht. Wer ihn aus Datenschutzgründen ausschaltet, erwartet keine alten Einträge mehr.
- **⌥↓:** Öffnet den Verlauf nur, wenn das Suchfeld den Fokus hat. Der Test aus 1.2.1, nach dem ⌥↓ im Feld unverändert durchging, ist angepasst.
- **Schrift:**
  - Schrift und Steuerelementgröße gelten für die drei Zeilen der Werkzeugleiste: klein unter 12 pt, normal bis 15 pt, groß darüber. Das Suchfeld bekommt eine `NSFont` in dieser Größe. A−/A+ und die Statuszeile wachsen anteilig mit.
  - Gemessen braucht die Leiste bei 20 pt mindestens 892 pt, die Mindestbreite des Fensters (960 pt) bleibt also.
  - Zeile 2 ist ein `ToolbarFlow` und bricht bei Bedarf um. Dort kommt auch ein späterer Dateityp-Filter hinein.
  - Die Statuszeile bricht auf bis zu 3 Zeilen um.
  - Menütexte von Pickern folgen der Steuerelementgröße, nicht jeder Zwischengröße. Grund: Ein AppKit-Popup übernimmt die SwiftUI-Schrift nicht.
- **Review 1.2.2 (behoben):**
  - Als Tipp-Präfix wird nur ein Eintrag ersetzt, den die Pause neu gespeichert hat. Ein Begriff, der mit Return, Klick, Häkchen oder aus der Liste kam, bleibt (I1).
  - Nur eine getippte Eingabe startet die Wartezeit. Eine erneute Anzeige durch Indexieren, Texterkennung oder Sortieren speichert nichts (I2).
  - Ist der neueste Eintrag schon derselbe Begriff, wird nichts geschrieben und das Präfix-Fenster nicht verlängert (M2).
  - Der Platz für ⌄ und ? im Suchfeld wächst mit der Schrift (I3).
  - Nur einzelne Häkchen speichern. „Auswahl leeren“ und das Aufräumen mehrerer Häkchen speichern nichts (M1).
  - Text, der keine Suche ergibt, etwa „-“, wird nicht gespeichert (M3).
  - Die Verlaufsliste nutzt normale Schrift (M5).
  - Ein eigenes Tastenkürzel auf ⌥↓ geht vor (M7).
- **Zurückgestellt:**
  - Die Höhe der Statuszeile kann beim Indexieren zwischen 1 und 2 Zeilen wechseln (M6).
  - `ToolbarFlow` hat keinen Layout-Cache (M10).
  - Der Mindestbreiten-Test prüft nicht, ob Zeile 2 bei 13 pt und 960 pt einzeilig bleibt (M8).
  - Ob ⌥↓ den Popover wirklich zum Tastaturziel macht, zeigt erst der UI-Lauf mit der Hand. Der UI-Test deckt nur die Maus ab.
- **Plan:** `ViewThatFits` für Zeile 1 war nicht nötig, siehe die Messung oben (M9).

## 2026-11-13 — 1.2.3: Kachel-Cache und paralleles Rendern

- **Eigene Threads statt Actor:** Seiten zeichnen blockiert bis zu 0,25 s. Auf dem kooperativen Pool würde das Indexierung und OCR ausbremsen und umgekehrt. Zahl der Threads: halbe Kernzahl, 2 bis 6, geteilt von allen Caches.
- **Reihenfolge:** sichtbar vor vorausgeladen, dann die neueste Anfrage zuerst (LIFO). Nach schnellem Scrollen kommen die Kacheln, die jetzt im Bild sind, zuerst dran. Ein schon laufender Job wird beim Wegscrollen nicht abgebrochen, sondern füllt den Cache.
- **Speicher-Schlüssel mit Dateistand:** Der Schlüssel enthält Änderungsdatum und Größe der Datei. Eine geänderte Datei zeigt nie ein altes Bild; alte Einträge altern einfach heraus.
- **Platten-Cache:** HEIC (Transparenz der Ränder bleibt, etwa ein Zehntel von PNG), PNG als Rückfall. 512 MB Obergrenze. Tests benutzen ihn nur mit eigenem Ordner; `ThumbnailCache()` ohne `disk:` schreibt nichts auf die Platte. Ein Knopf „Kachel-Cache leeren“ fehlt noch (Einstellungen ändert gerade 1.2.2).
- **Scans:** Der schnelle Weg gilt nur für Seiten, deren Inhalt genau ein JPEG/JPEG-2000-Bild ist (RGB/Grau, 8 Bit, ohne Maske/Decode), plus unsichtbarer Text (Tr 3). Jeder andere zeichnende, beschneidende oder mischende Operator (auch `gs`, Pfade mit `W`) und jede Annotation führen zu PDFKit. Abweichung zu PDFKit an echten Scans: im Mittel 3–5 von 255 Helligkeitsstufen (Glättung).
- **Flate-Scans** (verlustfrei gepackte Seitenbilder, z. B. 125 ms/Seite) lassen sich nicht verkleinert dekodieren; sie profitieren nur von Parallelität, Vorausladen und Platten-Cache.

## 2026-11-13 — 1.2.3 (Merge tile-cache): Review-Befunde, offen für 1.2.4

Die Review des Kachel-Diffs (df2d340..54853c0) hat keine kritischen Befunde. Keine Kachel zeigt falschen Inhalt. Getaggt wurde 1.2.3 auf 20b617a, nach einem grünen UI-Lauf. Offen sind:

- **Wichtig: Warteschlange der Plattenschreibvorgänge ohne Grenze** (`TileDiskCache.store`). Jeder Eintrag hält ein dekodiertes Bild. Beim schnellen Scrollen wächst der Speicher außerhalb der 256-MB-Grenze, und „leeren“ wartet hinter der ganzen Warteschlange. Vorschlag: höchstens etwa 32 offene Schreibvorgänge.
- **Wichtig: Prefetch-Sturm** (`onAppear` pro Kachel und pro Zeile). Es entstehen viele nicht abbrechbare Tasks mit Indexabfragen. Vorschlag: einmal pro Zeile vorladen und einen abbrechbaren Prefetch-Task verwenden.
- **Wichtig: Seitenbilder bleiben auf der Platte.** Sie liegen in `~/Library/Caches/local.pdfsucher/Tiles` und werden erst ab 512 MB ausgedünnt. Kacheln gelöschter PDFs bleiben, ebenso nach „Index löschen“. Vorschlag:
  - beim Start nach Alter ausdünnen, etwa 30 Tage;
  - je Format-Version ein eigener Ordner;
  - „Index löschen“ leert auch die Kacheln.
- **Wichtig: bis zu 6 offene `PDFDocument`s pro Datei** (`DocumentPool`). Vorschlag: insgesamt begrenzen.
- **Kleinere Punkte:**
  - Der Speicher-Schlüssel enthält keine OCR-Revision.
  - Die OCR-Version auf der Platte besteht nur aus Textlänge und Wortanzahl.
  - Ändert sich der Highlighter, werden alte Kacheln nicht ungültig.
  - Fast-Scan: `q`/`Q` sichert `Tr` nicht, und `BDC /OC` wird nicht beachtet.
  - Vektorseiten werden zusätzlich ganz geparst.
  - Lesevorgänge von der Platte sind unbegrenzt und nicht abbrechbar.
  - „Leeren“ kann parallel zum Rendern laufen.
  - Prefetch läuft mit `.userInitiated`.
  - Testhygiene: Datenrennen bei `startedCount`, Temp-Ordner im Benchmark werden nicht aufgeräumt.

## 2026-11-13 — 1.2.4: Kacheln (Review-Befunde aus 1.2.3) und Einstellungsfenster

- **Plattenschreibvorgänge:**
  - Höchstens 32 Kacheln warten aufs Schreiben, bei mehr fallen die ältesten weg. Die neueren sind beim Scrollen eher sichtbar, und eine weggefallene Kachel wird bei Bedarf neu gerendert.
  - „Leeren“ verwirft zuerst die wartenden Schreibvorgänge.
- **Vorausladen:**
  - Der `TilePrefetcher` sammelt sichtbare Zeilen und Kacheln. Nach 80 ms Ruhe schickt er einen Auftrag für den Bereich: rechts der letzten sichtbaren Kachel jeder Zeile und die ersten Kacheln der zwei Zeilen darunter.
  - `ThumbnailCache.prefetch` ersetzt den vorigen Auftrag. Sein Task wird abgebrochen, seine wartenden Jobs verlassen die Render-Warteschlange.
- **Platten-Cache:**
  - Struktur: `Tiles/v2/<Hash des PDF-Pfads>/`, darin eine Datei `source` mit Pfad, Datum und Größe. Grenze 1 GB, LRU.
  - Aufräumen gelöschter oder geänderter PDFs: beim Start, nach dem Indexieren eines Ordners und bei „Index löschen“.
  - Die 1.2.3-Ablage ohne Unterordner und andere Formatversionen werden beim Start gelöscht.
  - Die `source`-Datei enthält den PDF-Pfad im Klartext, wie der Index selbst.
- **PDF-Dokumente:**
  - Pro Datei bleiben bis zu „Render-Threads“ offen, über alle Dateien höchstens so viele zusätzliche wie Render-Threads, also 20 + 6 statt bis zu 120.
  - Gegen „genau 1 pro Datei“ spricht: Für jede parallel gerenderte Seite würde die Datei neu geöffnet, siehe `manyPagesOfOneFileRenderCorrectlyAtOnce`.
- **Kleinere Punkte:**
  - OCR-Version (Hash aus Text und Kästen) im Speicher- und Plattenschlüssel.
  - Lesen von der Platte mit höchstens 4 gleichzeitig, abbrechbar.
  - `startedCount` wird unter der Sperre gelesen.
  - Die Temp-Ordner im Benchmark werden aufgeräumt.
- **Einstellungsfenster (Chris):**
  - Gemeinsame Inhaltsgröße 680 × 920 pt, höchstens 85 % der sichtbaren Bildschirmhöhe. Gemessen braucht „Allgemein“ 848 pt.
  - Frei vergrößerbar ab 640 × 420. Größe und Position werden gemerkt (`window.settings.frame` ersetzt `window.settings.origin` aus 1.2.1).
- **Knöpfe im Suchfeld (Chris):**
  - ⌄ und ? haben volle Textfarbe, eine leichte Hervorhebung beim Überfahren und eine Reaktion beim Drücken.
  - Grau nur, wenn deaktiviert: Der Verlaufsknopf ist bei leerem Verlauf deaktiviert. ⌥↓ öffnet die Liste trotzdem, mit „Noch keine Suchbegriffe“.
- **Release-Testläufe:** `ToolbarFontTests` und `SettingsWindowTests` laufen nur in Debug, weil `SampleViewerModel` nur dort existiert.
- **Ruling (TDD):** Die Umbauten von `TileDiskCache` und `ThumbnailCache` habe ich vor ihren Tests geschrieben. Die Tests (`TileCache124Tests`) kamen danach und sahen ihr Rot nur als Compile-Fehler. Kosten, falls das falsch war: ein Verhalten, das kein Test tatsächlich hat scheitern sehen. Die Messung vorher/nachher stützt die Wirkung.
- **Review 1.2.4:**
  - Kacheln eines PDFs, dessen Ordner gerade fehlt (Volume nicht angeschlossen), bleiben erhalten. Gelöscht wird nur, wenn der Ordner da ist und das PDF nicht (I2).
  - Das Einstellungsfenster hat für alle Reiter dieselbe ideale Größe, ist über `.windowResizability(.contentMinSize)` vergrößerbar und speichert nur die Größe, die der Nutzer einstellt. Ein Reiterwechsel ändert nichts (I3).
  - Ein gemerkter Rahmen, der größer als der aktuelle Bildschirm ist, wird darauf verkleinert. Auf Bildschirmen unter etwa 1 083 pt sichtbarer Höhe scrollt „Allgemein“; das Formular scrollt von selbst (I4).
  - Der Befund „Leeren friert den Hauptthread ein“ traf nicht zu: Der Aufruf lief schon im Hintergrund (I1). `removeAll()` ist trotzdem jetzt `async` und blockiert keinen Thread mehr.
  - Bei langem Scrollen geht spätestens alle 250 ms ein Vorausladeauftrag hinaus (M2).
  - Eine schon dekodierte Kachel landet im Speicher, auch wenn sie inzwischen weggescrollt wurde (M5).
  - `source` speichert den Pfad als letzte Zeile, damit Pfade mit Zeilenumbruch funktionieren (M6).
  - Kacheln einer älteren Dateiversion ersetzen keine neueren (M7).
- **Zurückgestellt:**
  - Wartende Vorausladeaufträge eines alten Batches können in einem knappen Zeitfenster noch einreihen (M1, harmlos).
  - `lastTile` und `visibleRows` werden bei einer neuen Trefferliste nicht abgeglichen (M3).
  - Beim Weglassen von Schreibvorgängen könnten zuerst die aus dem Vorausladen dran sein (M10).
  - `ocrVersion` wird bei jedem Request neu gehasht (M10).

## 1.3 Office (Teil A, Branch `office`)

- **Basis (Task 0):** Branch `office` von `ocr-index`, `ocr-output` mit `--no-ff` hineingeführt. Konflikte nur
  wie erwartet: `Models.swift` (ocr-index-Seite genommen, `OCRWord` nur einmal deklariert) und
  `decisions.md` (beide Abschnitte behalten). Ausgangsstand: 516 Tests grün (1 bekanntes Issue), App-Build ok.
- **Datenmodell gesetzte Seiten (Task 2, R1):** Office-Dokumente, die noch auf ihr Layout warten, liegen mit
  `page_count 0`, Status `noText` und `needs_layout = 1` im Index (wie Bilder vor der OCR in 1.2); die Suche
  ignoriert sie, bis `storeLayout` sie setzt. Der Indexer schreibt sie mit `IndexStore.upsertAwaitingLayout`;
  `pendingLayoutJobs()` liefert sie nach Pfad sortiert. Jedes Upsert setzt `renderer`/`layout_version` zurück.
- **Quelle und „vereinfacht“ (Task 2, R2):** Alle Seiten eines Layout-Renderers haben `page_text.source = 'layout'`;
  welcher Renderer sie erzeugt hat, steht in `documents.renderer` (`quicklook`/`textkit`, später `wordkit`/`slidekit`).
  Keine Spalte `simplified` in Teil A: „vereinfacht“ (Spec §7, `.doc`) ergibt sich aus `renderer == "textkit"`.
  Schema-Version 3 (Neuaufbau älterer Indizes wie 1.2). `storeLayout` ersetzt Seiten und Wortrahmen in einer
  Transaktion und verwirft das Ergebnis, wenn Dokument, Größe oder Datum nicht mehr zum Job passen. Die Seitengröße
  (`LaidOutPage.size`) wird nicht gespeichert (Boxen sind normalisiert).
- **Fehlgeschlagenes Layout (Task 2, Nachbesserung):** `markLayoutFailed` löscht alte Seiten/Wortrahmen und setzt
  `renderer`/`layout_version` zurück (Status `error` = nicht lesbar, kein veralteter Text, keine Neuvormerkung durch
  `requestLayout`). Ändert sich die Datei später, greift der normale Geändert-Pfad. Wortrahmen außerhalb des
  Seitentexts werden in allen Builds verworfen (privat geloggt); `pendingLayoutJobs` überspringt unbekannte Arten.
- **Indexer-Phase „layout“ (Task 3):** Läuft nur mit `PageLayoutSource`, nach Phase 1 und vor der OCR; ohne Quelle
  listet der Scanner keine Office-Dateien (Verhalten wie bisher). Phase 1 schreibt neue/geänderte Office-Dateien
  im selben Batch wie PDFs als „wartet auf Layout“ (internes `upsertBatch` mit `needsLayout`), nie über die
  `TextSource`; sie erscheinen nicht in `IndexReport.noText`. Unveränderte Office-Dateien werden nicht angefasst
  (sonst ginge das gespeicherte Layout bei jedem Lauf verloren).
- **Renderer-Upgrade je Art:** `requestLayout` hat einen optionalen Parameter `kind`; der Indexer fragt
  `renderer(for:)` für Word und PowerPoint getrennt ab. Sonst würden bei gleichem Renderer-Namen und
  unterschiedlicher Version die Dokumente der anderen Art bei jedem Lauf neu gesetzt.
- **Renderer-Wechsel (Final-Review I2, ohne Schema-Wechsel):** Der erwartete Renderer je Art steht in `meta`
  (`layout.expected.word`/`layout.expected.powerpoint` = `name:version`, z. B. `textkit:1`). Die Phase „layout“
  vergleicht ihn mit `renderer(for:)` (`IndexStore.adoptLayoutRenderer`); weicht Name oder Version ab oder fehlt der
  Wert, werden in derselben Transaktion **alle** Dokumente der Art neu vorgemerkt — auch `error` und solche ohne
  Renderer — und der neue Wert gespeichert. Auf einem frischen Index entsteht dadurch keine Zusatzarbeit (alles
  wartet ohnehin). Bisherige Seiten bleiben bis zum neuen Ergebnis suchbar. Kein Schema-Wechsel, weil der den Index
  neu aufbaut und die OCR-Arbeit verwirft. Neue API `requestLayout(kind:)` (alle Dokumente einer Art) für Teil B.
- **Zeitlimit (120 s, Spec §11):** Das Layout läuft in einem eigenen `Task.detached(.utility)` und wird gegen einen
  Timer-Task „gerannt“; das erste Ergebnis gewinnt. Bei Zeitüberschreitung wird der Layout-Task abgebrochen und die
  Datei sofort mit „Zeitlimit“ als Fehler markiert, ohne auf eine Quelle zu warten, die den Abbruch ignoriert. Deren
  spätes Ergebnis wird verworfen und nie gespeichert; ihre Arbeit läuft bis zum Ende weiter, dann außerhalb der
  Grenze `layoutConcurrency` (Preis dafür, dass der Indexer nicht hängen kann).
- **Abbruch (Final-Review I3, ersetzt „laufende Ergebnisse werden noch gespeichert“):** Vor jeder Datei geprüft;
  ein laufendes Layout wird mit abgebrochen (`withTaskCancellationHandler` → Layout-Task `cancel`, das Rennen endet
  sofort mit „abgebrochen“), nichts davon gespeichert, die Datei bleibt `needs_layout` für den nächsten Lauf;
  `update` wirft sofort `CancellationError`, auch bei einer Quelle, die den Abbruch ignoriert (deren spätes Ergebnis
  wird verworfen). Vor dem Abbruch fertige Ergebnisse werden gespeichert. Grund: Stoppen wartete sonst 3–13 s je
  Deck, schlimmstenfalls 120 s. Wirft die Quelle von sich aus `CancellationError`, endet der Lauf ebenso. Echter
  Pfad getestet: Abbruch während der WebView lädt (Bild als Named Pipe hält das Laden offen) → `CancellationError`
  in < 2 s, Ordner weg.
- **Fehlerklassen:** `LayoutSourceError.unreadable` → Status `error` (`LayoutReport.failed`, kein neuer Versuch bis
  zur Dateiänderung); Zeitlimit ebenso; jeder andere Fehler → Datei bleibt `needs_layout`, nächster Lauf
  (`LayoutReport.deferred`, wie `OCRReport.deferred`).
- **Datei während des Layouts geändert:** `storeLayout` vergleicht nur mit dem Index. Darum prüft der Indexer nach
  dem Layout Größe und Datum auf der Platte (Links aufgelöst); weicht etwas ab, wird das Ergebnis verworfen
  (`deferred`), und der nächste Lauf erkennt die Änderung in Phase 1 und setzt neu.
- **Nachbesserung Task 3:** `markLayoutFailed` liefert wie `storeLayout` ein `Bool`; der Indexer meldet eine Datei nur
  dann in `LayoutReport.failed`, wenn wirklich etwas geschrieben wurde (veralteter Job → nicht gemeldet). Eine während
  des Layouts gelöschte Datei zählt als `deferred` und wird im nächsten Lauf von Phase 1 entfernt.
- **Quick-Look-HTML ohne öffentliche API (Task 4):** Geprüft im macOS-26-SDK: `QuickLook.framework` hat nur
  (veraltete) Thumbnail-Funktionen und die Generator-Seite (`QLPreviewRequest…`, nur für Generatoren selbst);
  `QuickLookUI` (`QLPreviewView`, `QLPreviewPanel`, `QLPreviewingController`, `QLPreviewProvider`/`QLPreviewReply`)
  zeigt eine Vorschau an bzw. liefert sie als Erweiterung, gibt das erzeugte HTML aber nie heraus;
  `QuickLookThumbnailing` (`QLThumbnailGenerator`) liefert nur ein Bild der ersten Folie. Eine öffentliche Funktion,
  die die Vorschaudaten eines fremden Generators zurückgibt, gibt es nicht. Darum `OfficeKit.QuickLookHTML`:
  `/usr/bin/qlmanage -p -o <tmp> <datei>` als `Process` (Ausgaben verworfen), Ergebnis
  `<tmp>/<Name>.qlpreview/Preview.html`; der Ordner wird gesucht statt aus dem Namen gebaut (Unicode-Normalisierung
  bei Umlauten). Temp-Ordner `PDFSucher-QL/<UUID>`, gehört dem Aufrufer. Zeitlimit/Abbruch: SIGTERM, nach 2 s
  SIGKILL, erst nach dem Prozessende `timedOut` bzw. `CancellationError` (kein Kindprozess bleibt übrig, Ordner
  gelöscht). Fehlt `Office.qlgenerator` → `generatorMissing`. Risiko: `qlmanage` ist ein Debug-Werkzeug, der
  Generator ein Legacy-Plug-in; die App ist nicht sandboxed. Fixture-Deck (3 Folien): ~70–90 ms je Aufruf.
- **Folien-Cache: HEIC, Qualität 0,85, lange Seite ≤ 2.800 px** (`OfficeKit.SlideCache`; Task 8: von 2.400 px angehoben, siehe „Folien in der Ausgabe“). Scharf auch bei hohem Kachelzoom, HEIC ist bei gleicher Qualität deutlich kleiner als PNG/JPEG. Ein Ordner je Schlüssel (SHA-256 über Standardpfad|Größe|Änderungsdatum in ms), Dateien `0.heic…`; Schreiben atomar über `<key>.<UUID>.tmp` und Umbenennen, ein vorhandener Eintrag wird ersetzt; `prune` räumt verwaiste `.tmp`-Ordner ab. HEIC-Kodierung wird vorausgesetzt (Apple Silicon, macOS 26), bewusst kein Format-Fallback; scheitert sie, wirft `store` und hinterlässt keinen Teil-Eintrag. Der Schlüssel nutzt den standardisierten Pfad ohne Symlink-Auflösung und ohne Unicode-Normalisierung: dieselbe Datei über zwei Wege ergibt zwei Einträge (harmlose Doppelung). `prune` darf nicht parallel zu `store` laufen (nur beim Start / „Cache leeren“).
- **PowerPoint über Quick Look (Task 6, `QuickLookSlideSource`, Renderer `quicklook` v1):** `QuickLookHTML` →
  `PresentationSlides.visibleSlideNumbers` → `SlideSnapshotter` (lange Seite = `SlideCache.maxLongSide`, seit Task 8 2.800 px) → `SlideCache`. Folien-Selektor
  `div.slide` (aus dem Spike-HTML: ein Element je sichtbarer Folie, Größe in CSS-px = pt). Weicht die Zahl der
  `div.slide` von der Zahl sichtbarer Folien ab, oder wirft `QuickLookHTML` `noPreview`/`timedOut`, oder ist die
  Datei kein lesbares Paket → `unreadable(„Vorschau nicht möglich“)`. Fehlt der Generator → `unreadable` mit eigenem
  Grund „Office-Vorschau von macOS fehlt“. Ein Deck ohne sichtbare Folie gilt ebenfalls als nicht lesbar.
- **`PresentationSlides` statt OOXMLKit:** Branch `slidekit` wird nicht hineingeführt. Eigener Mini-Leser mit der
  Semantik von OOXMLKit `PresentationInfo` (`partPath`, `hidden` = `show="0"` auf `p:sld`, `powerPointNumber` =
  Position in `p:sldIdLst` + `firstSlideNum` − 1, über `ppt/_rels/presentation.xml.rels` aufgelöst). Entpacken mit
  eigenem kleinem ZIP-Leser (Zentralverzeichnis, stored + deflate über das Compression-Framework, kein ZIP64): kein
  Kindprozess, kein Blockieren auf `unzip`, liest nur die nötigen XML-Teile. **Später durch OOXMLKit
  `PresentationInfo` ersetzen, sobald slidekit gemergt ist** (eigener Commit). `p:sldSz` wird für das Layout nicht gelesen; die
  Foliengröße kommt aus dem `div.slide` (die Ausgabe liest `p:sldSz` seit Task 8).
- **SlideSnapshotter ohne Fenster:** Der `WKWebView` hängt in keinem Fenster (wie im Plan); Snapshots waren im
  Test-Prozess und mit echten Decks (EMF-Bilder als PDF, Deck B) vollständig, das Off-Screen-Fenster des Spikes ist
  nicht nötig. Inhalts-JavaScript aus, eigene Aufrufe in `.defaultClient`, nicht persistenter Datenspeicher. Ablauf:
  `didFinish` → Bilder `complete` (≤ 5 s) → jede Folie einmal in den Viewport scrollen (je 50 ms, wie im Spike; auch
  Nicht-PDF-Bilder können verzögert dekodiert werden) → 1 s warten → je Folie Text, Wortrahmen, Snapshot. Jeder Schritt ist ein kurzer Main-Actor-Schritt mit `await`
  dazwischen; Abbruch wird dazwischen geprüft, der WebView wird bei jedem Ausgang abgebaut, der Temp-Ordner per `defer`.
- **Folientext und Wortrahmen:** Ein Textknoten-Durchlauf je Folie baut den Rohtext (`\n` zwischen Blöcken =
  nicht-inline oder absolut positioniert; ein Leerzeichen, wenn zwei Knoten im selben Block sichtbar auseinander
  stehen, z. B. Aufzählungszeichen mit Abstand). Die Wörter trennt Swift genau wie `OCRRecognizer` (Leerraum,
  Steuer- und Private-Use-Zeichen); JavaScript misst je Wort `Range.getClientRects()` (Vereinigung) relativ zur Folie.
  Foliennummern-Felder (`‹#›`, defensiv auch `<#>`) werden vor Snapshot und Text im DOM durch die PowerPoint-Nummer
  ersetzt (`slides(…, slideNumbers:)` — zusätzlicher Parameter gegenüber dem Plan, weil der Snapshotter die Nummern
  sonst nicht kennt).
- **Fehler im WebView (Review Task 6):** Jeder WebKit-Fehler (JS-Ausnahme, WebContent-Prozess weg, Snapshot ohne Bild)
  und jeder JSON-Dekodierfehler wird im `SnapshotWebView` zu `SlideSnapshotterError` → `unreadable`; nur Abbruch
  bleibt `CancellationError`. So wird ein Deck, das immer so scheitert, nicht bei jedem Lauf neu versucht. Fehler beim
  Schreiben des Caches (z. B. Platte voll) bleiben „später erneut“.
- **Kein eigenes Zeitlimit im Snapshotter:** Hänger decken das Zeitlimit je Datei im Indexer (120 s) und das 60-s-Limit
  von `QuickLookHTML` ab.
- **Cache-Schlüssel:** Pfad = die übergebene URL (standardisiert, wie der Index sie speichert), Größe und Datum aber
  vom aufgelösten Ziel (`resolvingSymlinksInPath` + `resourceValues`, wie `Indexer.isUnchanged`). Gelesen und an
  `qlmanage` übergeben wird das aufgelöste Ziel (für einen Symlink schreibt `qlmanage` keine Vorschau).
- **ZIP-Leser-Grenzen:** ZIP64-Markierungen (0xFFFFFFFF bei Größen/Offsets, 0xFFFF Einträge) → nicht lesbar; Einträge
  über 64 MB unkomprimiert werden nicht entpackt. Snapshots, die WebKit nicht in der verlangten Pixelgröße liefert,
  werden umgerechnet und geloggt (debug); ein Test prüft, dass das auf diesem Mac nicht nötig ist.
- **Word vorläufig über TextKit (Task 7, `TextKitWordSource`, Renderer `textkit` v1):** `NSAttributedString`
  (`.officeOpenXML` für docx/docm/dotx, `.docFormat` für doc) → TextKit 1, ein `NSTextContainer` je Seite (Seite minus
  Ränder, `lineFragmentPadding` 0). Harte Seitenumbrüche liefert der Import als U+000C (`"\n\u{0C}\n"` für
  `<w:br w:type="page"/>`); TextKit behandelt das selbst als Container-Umbruch. Eine letzte Seite nur aus Leerraum
  (Absatzmarke nach dem letzten Umbruch) entfällt, ein leeres Dokument hat 1 Seite; Obergrenze 10.000 Seiten, ein
  leerer Container vor dem Textende bricht ab (Text passt nicht), Abbruch des Tasks wird je Seite geprüft.
  Import-Fehler (Cocoa 259, auch verschlüsselte docx = OLE-Datei) → `unreadable(„Word-Dokument nicht lesbar“)`;
  fehlende Datei/fehlende Rechte behalten den Cocoa-Fehler (nächster Lauf). `.powerpoint` → `unreadable`
  („kein Word-Dokument“), das Verteilen nach Art macht `OfficeLayoutSource` (Task 8). Wortgrenzen wie
  `SlideSnapshotter.wordRanges` (dafür `nonisolated`), Rahmen über `boundingRect(forGlyphRange:in:)`.
- **Import abseits des Hauptthreads stabil:** Geprüft mit 3.000 Importen (docx, doc, test.docx/test.doc) parallel auf
  globalen Queues inkl. TextKit-Umbruch, mit eingeschleustem Main Thread Checker (vorher mit `NSView()` im
  Hintergrund gegengeprüft, dass er meldet): keine Meldung, kein Absturz, identische Ergebnisse; dazu ein Test mit
  64 parallelen Tasks. Darum kein `MainActor.run`: Import und Umbruch laufen im Task des Indexers.
  `NSLayoutManager.backgroundLayoutEnabled = false` (kein Run-Loop-Bezug). Zeichnen setzt
  `NSGraphicsContext` threadlokal und löst dynamische Farben in `.aqua` auf.
- **Seitengröße:** Für docx/docm/dotx aus dem Paket (`_rels/.rels` → Hauptteil, letzter `w:sectPr` → `w:pgSz`,
  `w:pgMar` in Twips, Bundsteg zum linken Rand, ohne `w:pgMar` 2,5 cm), sonst A4 mit 2,5 cm — `documentAttributes`
  werden für docx nicht genutzt. Für doc: `documentAttributes` (`.paperSize`, Ränder), sonst A4. Unbrauchbare Werte
  (< 1 Zoll Inhalt, > 200 Zoll) fallen eine Stufe weiter. Befund: Der Importer liest `w:pgSz` korrekt (Fixture A4 →
  595,3 × 841,9; test.docx ist wirklich Letter, `w:pgSz 12240×15840`, Referenz-PDF 612×792 — der Spike-Hinweis
  „Letter trotz A4“ war ein Irrtum). Fehlt `w:sectPr`, meldet er aber seine eigene Vorgabe Letter; das Lesen aus dem
  Paket macht den Rückfall auf A4 ausdrücklich und spec-konform. ZIP-/XML-Leser dafür aus `PresentationSlides.swift`
  unverändert nach `OOXMLPackage.swift` verschoben. Nur eine Seitengröße je Dokument (mehrere Abschnitte: die letzte).
- **Abgebrochener Umbruch:** Endet der Umbruch vorzeitig (leerer Container oder 10.000 Seiten), wird der nicht
  gesetzte Rest an den Text der letzten Seite angehängt (ohne Wortrahmen), damit er suchbar bleibt (Spec §11).
- **Bekannte Grenze des Importers (geprüft mit eigenem docx):** Kopf- und Fußzeilen sowie Fußnoten fehlen ganz (weder
  Text noch Darstellung); Textfelder (VML `v:textbox` und DrawingML `wps:txbx`) kommen als normale Absätze an der
  Ankerstelle an. test.docx hat keine Kopf-/Fußzeilen („Seite 2/3“ ist Fließtext). Dazu fehlen Bilder und
  Formatvorlagen (Spike C). Abhilfe erst mit dem späteren Renderer `wordkit`.
- **`TextKitWordDocument.cached`:** LRU mit höchstens 4 Dokumenten und (Final-Review M4, Spec §8 „Obergrenze nach
  Speicher“) höchstens 2.000 Seiten zusammen (≈ 0,3 MB je Seite → ≈ 600 MB); das zuletzt benutzte Dokument bleibt
  immer, auch wenn es allein schwerer ist (eigener Typ `DocumentLRU` mit `Mutex`, `maxWeight` und Gewichtsfunktion, in Tests
  als eigene Instanz geprüft, weil der gemeinsame statische Cache von parallelen Tests mitbenutzt wird), Schlüssel standardisierter Pfad + Größe
  + Änderungsdatum des aufgelösten Ziels; ein neuer Stand ersetzt den Eintrag desselben Pfads; Import außerhalb der Sperre (zwei gleichzeitige Fehltreffer importieren
  doppelt, harmlos). `TextKitWordSource.layout` nutzt den Cache, damit die Anzeige danach nicht neu importiert.
  test.docx/test.doc: 3 Seiten Letter wie das Referenz-PDF; Import + Umbruch + Seiten ~2 ms (erster Aufruf ~40 ms).
- **Folien in der Ausgabe (Task 8, `OfficePages`):** Seitengröße = Foliengröße ohne Rand (Spec §5a), aus
  `ppt/presentation.xml` `p:sldSz` (EMU / 12.700 → pt; fehlt `p:sldSz`: 720 × 540). Nur wenn das Paket nicht lesbar
  ist, 960 pt breit im Seitenverhältnis des Cache-Bilds (Rückfall des Plans). Das Bild wird eingepasst (bei gleichem
  Seitenverhältnis = randlos) und als JPEG (Qualität 0,9, `/DCTDecode`) eingebettet, nicht als Rohpixel.
- **Auflösung:** 2.400 px auf 960 pt wären nur 180 dpi (< 200 dpi, Spec §5a). Darum lange Seite im `SlideCache` und
  im `SlideSnapshotter` 2.800 px (≈ 210 dpi bei 960 pt, 280 dpi bei 720 pt). Schlüssel und Format bleiben; ältere
  Einträge mit 2.400 px bleiben gültig (nur kleiner). test.pptx: 2.800 × 2.100 px, kein Umrechnen im Snapshotter.
  Grenze: 2.800 px reichen für ≥ 200 dpi nur bis etwa 1.008 pt lange Folienseite (2.800 / 200 × 72); größere
  benutzerdefinierte Foliengrößen bekommen entsprechend weniger (z. B. 1.440 pt → 140 dpi). Bewusst hingenommen.
- **Review Task 8:** Foliengröße je Cache-Schlüssel gemerkt (`SlideSizeMemo`, `Mutex`, höchstens 64 Einträge, voll →
  neu anfangen), damit ein Merge vieler Folien das Paket nur einmal öffnet. Die PowerPoint-Kachel verlangt wie
  `pageCount`/`makePage` einen vollständigen Cache-Eintrag (unvollständig → nil).
- **Nicht gesetzte Decks:** PowerPoint-Seiten gibt es nur aus dem Cache (gleicher Schlüssel wie beim Layout,
  `QuickLookSlideSource.cacheKey`). Fehlt der Eintrag (noch nicht gesetzt oder Datei seither geändert):
  `pageCount` nil → `Merger.unavailable` listet die Seiten als nicht verfügbar, `makeDocument` wirft `cannotOpen`;
  Kachel nil (Aufrufer zeigt Platzhalter), keine große Vorschau. Kein Quick Look zur Ausgabezeit.
- **Word in der Ausgabe:** Vektorseite — `TextKitWordDocument.draw` in einen PDF-`CGContext`, daraus
  `PDFDocument(data:)?.page(at: 0)` (wie `ImagePages`); der Text bleibt Text (`page.string`), die Seite bleibt nach
  Freigabe ihres Einseiten-Dokuments nutzbar (getestet: Rendern und Schreiben danach). Vorschau = dieselbe Seite.
- **OutputKit bleibt Office-frei:** `ForeignPageProvider` (`handles`, `pageCount`, `makePage`) in OutputKit;
  `Merger(foreign:)`, `Merger.unavailable(_:foreign:)`, `Printer.printOperation(for:foreign:)`,
  `PrintDocument.build(_:foreign:)`, jeweils Vorgabe `nil` = Verhalten wie bisher (Aufrufer in AppCore unverändert,
  Verdrahtung folgt). Der Anbieter wird vor der Bildprüfung gefragt; andere Fehler als `OutputError` aus `makePage`
  werden zu `cannotOpen`. Fremde Seiten tragen keine internen Links.
- **`OfficeLayoutSource`:** verteilt nach Art (`.powerpoint` → Quick Look, `.word` → TextKit), `renderer(for:)` fragt
  dieselbe Quelle. `.pdf`/`.image` (vom Indexer nie angefragt): `layout` wirft `unreadable(„kein Office-Dokument“)`,
  `renderer` liefert `("none", 0)` statt einer Precondition.
- **Messung mit echten Dateien (Task 10, Zahlen in performance.md):** Gated Test
  `OfficeRealFilesMeasurement` (`PDFSUCHER_OFFICE_PERF=1`). Die Originale werden nicht kopiert: Einzelmessung direkt
  auf den Pfaden, der Indexer-Lauf über einen temporären Ordner mit symbolischen Links (Quick Look bekommt das
  aufgelöste Ziel, Task 6). Stufenzeiten über den vorhandenen internen Snapshot-Hook und einen umhüllten
  HTML-Generator — keine Zeitmessung im Produktionscode. Kontaktbögen zeigen Kundeninhalte und liegen darum nur
  außerhalb des Repos (`~/Developer/PDFSucher-spikes/office-a-measure/`), nicht in `docs/screenshots/office/`.
  Alle 11 Dateien ohne Fehler, Seiten = sichtbare Folien, alle Zeitlimits weit unterschritten (≤ 13,4 s je Deck).
  Keine Konstante geändert: Den größten festen Anteil hat das Aufwärmen (50 ms je Folie + 1 s), es ist aber das,
  was die verzögert dekodierten EMF/PDF-Bilder braucht; ohne Gegenmessung bleibt es.
- **Speicher beim Setzen eines Decks: Folienbilder werden gestreamt (Task 10b, behebt den Befund aus Task 10):**
  Vorher hielt `SlideSnapshotter` alle Folienbilder (2.800 px) bis `SlideCache.store` am Ende; der Höchststand
  wuchs um ≈ 28 MB je Folie (gemessen 57 Folien → 1,6 GB, 65 → 1,8 GB, davon ≈ 10 MB je gehaltenem Bild bis zur
  letzten Folie und der Rest beim Kodieren am Stück). Jetzt: `SlideCache.beginEntry(for:)` liefert einen
  `SlideCacheWriter`; `append` verkleinert, kodiert (HEIC 0,85) und schreibt `<n>.heic` sofort in den eigenen
  `<key>.<UUID>.tmp`-Ordner, `commit` veröffentlicht wie bisher (Verschieben bzw. `replaceItemAt`, ersetzt einen
  vorhandenen Eintrag), `discard` und `deinit` ohne `commit` löschen den `.tmp`-Ordner. Ein fehlgeschlagenes
  `append`/`commit` verwirft den Writer selbst; nach `commit`/`discard` werfen `append`/`commit` `writerClosed`.
  `store` ist nur noch eine Hülle darum (Vertrag und Tests unverändert). `SlideSnapshotter.slides` gibt die Bilder
  nicht mehr zurück, sondern reicht jedes direkt nach dem Snapshot an eine nicht main-actor-gebundene Senke (das
  Kodieren blockiert den Hauptthread also nicht); `QuickLookSlideSource` hängt dort an den Writer an und ruft
  `commit` erst nach der Prüfung „Seiten = sichtbare Folien“, sonst (Fehler, Abbruch, Anzahl falsch) `discard`
  per `defer` — kein halber und kein veralteter Eintrag, ein älterer vollständiger Eintrag bleibt. Autoreleasepool
  um das Kodieren und um die `NSImage`→`CGImage`-Umwandlung je Folie. Ergebnis: Höchststand je Deck ≈ 0,7 GB
  unabhängig von der Folienzahl (ab ≈ 40 Folien flach), Fußabdruck ≈ 50 MB, Gesamtzeit gleich (das Kodieren ist
  nur vom Ende in jede Folie gewandert). Bewusst nicht parallelisiert (Kodieren von Folie n neben Snapshot n+1):
  brächte höchstens ≈ 50 ms je Folie und hielte zwei Bilder; ohne Bedarf einfach gelassen.
- **Befund Quick Look nicht deterministisch (offen):** `Office.qlgenerator` schreibt für dieselbe Datei bei jedem
  Aufruf etwas anderes HTML (andere Zahl von `<img>`/Anhängen; Deck A 503–539 Bilder). Bei 4 von 7 Decks waren
  zwischen zwei Läufen 12–33 Folienbilder sichtbar verschieden (z. B. fehlt oder erscheint ein Textkasten je nach
  Lauf, oder es erscheinen kleine Bilder, die laut Folien-XML nicht auf der Folie stehen). Ursache liegt im Generator, nicht im
  WebView (Warten, `img.decode()`, `decoding='sync'` geprüft, ohne Wirkung). Folge: Bild, Text und Wortrahmen
  einer Folie können je Layout-Lauf leicht anders sein; da unveränderte Dateien nicht neu gesetzt werden, bleibt
  der einmal gespeicherte Stand. Kein Workaround in Teil A (z. B. „zweimal erzeugen, mehr Bilder gewinnt“ wäre
  geraten und kostet Zeit); Rückfall/Vergleich mit SlideKit, sobald vorhanden. Deck G pixel- und HTML-stabil;
  Deck D und Deck F pixelstabil (gleiche Folienbilder), obwohl die `<img>`-Zahl im HTML je Lauf leicht schwankte.
  Bleibt als **bekanntes Risiko** von Teil A stehen (Task 10b): kein Fehler, aber Suchtreffer und Bilder einer
  Folie hängen davon ab, welchen Lauf der Index gespeichert hat.
- **Kontaktbögen (Task 10):** Deck B und Deck G sehen aus wie die Spike-Bögen (gleiche Titelbalken aus EMF,
  gleiche Schärfe); Foliennummern-Felder zeigen jetzt Zahlen statt `‹#›`, bei Deck G 2, 4, 5, 6, 7 (die
  ausgeblendete Folie 3 fehlt und zählt mit). Abweichungen nur in den Folien, die Quick Look je Lauf anders
  liefert (oben). test.docx entspricht dem Spike-Bild „C TextKit“ (bekannte Grenzen: kein Bild, keine
  Überschriftenfarben).
- **Befund Word-Kachel kalt bei großen Dokumenten (Task 10b, offen):** Mit erzeugten Word-Dateien (Spec §12)
  dauert die erste Kachel eines noch nicht geladenen Dokuments bei 99 Seiten 97 ms, bei 495 Seiten 868 ms
  (Debug-Build) und verfehlt damit die 300 ms aus §12, weil `TextKitWordDocument` beim Öffnen das ganze Dokument
  setzt. Layout selbst ≈ 8 ms je Seite (495 Seiten 4,2 s), Speicher ≈ 0,3 MB je Seite. Nicht in diesem Task
  geändert (wäre ein seitenweises/inkrementelles Setzen in TextKitWordDocument); Entscheidung beim Controller.
- **Messtest ohne Kundeninhalt (Task 10b, aus dem Review von Task 10):** Docs zitieren keinen Folientext mehr;
  Suchwörter im Messtest neutral (`und`, `Daten*`, `*ung`, `gibtsnicht`); Kontaktbögen werden nicht mehr über
  feste Dateinamen gewählt, sondern über `PDFSUCHER_OFFICE_SHEET_DECKS` oder die zwei kleinsten Decks mit
  ausgeblendeter Folie; `PDFSUCHER_OFFICE_SHEETS` innerhalb des Repos wird abgelehnt; die Word-Seitenzahl 3 von
  test.docx/test.doc wird geprüft statt nur ausgegeben; Median/Max je Folie ohne die letzte, wie in performance.md.
- **Abweichung von Spec §5a, bewusst (Final-Review I1):** Scheitert die Quick-Look-Vorschau eines Decks (Zahl der
  `div.slide` ≠ sichtbare Folien, kein HTML, Zeitlimit), wird das Deck als nicht lesbar ohne Text gespeichert — kein
  Rückfall „nur Text indexieren“. Grund: Die Zuordnung Text → Seite ist dann nicht verlässlich; Treffer lägen auf
  falschen Seiten. Gemessen bei 0 von 7 echten Decks. Diese Decks deckt später der SlideKit-Rückfall ab.
- **Netzwerk im Folien-WebView gesperrt (Final-Review M2):** `WKContentRuleList` (einmal je Prozess kompiliert,
  im Standard-Store unter `PDFSucherBlockNetwork`) blockiert alles außer `file:`; `data:`/`blob:`/`about:` bleiben
  erlaubt, weil sie nie ins Netz gehen und Quick Look Bilder als `data:` einbetten könnte. Dazu erlaubt die
  Navigations-Policy nur lokale Navigationen. Test: http/https-Bild, Stylesheet und iframe auf einen lokalen
  Socket → 0 Verbindungen, Folie trotzdem gesetzt (ohne Sperre: Verbindungen). Lässt sich die Liste nicht
  kompilieren, wird nichts geladen und der Indexer versucht es im nächsten Lauf erneut (kein „nicht lesbar“).
- **Reste von `PDFSucher-QL` (Final-Review M3):** `QuickLookHTML.sweepLeftovers()` löscht Einträge unter
  `$TMPDIR/PDFSucher-QL`, die älter als 10 min sind (ein abgestürzter Lauf; laufende, auch eines anderen Prozesses,
  sind jünger). **Teil B:** die App ruft es einmal beim Start auf.
- **`OOXMLPackage` mit `.mappedIfSafe` (Final-Review M1):** statt `.alwaysMapped`; auf Netzlaufwerken liest
  Foundation dann normal ein, ein abgeschnittenes oder ausgehängtes Netzlaufwerk kann so keinen SIGBUS auslösen.
- **Schema 2 → 3 verwirft OCR-Ergebnisse (Final-Review M6, keine Änderung):** Der Neuaufbau beim Öffnen eines
  Index mit Schema 2 löscht auch die erkannten OCR-Texte; Spec §7 erlaubt das. **Task 12 (Merge):** Schema-Version
  von `main` prüfen, bevor 3 übernommen wird.
- **Für Teil B (Final-Review I4):** Wird der Folien-Cache geleert („Folien-Cache leeren“) oder fehlt ein Eintrag
  (Cache-Fehltreffer, `prune`), bleibt ein Deck sonst für immer ohne Seiten. Teil B verdrahtet
  `IndexStore.requestLayout(kind: .powerpoint)` beim Leeren und bei einem Fehltreffer (bzw. nur das betroffene
  Dokument), und `prune` bekommt die Schlüsselmenge aller bekannten Indizes oder räumt nach Alter — der Cache ist
  für alle Ordner gemeinsam, ein `prune` mit den Schlüsseln nur eines Index würde die Decks der anderen löschen.
- **Merge v1.2.1 (Task 12):** `main` 1.2.1 (Tag `v1.2.1`) in `office` hineingeführt; Auflösung zugunsten von 1.2.1,
  Teil A darüber.
  - **Dateitypen an einer Stelle:** Word/PowerPoint-Endungen stehen jetzt in `SupportedSourceTypes`
    (`wordExtensions`, `powerpointExtensions`; `kind(forExtension:)` liefert `.word`/`.powerpoint`).
    `DocumentKind(fileExtension:)`, `DocumentKind.wordExtensions/powerpointExtensions` und `FolderScanner` lesen
    nur noch dort. `accepts(fileExtension:includeImages:includeOffice:)` nimmt Office nur mit `includeOffice: true`
    (Vorgabe false), `accepts(fileName:…)` überspringt zusätzlich `~$`-Sperrdateien (immer, auch `~$x.pdf`, wie
    Teil A). `openPanelTypes` bietet Word/PowerPoint **noch nicht** an, Drop/⌘O (`SourceList`) übergeben kein
    `includeOffice` – die App verhält sich wie 1.2.1, bis Teil B verdrahtet. Der 1.2.1-Test „`docx` → nil“ wurde
    entsprechend auf `.word` geändert (Regel des Controllers).
  - **Phasenfolge:** Das `Indexer`-`update` bleibt Text → Layout → OCR. Für die 1.2.1-Warteschlange (erst Phase 1
    aller Quellen, dann Phase 2) gibt es neu `Indexer(…, layoutDuringUpdate: false)` + `layOutPending(progress:)`
    (wie `recognizeText: false` + `recognizePending`), damit Teil B Phase 1 aller Ordner → Layout aller Ordner →
    OCR fahren kann. „Einzeldateien zuerst“ gibt es in 1.2.1 nur in der OCR-Warteschlange für Einzeldatei-Quellen
    (ohne Index, `SingleFileOCR`); ein Layout pro Einzeldatei hat in Teil A kein Gegenstück (Einzeldateien haben
    keinen Index, Office-Einzeldateien nimmt die App noch nicht an). **Teil B** entscheidet, ob eine
    Office-Einzeldatei direkt (wie `SingleFileOCR`, vor der Ordner-Arbeit) gesetzt wird.
  - **OCR-Bericht ohne Office:** 1.2.1 meldet nach Phase 2 alle Dokumente des Index ohne Text; Word/PowerPoint
    (auch „wartet auf Layout“, gespeichert als `noText`) sind davon ausgenommen – sie gehören in den `LayoutReport`.
  - **Markierungen:** `IndexStore.ocrPage(relativePath:pageIndex:)` (1.2.1, Weg der Vorschau über
    `OCRHighlights`) liefert auch gesetzte Office-Seiten (`source = 'layout'`), Office wird also wie ein erkanntes
    Bild markiert (normierte Boxen oben links → `OCRMapping.imageRect` → `HighlightGeometry`). `HighlightBoxes`
    blieb in 1.2.1 unverändert; der End-to-End-Test von Task 9 geht jetzt über `ocrPage`.
  - **Schema:** `main` hat in 1.2.1 nichts am Schema geändert (nur Lese-APIs `matchBatches`, `allPagesBatches`,
    `ocrPage`); `schemaVersion` bleibt 3.
  - **Für Teil B:** `DocumentHit` kennt nur `isImage` (`FolderIndex.browse`, `SearchService`); Office-Treffer
    brauchen dort eine Art bzw. `isOffice`, und `FolderIndex` muss den Indexer mit `layout:` bauen.

### Teil B (Oberfläche)
Plan `docs/superpowers/plans/2026-11-13-office-b-ui.md`, Abschnitt „Entscheidungen dieses Plans“ (2026-11-13):
- **Dokumentart:** `DocumentHit.kind: DocumentKind` ersetzt den Init-Parameter `isImage` (`isImage` bleibt als berechnete Eigenschaft); „vereinfacht“ ist `isSimplified` (= Renderer `textkit`), keine neue Spalte.
- **„vereinfacht“ bei Word:** Hinweis bei allen Dokumenten mit Renderer `textkit`, derzeit also allen Word-Formaten (Spec §15 nennt `.docx` vorläufig „vereinfacht“, §8 `.doc`); mit WordKit entfällt er für docx automatisch.
- **Symbole:** Word `doc.richtext`, PowerPoint `rectangle.inset.filled.on.rectangle`, Bild weiter `photo`, PDF ohne Symbol (Test prüft, dass die Symbole existieren; fehlt eins, nächstbestes wählen und hier eintragen).
- **Open-Panel:** bietet Word/PowerPoint immer an (wie Bilder); ist der Schalter aus, ignoriert der Classifier sie mit dem bestehenden Hinweis.
- **Schalter aus:** wirkt auf Ordner (kein Layout-Quelle, Scanner ohne Office → aus dem Index entfernt) und neue Drops/⌘O; bereits geladene Office-Einzeldateien bleiben wie Bild-Einzeldateien bei „Bilder aus“ geladen.
- **Einzeldateien:** gesetzt im Speicher (`fileLayouts` + `FileStamp`), nie in der OCR-Warteschlange; sie stehen vorn in `layoutPending` und unterbrechen eine laufende Ordner-OCR oder -Layout-Phase (verloren gehen höchstens die ≤ 2 gerade gesetzten Ordnerdateien); PDFs/Bilder unverändert.
- **Layout-Phase:** kein eigenes ✕ (abbrechbar über Quelle entfernen, Schalter aus, Beenden); neue Ordner (Phase 1) unterbrechen sie wie die OCR. Suche wird nach jedem Ordner-Layout neu ausgeführt, Durchblättern während des Laufs gedrosselt aktualisiert.
- **Kachel-Neuladen:** `layoutRevision` (≤ 1×/s gebündelt) im `LoadID` nur von Office-Kacheln; nil-Kacheln werden nie gecacht.
- **Große Vorschau:** Office als einseitiges `PDFDocument` je Seite (`singlePage`), nicht ganze Datei (495-Seiten-Word wäre zu teuer).
- **Kachel-Provider:** `ForeignPageProvider.pageDocument(_:maxPixel:)` (Vorgabe aus `makePage`), `OfficePages` liefert Folien aus dem verkleinerten Cache-Bild (erste Kachel < 300 ms); Hook-Funktion daher mit `maxPixel`.
- **Cache-Pflege:** Start: `QuickLookHTML.sweepLeftovers()` + Altersprune (180 Tage ohne Nutzung, Nutzung = `slideCount`-Zugriff); nie `prune(keeping:)` mit nur geladenen Schlüsseln. Fehltreffer: Einzeldokument neu vormerken, einmal je Pfad/Stamp und Sitzung.
- **Filter:** vier Häkchen immer sichtbar (auch wenn Bilder/Office aus), wirkt nur auf die Anzeige im `AppModel`; Speichern/Drucken folgen der ungefilterten Reihenfolge.
- **Office-Problemlisten:** aus dem ganzen Index (wie OCR seit 1.2.1), nicht aus dem letzten `LayoutReport`; Zähler in den Einstellungen über `layoutCounts()`.
- **Sperrdateien bei Drop/⌘O:** `SourceClassifier` prüft per Dateiname (`accepts(fileName:…)`), `~$…` wird für alle Typen abgelehnt.
- **`LayoutCounts` (Task 2):** jedes Office-Dokument zählt genau einmal – wartend (`needs_layout = 1`, auch ein neu vorgemerktes, früher fehlgeschlagenes oder gelesenes) geht vor; sonst Status `error` = fehlgeschlagen, `ok`/`noText` = gelesen. Wartende nicht nach Art getrennt (Vorgabe).
- **`LayoutReport` (Task 2):** `failed`/`noText` kommen nach jedem Lauf (auch ohne wartende Dateien) aus dem ganzen Index; `Indexer.store` sammelt sie nicht mehr selbst.
- **Cache-Nutzung (Task 2):** das „einmal je Schlüssel und Prozess“-Memo von `slideCount(for:)` hängt an der `SlideCache`-Instanz (in der App gibt es nur `.shared`), damit Tests mit eigenem Cache-Ordner sich nicht gegenseitig beeinflussen; berührt wird nur ein vollständiger Eintrag.
- **`pageDocument` (Task 2):** PowerPoint mit `maxPixel` zeichnet das verkleinerte Cache-Bild unkomprimiert (kein JPEG) auf eine Seite in Foliengröße; Word und ohne `maxPixel` = Ausgabeseite. Negativer Seitenindex → nil.
- **`FolderIndex` (Task 3):** die Layout-Quelle kommt aus einer Fabrik (`makeLayout`, Vorgabe `OfficeLayoutSource()`, intern für Tests mit Fake); ein neuer `FolderIndex` listet Office bis zum ersten `configure` (Vorgabe von „office.include“ ist an). `configure(_:includeOffice:)` baut den Indexer nur bei geänderter OCR-Einstellung oder geändertem Schalter neu.
- **Schalter-Wechsel (Task 3):** folgt `ocrSettingsChanged` (alle Ordner `configure`, erneut in Phase 1); der Office-Schalter allein setzt eine per ✕ angehaltene Texterkennung nicht fort (nur ein OCR-Wechsel tut das, wie bisher).
- **Übergang bis Task 5 (erledigt in Task 5):** Office-Einzeldateien wurden ab Task 3 per Drop/⌘O angenommen, liefen aber bis Task 5 noch über den Einzeldatei-Weg für PDFs (unlesbarer Eintrag mit Seitenzahl 0, bei jeder Suche „PDF kann nicht gelesen werden …“). Seit Task 5 werden sie im Speicher gesetzt (kein PDF-Weg, kein PDF-Hinweis); abgesichert durch `SingleFileLayoutTests.singleDocxIsLaidOutAndSearchable`.
- **Layout-Warteschlange (Task 4):** Ein Ordner kommt nach jedem erfolgreichen Phase-1-Lauf nur bei „office.include“ an nach `layoutPending`; ist der Schalter aus, fällt sein letzter `LayoutReport` weg. Schalter aus stoppt ein laufendes Layout (über die Phase-1-Neuaufnahme, wie `preemptRecognition`), leert `layoutPending` und alle `LayoutReport`s; `nextLayout()` liefert bei „aus“ nichts.
- **`layoutRevision` (Task 4):** steigt, sobald ein Fortschritt mehr fertige Dateien meldet (höchstens 1×/s, nachlaufend gebündelt), und am Ende jedes Laufs – auch eines unterbrochenen (dessen fertige Dateien bleiben). Durchblättern wird im gleichen Moment gedrosselt aufgefrischt; die Suche läuft nur nach einem vollständigen Lauf neu (ein unterbrochener Lauf wird von Phase 1 des neuen Ordners ohnehin mit einer Suche gefolgt).
- **Status bei Ordnern ohne Office (Task 4):** die Layout-Phase läuft trotzdem (sie liefert die Problemlisten aus dem ganzen Index); die Statuszeile zeigt dabei kurz „Word/PowerPoint 0/0“, wie „Texterkennung 0/0“ bei Ordnern ohne Scans.
- **Beschädigter Index während des Layouts (Task 4):** wie in der Texterkennung einmal neu aufbauen (Phase 1 von vorn), sonst „Indexieren fehlgeschlagen“.
- **Merge 1.2.4 (main `2acdedd`):** `main` 1.2.2–1.2.4 (Suchverlauf, Schriftgröße der Werkzeugleiste, Kachel-Cache auf der Platte, Einstellungsfenster) in `office` hineingeführt; Auflösung zugunsten von `main`, Office darüber. `ThumbnailCache.swift`/`TileDiskCache.swift` unverändert von `main` (Office-Hook folgt in B13). Konflikte nur in `AppModel` („Index löschen“: `layoutReports` und Kacheln entfernen; nach Phase 1: Layout-Warteschlange und `pruneStale` beide) und in den Doku-Dateien (1.2.x-Abschnitte vor „1.3 Office“).
- **Kachel-Cache-Bereinigung und Office (Merge 1.2.4):** `TileDiskCache.pruneStale` prüft je Cache-Ordner nur die `source`-Datei (Pfad, Änderungsdatum, Größe): Datei fehlt bei vorhandenem Ordner oder hat sich geändert → Ordner weg; Ordner ohne `source` → weg (nur beim Start). Keine Prüfung von Endung oder Dokumentart, also bleiben Kacheln von Word/PowerPoint-Dateien erhalten; keine Änderung nötig, abgesichert durch `OfficeTileCacheTests.diskCacheCleanupKeepsOfficeTiles`. **Für B13:** Hängen Office-Kacheln am Pfad der `.docx`/`.pptx`, macht ein Neu-Layout ohne Dateiänderung (Seite neu setzen, neue Layout-Version) die Kacheln nicht ungültig — der Kachelname muss daher die Layout-Version bzw. `layoutRevision`/den Cache-Schlüssel enthalten.
- **Testkorrektur (Merge 1.2.4):** `LayoutQueueTests.officeOffDuringLayoutRemovesOfficeDocumentsFromRealIndex` wartete nur auf `.layingOut`; die Statuszeile zeigt das kurz bevor die Layout-Quelle aufgerufen wird (einmal `attempts == 0` gesehen). Der Test wartet jetzt auf den Aufruf selbst.
- **Kachel-Hook (Task 13):** `ThumbnailCache(…, foreign:)`; in `render(_:)` neben dem Bild-Zweig: Datei, die der Provider `handles`, → `foreignDocument(for:page:maxPixel:)` (einseitig, Seite 0, `maxPixel` wie bei Bildern ≤ 2048), nicht im Dokumenten-Pool; nil → nil, nichts gecacht (Speicher wie Platte). Hilfsfunktionen in `ThumbnailCache+Foreign.swift`, damit `ThumbnailCache.swift` bei späteren Merges von `main` nur wenige Zeilen Unterschied hat. ViewerUI kennt nur `ForeignPageProvider`; `ViewerModel.foreignPages` (App: `OfficePages()`, Beispiel/Test-Fakes: nil) liefert ihn `ContentShell`.
- **Veraltete Office-Kacheln (Task 13):** neue Anforderung `ForeignPageProvider.contentVersion(_:)` (Vorgabe ""); `OfficePages` liefert `renderer:version` der Layout-Quelle je Art (`textkit:1`, `quicklook:1`), bei PowerPoint dazu den Slide-Cache-Eintrag (`|slides:n` bzw. `|-`). Bei Office-Dateien steht im `ocrVersion`-Feld des Kachelschlüssels (und damit im Plattennamen) immer `"ofc:" + contentVersion + "|" + ocrVersion`, auch ohne Markierung. Der Provider wird nur auf dem Render-/Anfrage-Pfad gefragt, nie im Main Actor; `cachedImage` nimmt die zuletzt gesehene `contentVersion` je Datei. Datumsvergleiche bleiben bei `FileStamp`/`TileDiskCache`.
- **Tests (Task 13):** in eigener Suite `ThumbnailCacheForeignTests` (eigene Datei statt Ergänzung von `ThumbnailCacheTests`, aus demselben Merge-Grund).
- **Office-Einzeldateien (Task 5):** `fileLayouts[Pfad]` = `FileLayoutState` (`pending` / `laidOut(Ergebnis, FileStamp)` / `failed`), Suche über `LaidOutTextSource` (Seiten nur bei gleichem `FileStamp`, sonst keine; `failed` wirft `TextSourceError.unreadable`, damit der Office-Hinweis kommt). Bei jedem Zustandswechsel neue `SingleDocumentSearch` (deren Seiten-Cache hängt am Änderungsdatum, nicht am Layout).
- **Geänderte Einzeldatei nach dem Setzen (Task 5):** Suche und Durchblättern prüfen den `FileStamp` (abseits des Main Actors); ist er anders, zählt die Datei als wartend (keine Treffer, Seitenzahl 0, kein Hinweis) und wird vorn in `layoutPending` erneut gesetzt. `ocrText(for:)` liefert dann nil.
- **Vorrang (Task 5):** Eine Office-Einzeldatei unterbricht Ordner-OCR und Ordner-Layout, aber nicht eine laufende Einzeldatei-OCR (sie wartet dahinter). Eine laufende Einzeldatei-Layout wird von nichts unterbrochen außer Entfernen der Quelle bzw. Anhalten der ganzen Warteschlange (Ersetzen, Alle entfernen): neue Ordner (Phase 1) und Schalter aus lassen sie fertig laufen (`preemptLayout` nur für Ordner).
- **Schalter „Word/PowerPoint“ aus (Task 5):** leert aus `layoutPending` nur Ordner; geladene Office-Einzeldateien bleiben geladen und werden weiter gesetzt (passt zu „bleiben wie Bild-Einzeldateien geladen“).
- **Andere Fehler (Task 5):** Fehler außer `unreadable`/Zeitlimit lassen die Datei `pending` (aus der Warteschlange genommen); erneut versucht bei jedem `add` (Drop/⌘O, auch derselben Datei) und beim nächsten Start. Zeitlimit = `fileLayoutTimeout` (120 s, intern für Tests), danach `failed("Zeitlimit")`.
- **Status (Task 5):** Während des Setzens `.layingOut(folder: 1, folders: 1, done: 0, total: 1)`, nach Erfolg kurz `done: 1`; `updateIndexStatus` überschreibt diesen Status nicht mit Ordnerpositionen, solange die Einzeldatei läuft. Danach wie bei Einzeldatei-OCR (ohne Ordner `.none`).
- **Hinweise (Task 5):** `noText` einer wartenden Office-Datei → kein Hinweis; gesetzt ohne Text → „Im Dokument wurde kein Text gefunden“; unlesbar/Zeitlimit → „Word- oder PowerPoint-Datei kann nicht gelesen werden“. Beide werden wie die anderen Datei-Hinweise von einer fehlerfreien Suche gelöscht.
- **Review-Korrekturen (Task 5):** `failed` trägt den `FileStamp` (`failed(Grund, FileStamp?)`); ändert sich die Datei, gilt ein unlesbarer Eintrag wie ein gesetzter als veraltet und wird neu gesetzt (eine beim Drop noch kopierte/synchronisierte Datei bleibt nicht für die Sitzung unlesbar). „Unlesbar“ oder Zeitlimit bei einer Datei, die sich während des Laufs geändert hat → `pending` (noch einmal). Die Stamp-Prüfung der Suche sitzt in `LaidOutTextSource` (wirft `StaleFileLayout`, keine Vorprüfung mehr), damit eine Änderung kurz vor dem Lesen nie „kein Text“ zeigt und nichts unter dem neuen Datum gecacht wird; Durchblättern prüft weiter selbst (es liest keine Seiten). Zeitlimit wie `Indexer.layOut` über `LayoutRace` (jetzt `public` in IndexKit): Rückkehr sofort bei Zeitlimit oder Abbruch, eine Quelle, die den Abbruch ignoriert, hält die Warteschlange nicht auf, ihre späte Antwort wird verworfen. `updateIndexStatus` lässt den Status einer laufenden Einzeldatei (Layout und OCR) stehen, auch ohne Ordner.
- **Speicher (Task 5):** `fileLayouts` hält je geladener Office-Einzeldatei das ganze `LayoutResult` (Text und Wortrahmen aller Seiten) für die Sitzung; begrenzt durch die geladenen Einzeldateien, frei beim Entfernen, Ersetzen oder „Alle entfernen“.
- **Große Vorschau (Task 7):** `DetailDocument.load(_ ref:reusing:foreign:)` nimmt jetzt die Seite statt der URL; für Dateien, die der Provider `handles`, kommt `pageDocument(ref, maxPixel: nil)` (volle Qualität) detached, `singlePage = ref.pageIndex`, angezeigt wird Seite 0 (`documentPageIndex(for:)`). nil oder leeres Dokument → `.preparing` („Vorschau wird vorbereitet …“ mit `ProgressView`); fehlende Datei weiter `.missing`. Wiederverwendung nur bei gleicher URL, Seite und Änderungsdatum (PDF/Bild: nur bei `singlePage == nil`). Beim Seitenwechsel innerhalb einer Office-Datei zeigt die Vorschau kurz den Ladekreisel statt der alten Seite; war schon „Vorschau wird vorbereitet …“ für dieselbe Datei zu sehen, bleibt der Hinweis stehen (`placeholder`).
- **Neu laden bei Layout-Fortschritt (Task 7, Review):** `task(id:)` = Seite + Zähler `retry`. `onChange(of: layoutRevision)` erhöht `retry` nur, solange eine Office-Seite `.preparing` ist und kein Laden läuft (`retriesOnLayout(load:isForeign:loading:)`, `loadingKey` = laufende Aufgabe); eine ladende oder angezeigte Seite wird nicht neu gestartet – auch nicht, wenn sie beim Blättern in derselben Datei oder bei einem Neuversuch `.preparing` als Platzhalter zeigt (`layoutRevision` steigt bis zu 1×/s, ein detached Rendern lässt sich nicht abbrechen, eine langsame Folie käme sonst nie an). Nicht über `layoutRevision` im Schlüssel, damit die eigenen Änderungen der Aufgabe an `load` (Platzhalter, Ergebnis) sie nie selbst neu starten. Stieg die Revision während des Ladens und ist das Ergebnis `.preparing`, wird einmal nachgeladen. Wiederverwendung über `reusable(load:for:)`.
- **Main Actor (Task 7):** `ForeignPageProvider.handles(_:)` wird im Main Actor aufgerufen (Schlüssel/Knopf der Vorschau) – dokumentierte Ausnahme, nur Endungsprüfung; `pageDocument` nie.
- **Zoom bei Office-Seiten (Task 7):** `PDFPageView` setzt `applied` zurück, sobald die bestehende Ansicht ein neues Dokument bekommt (andere Office-Seite – Seitenindex dort immer 0 –, oder dieselbe Datei nach Datumsänderung neu geladen), damit die Zoomstufe darauf wieder angewandt wird; Modus und Stufen bleiben wie bisher erhalten.
- **Öffnen-Knopf (Task 7):** `ViewerText.openOriginal(kind:)` – Word/PowerPoint „Original öffnen“, PDF/Bild „In Vorschau öffnen“; Symbol bei allen `arrow.up.forward.app`, Aktion weiter `openInPreview` (Weiterleitung an die Standard-App ist Task 6). Art aus der Dateiendung (`DocumentKind(fileExtension:)`, sonst PDF).
- **Ausgabe mit Office-Seiten (Task 6):** Sichern, Drucken und „Fehlende Seiten entfernen“ geben `AppModel.foreignPages` an `Merger(foreign:)`, `PrintDocument.build(_:foreign:)` bzw. `Merger.unavailable(_:foreign:)`; alles weiter in einer detached Aufgabe (Word-Layout und Folien-Dekodierung nie im Main Actor). `Printer.printOperation(for:foreign:)` wird nicht benutzt. Eine PowerPoint-Folie ohne Eintrag im Folien-Cache zählt als fehlend (wie eine fehlende PDF-Seite) und wird von „Fehlende Seiten entfernen“ abgehakt.
- **Provider (Task 6):** `AppModel.init(…, foreignPages:)` mit Vorgabe `OfficePages()`, für Tests mit Fake; `ViewerModel.foreignPages` liefert denselben Provider (Kacheln, Vorschau, Ausgabe aus einer Quelle).
- **Doppelklick/„Original öffnen“ (Task 6):** `openInPreview(_:)` leitet Word/PowerPoint (`DocumentKind(fileExtension:)?.isOffice`, unabhängig vom Provider) an `AppEnvironment.openWithDefaultApp(_:)` weiter; `SystemEnvironment` ruft nur `NSWorkspace.shared.open(url)` (die Standard-App des Nutzers, z. B. Pages, Keynote oder Office) – nie eine App per Bundle-ID oder AppleScript. PDF/Bild weiter in Vorschau. Der Name `openInPreview` bleibt (ViewerModel-Schnittstelle).
- **Reihensymbole (Task 8):** Word `doc.richtext`, PowerPoint `rectangle.inset.filled.on.rectangle`, Bild weiter `photo`, PDF keins; beide Office-Namen mit `NSImage(systemSymbolName:accessibilityDescription:)` geprüft (vorhanden, Test `rowSymbolsExist`). VoiceOver-Label = `ViewerText.kindLabel(kind)` („PDF“, „Word“, „PowerPoint“, „Bild“), ersetzt `imageLabel`.
- **„vereinfacht“ (Task 8):** kleine umrandete Kapsel rechts neben dem Reihentitel bei `hit.isSimplified` (Renderer `textkit`, derzeit alle Word-Dateien), Tooltip und VoiceOver-Hinweis `simplifiedHelp`, Kennung `simplifiedHint`. View-Test über `fittingSize` (die SwiftUI-Bedienungshilfen-Hierarchie ist im Test ohne Bedienungshilfe-Client leer, Kennungen lassen sich dort nicht finden).
- **Reihe ohne Seiten (Task 8):** `ViewerText.rowHint(_:)` – nicht lesbar → „nicht lesbar“, Word/PowerPoint mit `pageCount 0` → „Wird für die Anzeige vorbereitet …“, sonst „Seiten werden gelesen …“.
- **Texterkennungs-Plakette (Task 8, Review Focus 1):** `showsOCRBadge(kind:ocr:)` = `kind == .pdf && ocr != nil` (ersetzt `isImage:`); Layout-Text von Office-Seiten aus `ocrPage` zeigt keine Plakette. Art kommt als neuer Parameter `kind` aus `DocumentHit.kind`, nicht mehr aus der Dateiendung.
- **Office-Kachel ohne Bild (Task 8):** Phase `.preparing` (Sanduhr + „Vorschau wird vorbereitet …“) statt `.unavailable`, wenn Word/PowerPoint und Datei vorhanden (`placeholderPhase(kind:fileExists:)`); fehlende Datei weiter `.missing`. Tooltip `tileHelp(kind:)` („… Doppelklick: Original öffnen“), Bedienungshilfen-Aktion `openOriginal(kind:)`.
- **Kachel neu laden nach Layout (Task 8, Review):** `LoadID` enthält `layoutRevision` nur für Word/PowerPoint-Kacheln, die noch kein Bild zeigen (Phase `.loading`/`.preparing`; `loadID(…kind:layoutRevision:showsImage:)`, sonst 0). `DocumentRow` liest `model.layoutRevision` nur in Office-Reihen, damit PDF-/Bild-Reihen bei Layout-Fortschritt (bis 1×/s) weder neu zeichnen noch laden. Eine Kachel mit Bild lädt bei Layout-Fortschritt nicht neu; eine geänderte Datei bekommt über ihren Stempel trotzdem einen neuen Schlüssel. Beim Wechsel von „wartet“ zu „Bild“ ändert sich die `LoadID` einmal (Revision → 0); das Nachladen kommt aus dem Speicher-Cache. Die Plakettenabfrage (`ocrText`) läuft nur für PDF-Kacheln.
- **Word-Seite ohne Bild (Task 8, offen):** Eine gesetzte Word-Seite (`pageCount > 0`), für die der Provider dauerhaft nil liefert, bleibt bei „Vorschau wird vorbereitet …“ stehen; es gibt keine Meldung und keinen neuen Versuch außer bei Layout-Fortschritt. Folgearbeit zusammen mit Task 9.
- **`slidesMissing(for:)` (Task 8):** neue `ViewerModel`-Anforderung; die Kachel meldet sie, wenn `reportsSlidesMissing(kind:pageCount:phase:)` gilt (PowerPoint, `hit.pageCount > 0`, `.preparing`) – bei jedem Laden einer solchen Kachel, also auch je Layout-Revision; **Task 9 MUSS die Aufrufe entdoppeln** (harte Anforderung: höchstens ein Neusetzen je Pfad und `FileStamp` pro Sitzung, sonst kreist es). `AppModel.slidesMissing` ist vorerst leer (Task 9, Folien-Cache-Pflege, verschoben).
- **Dateitypen-Filter (Task 11, Spec §8a):** eigener reiner Typ `FileKindFilter` (`ViewerUI/FileKindFilter.swift`, `kinds`, `includes(_:)` für Art und `DocumentHit`, `apply(_:)`, `label`) – passt so zum `DocumentFilter`-Protokoll des Ordnerbaums (1.3.1, Branch `folder-tree`), das dort eingeführt wird und hier nicht vorweggenommen ist; dort wird er mit dem Ordnerfilter UND-verknüpft. Leere Menge = alle (ein Filter blendet nie alles aus). `GridSettings.fileKinds` (Schlüssel `filter.kinds`, `[String]` der rawValues in Menüreihenfolge; leer/ungültig → alle; Setter ignoriert die leere Menge), `toggleFileKind(_:)` lässt das letzte Häkchen stehen, `allFileKinds` = PDF, Word, PowerPoint, Bild (`nonisolated`, damit der reine Typ ihn nutzen kann).
- **Filter im Modell (Task 11):** `AppModel` hält `allHits` (ungefiltert, sortiert) und filtert an genau einer Stelle (`filtered(_:)`, von `publishFiltered`); `show` bekommt statt eines fertigen Zusammenfassungstexts einen Stil (`empty`/`search`/`browse`), damit Zusammenfassung und Zähler bei jedem Filterwechsel aus der gefilterten Menge neu entstehen. Filterwechsel über die bestehende Einstellungs-Beobachtung → `publishFiltered()`: keine neue Suche, kein Indexieren, kein Eintrag in den Suchverlauf, `onHitsPublished` wird nicht aufgerufen. Sortierwechsel sortiert `allHits` und filtert neu. `selection` wird nie gefiltert; `orderedSelection` ordnet nach `allHits`, so landen ausgeblendete angehakte Seiten beim Sichern/Drucken an ihrem Platz in der Rasterreihenfolge (Test `hiddenTickedPagesStayCountedAndAreSavedInOrder`). Fokus auf einer ausgeblendeten Seite → `nil` (wie bei neuen Treffern), frühe Treffer (`keepFocus`) unverändert.
- **Menü (Task 11):** `FileKindsMenu` (SwiftUI `Menu` mit vier `Toggle`s, Kennung `fileKindsMenu`, je Eintrag `fileKind-<art>`) steht als erstes Element im `ToolbarFlow` von `GridControls` (zweite Werkzeugzeile, `ViewControls`), ohne eigene Schriftgröße – Schrift und `controlSize` kommen aus `ToolbarArea` (`toolbarFontSize`). Das einzige verbleibende Häkchen ist deaktiviert. Titel `ViewerText.fileKindsTitle`: alle → „Dateitypen“, sonst die Auswahl in Menüreihenfolge („PDF, Word“); im Menü und Titel heißt das Bild „Bilder“ (`fileKindLabel`), das Reihen-Label bleibt „Bild“. View-Test misst: das Menü wird bei 20 pt breiter als bei 10 pt, und ein längerer Titel verbreitert die Zeile von `GridControls`.
- **Start-Pflege (Task 9, Review I1):** `AppModel.startMaintenance()` einmal je Modell im `.task` des Fensters vor `restoreSources()` (UI-Test-Pfad ebenso), detached: `QuickLookHTML.sweepLeftovers()` (Vorschau-Ordner älter als 10 min), `SlideCache.prune(notUsedSince: jetzt − 180 Tage)` und neu `SlideCache.pruneAbandonedWrites(notChangedSince: jetzt − 1 Tag)` (`.tmp`-Ordner abgestürzter Writer; das Ordnerdatum eines offenen Writers ändert sich mit jedem `append`, ein junger `.tmp` wird nie angefasst; fertige Einträge bleiben Sache des Altersprunes). Fehler nur im Log. Die Warteschlange wartet vor jedem Layout-Schritt auf alle Folien-Cache-Aufträge (Start-Pflege, „Folien-Cache leeren“; nacheinander verkettet), Phase 1 nicht.
- **Berührt-Merker (Task 9, B2-Nachtrag):** `slideCount(for:)` merkt sich einen Schlüssel erst nach erfolgreichem Setzen des Ordnerdatums; ein fehlgeschlagenes Berühren wird beim nächsten Aufruf wiederholt. Wettlauf Prune/Berühren (dokumentiert an `prune(notUsedSince:)`): ein Eintrag, der zwischen Datumsprüfung und Löschen gelesen wird, geht trotzdem; der Leser hat dann einen Fehltreffer, der wie jede fehlende Folie neu gesetzt wird.
- **„Folien-Cache leeren“ (Task 9):** `AppModel.clearSlideCache()` (für den Knopf aus B12): läuft gerade ein Layout (Ordner oder Einzeldatei, auch eine Einzeldatei – sonst unterbricht nichts sie), wird die ganze Warteschlange angehalten und abgewartet (`stopQueue`, der Ordner steht danach wieder vorn in `layoutPending`); dann `SlideCache.clear()` detached als Folien-Cache-Auftrag (auch `.tmp`-Ordner; ein noch offener Writer scheitert danach beim nächsten `append`/`commit` und veröffentlicht nichts), dann je Ordner `requestLayout(kind: .powerpoint)` und (bei „office.include“) einmal nach `layoutPending`, PowerPoint-Einzeldateien `.pending` und vorn in `layoutPending`, Warteschlange starten, `layoutRevision` erhöhen, Suche/Durchblättern auffrischen. Fehler beim Leeren oder Vormerken → Hinweis „Folien-Cache kann nicht geleert werden: …“; neu gesetzt wird trotzdem. Test `clearingCacheDuringLayoutRelaysOutOnce` (Review Focus 4).
- **`slidesMissing(for:)` (Task 9, Review I2):** nur PowerPoint; je Pfad höchstens eine Prüfung gleichzeitig (weitere Meldungen währenddessen fallen weg), Prüfungen nacheinander und detached. Ordnerdatei: `FolderIndexing.isOutdated(relativePath:)` (neu; gespeicherte Größe/Datum gegen die Platte wie der Indexer, `Indexer.isUnchanged(fileSize:modifiedAt:at:)` jetzt öffentlich, `IndexStore.document(relativePath:)` neu; nicht gespeichert = veraltet; NFC wie `requestLayout`) → Phase 1 des Ordners erneut (`enqueueIndexing`, der Indexer setzt die geänderte Datei dann neu); sonst nur wenn `foreignPages.pageCount(of:)` wirklich nil ist → `requestLayout(relativePath:)` und Ordner nach `layoutPending` (läuft sein Layout gerade, fährt er danach einmal mehr: `layoutAgain`, weil der laufende Lauf seine Arbeit schon geholt hat). Einzeldatei: Stempel geändert → wie bisher neu setzen; sonst bei fehlendem Eintrag `.pending` und vorn in `layoutPending`. Entdoppelt über `requestedRelayouts` mit „index|…“ bzw. „slides|…“ + Pfad + `FileStamp`: je Dateiversion und Sitzung höchstens ein Neu-Indexieren und ein Neusetzen, also kein Kreisen; ein schon gesetztes Deck, dessen Eintrag fehlt, wird in derselben Version nicht ein zweites Mal gesetzt.
- **Geänderte Word-Datei im Ordner (Task 9, Review I2, minimal):** `ocrText(for:)` prüft bei Word/PowerPoint-Seiten aus Ordnern `isOutdated` (detached, ein Datensatz) – das ist der Weg, auf dem Kacheln und Vorschau Wortrahmen holen. Veraltet → keine Wortrahmen (sie gehörten zur alten Fassung) und derselbe Neu-Indexier-Auslöser wie oben (einmal je Dateiversion). Die Word-Seite selbst kommt weiter aus der aktuellen Datei (`TextKitWordDocument`); eine Kachel ohne Markierung fragt nicht nach, eine geänderte Word-Datei ohne Suche wird also erst beim nächsten Start bzw. Phase 1 neu gelesen. PDFs werden nicht geprüft.
- **Einzeldateien vor Ordnern (Task 9, Review I3):** die Warteschlange nimmt nach Phase 1 zuerst wartende Word/PowerPoint-Einzeldateien aus `layoutPending` (egal wo sie stehen), dann PDF/Bild-Einzeldateien aus `recognitionPending`, erst dann Ordner-Layout und Ordner-Texterkennung. Eine neue PDF/Bild-Einzeldatei unterbricht ein laufendes Ordner-Layout wie eine Ordner-Texterkennung (`preemptLayout`, der Ordner macht danach weiter). Test `singlePDFRecognitionPreemptsFolderLayout`.
- **Überlappung beim Unterbrechen (Task 9, Review M2):** ein unterbrochenes Ordner-Layout kehrt sofort zurück (`LayoutRace`), aber ein schon laufendes WebView-Rendern bzw. `qlmanage` lässt sich nicht abbrechen und läuft im Hintergrund zu Ende (Ergebnis verworfen); die Einzeldatei, die es unterbrochen hat, rendert währenddessen schon. Kurzzeitig zwei Renderer gleichzeitig → höherer Speicherbedarf (Spitze), angenommen; ein Dauerzustand entsteht nicht, weil höchstens die ≤ 2 gerade gesetzten Ordnerdateien betroffen sind.
- **Härtung nach Review (Task 9):** (1) Während eines Folien-Cache-Auftrags warten nur Layout-Schritte: Phase 1 neuer Ordner und die Texterkennung von PDF/Bild-Einzeldateien laufen weiter; bleibt nur Layout (oder danach Ordner-Texterkennung) übrig, schläft die Warteschlange, bis der Auftrag endet, neue Arbeit kommt (`startQueueIfNeeded`) oder sie abgebrochen wird (`wakeQueue`), und schaut dann neu. Test `maintenanceHoldsOnlyLayoutSteps`. (2) `clearSlideCache` reserviert den Cache-Auftrag (`cacheJobs`) vor dem Warten auf das Anhalten, damit eine währenddessen gestartete Warteschlange kein neues Layout mit offenem Writer beginnt (Wettlauf nicht deterministisch testbar, kein eigener Test). (3) `SlideCache.clear()` macht wie die Prunes nach einem nicht löschbaren Eintrag weiter (z. B. `.tmp` eines abgebrochenen, noch schreibenden Renderns) und wirft den ersten Fehler am Ende; der Hinweis kommt dann trotzdem, aber der Rest ist leer. (4) Eine PDF/Bild-Einzeldatei unterbricht Ordner-Layout und -Texterkennung nur, wenn Texterkennung möglich ist (an und nicht per ✕ angehalten). (5) `slidesMissing` merkt sich „slides|…“ erst nach erfolgreichem `requestLayout(relativePath:)`; ein Fehler wird bei der nächsten Meldung derselben Fassung erneut versucht (die Prüfungen laufen nacheinander, also kein Doppelauftrag). (6) `nextLayout()` liefert nur noch Ordner. (7) Eine Start-Pflege, deren Cache nicht lesbar ist, schreibt nur ins Log; die Warteschlange läuft weiter (Test `queueContinuesWhenMaintenanceFails`).
- **Nach „Folien-Cache leeren“ (Task 9, angenommen):** `layoutRevision` steigt sofort; sichtbare PowerPoint-Kacheln laden neu, finden keinen Eintrag und melden `slidesMissing` → je Deck ein `requestLayout(relativePath:)` für ein ohnehin schon wartendes Dokument und je Ordner höchstens ein zusätzlicher, meist leerer Layout-Lauf. Angenommen (billig, einmal je Dateiversion).
- **Tests ohne echten Folien-Cache (Task 9, Review M1):** `AppModel.init(…, slideCache:)` (Vorgabe `.shared`) baut die Vorgaben von `officeLayout` (`OfficeLayoutSource(powerpoint: QuickLookSlideSource(cache:))`) und `foreignPages` (`OfficePages(cache:)`) daraus; `FolderIndex.shared(root:indexURL:slideCache:)` und `FolderIndex(root:indexURL:slideCache:makeLayout:)` ebenso. Alle AppCore-Tests übergeben `testSlideCache` (Temp-Ordner je Testprozess, `Fakes.swift`) oder einen eigenen; `OfficeOutputTests` haben einen eigenen Cache, `missingPagesUseForeignProvider` prüft jetzt auch ein Deck mit gespeicherter Folie (bleibt angehakt). Der UI-Test-Start legt den Folien-Cache in seinen Temp-Ordner. `quickLookLeftoverRoot` und `maintenanceGate` sind interne Test-Haken. Die App-Zielgruppe in `project.yml` hängt jetzt auch an `OfficeKit` (für `SlideCache` im UI-Test-Pfad).
- **Filter-Review (Task 11):** `ViewerModel.hiddenByFilter` (AppModel: `allHits.count - hits.count`, gesetzt in `publishFiltered`; Beispiel-/Vertragsmodell 0). Zusammenfassung endet dann auf „· N ausgeblendet“ (`ViewerText.withHidden`). Leeres Raster, wenn der Filter alles ausblendet (auch nach Neustart mit gespeichertem Filter): `EmptyGridState.hiddenByFilter` → „N Dateien ausgeblendet“ (Durchblättern) bzw. „N Dokumente mit Treffern ausgeblendet“ (Suche; gezählt werden Dokumente, nicht Trefferstellen), Hinweis „Der Filter „Dateitypen“ zeigt nur: …“ und Knopf „Alle Dateitypen zeigen“ (`GridSettings.showAllFileKinds()`). Frühe Treffer, die alle ausgeblendet sind, ersetzen die gezeigte Liste nicht (`applyEarly` prüft `filtered(early)`). Suchverlauf zählt ausgeblendete Treffer mit (`allHits`): ein Begriff mit nur ausgeblendeten Treffern ist eine echte Suche. Menü für VoiceOver: Label „Dateitypen“, Wert = Titel; keine Kennungen an den Menüeinträgen.
- **Einstellungs-Tab „Word/PowerPoint“ (Task 12):** eigener Tab nach „Texterkennung“ (`SettingsTab.office`, Symbol `doc.richtext`), nur mit `OfficePreferences`. Inhalt: Schalter „Word- und PowerPoint-Dateien durchsuchen“ (`office.include`), Abschnitt „PowerPoint“ mit den zwei Auswahlen (Fußzeile: „Fehlende Schriften“ gilt nur für den eigenen Viewer), „Quellen“ mit Zählern je Ordner (`AppModel.layoutCounts(for:)` detached, alle 2 s wie `OCRSourceRow`; `ViewerText.layoutCounts`, Art ohne Dateien entfällt, keine gelesen → „2 PowerPoint-Dateien nicht lesbar“, alles 0 → „Keine Word- oder PowerPoint-Dateien“), „Folien-Cache leeren“ (ruft `AppModel.clearSlideCache()` aus Task 9; `SlideCacheClearAction` sperrt den Knopf währenddessen, ein zweiter Klick wird ignoriert). Passt in 680 × 920 ohne Scrollen (`SettingsWindowTests` misst alle Tabs, also auch diesen, mit Zählerzeile; UI-Test `testSettingsTabsFitAndSizeIsKept` prüft „Folien-Cache leeren“ als letztes Element). Ein Klick-Test für den Knopf in `NSHostingView` geht nicht (Knöpfe im gruppierten Formular sind keine `NSButton`), daher Test über `SlideCacheClearAction`; Schalter (`NSSwitch`) und Auswahlen (`NSPopUpButton`) werden echt bedient bzw. geprüft.
- **„PowerPoint-Darstellung“ (Task 12, Ruling 16:40):** `office.powerPointRenderer` = `slideKit` (**Vorgabe**, „Eigener Viewer“) | `quickLook` („Quick Look (macOS)“). **„Fehlende Schriften“:** `office.fontSubstitution` = `powerPoint` (**Vorgabe**, „wie PowerPoint“) | `similar` („ähnliche Schrift“). Beschriftung „wie PowerPoint“ ohne „Arial“: gemessen ersetzt PowerPoint fehlende Schriften durch Calibri; Tooltip nennt, dass Office-Schriften wie Garamond/Century Gothic auch dann einen ähnlichen Ersatz bekommen. Die Schrift-Auswahl ist bei Quick Look deaktiviert (gilt nur für den eigenen Viewer, später auch Word). Unbekannte gespeicherte Werte gelten als Vorgabe.
- **Typnamen (Task 12, Koordinator; umgesetzt beim SlideKit-Wiring 1.3.0):** `OfficeRendering` (jetzt OfficeKit) hält mains Typen: `PowerPointRenderer` (SlideKit) und `FontSubstitution` (OOXMLKit), von OfficeKit per `@_exported import enum` weitergereicht; `PowerPointDisplaySetting` (OfficeKit) hält ein `OfficeRendering`. Die IndexKit-Platzhalter sind weg. **ViewerUI behält eigene Auswahl-Enums** `OfficeRendererChoice`/`OfficeFontChoice` (jetzt in `OfficePreferences.swift`), weil ViewerUI nicht von SlideKit abhängen darf; das `AppModel` bildet sie per rawValue ab (`OfficeRendering(_ preferences:)` → `init(powerPointRawValue:fontsRawValue:)`, unbekannt → Vorgabe). Test `uiChoicesMapToMainsTypes` sichert gleiche Fälle/Rohwerte und dieselben Schlüssel wie `OfficeRenderSettings`. Name `PowerPointDisplaySetting` bleibt (Abgrenzung zu mains `OfficeRenderSettings`).
- **Wirkung eines Wechsels (Task 12, Review 1):** `PowerPointDisplaySetting` (OfficeKit, threadsicher, `.shared` für die App) wird vom `AppModel` gesetzt und von `OfficeLayoutSource` **bei jedem Layout** gelesen; `OfficeLayoutSource.standard(cache:rendering:)` ist die eine Stelle, an der Ordner-Indizes und Einzeldateien ihre Quelle bekommen; `OfficePages(renderers:)` nimmt dieselbe Quelle für die Kachel-Version (`contentVersion`). Ändert sich eine der beiden Auswahlen, wird sie sofort übergeben; **nur wenn sich dadurch die PowerPoint-Renderer-Identität (`officeLayout.renderer(for: .powerpoint)`, Name/Version inkl. `+similar`) ändert**: laufendes Layout anhalten und abwarten (`stopQueue`), je Ordner **`IndexStore.resetLayout(kind: .powerpoint)`** (neu: Seiten löschen, `page_count 0`, `noText`, Renderer leer, `needs_layout 1` – wie eine frische Office-Datei), PowerPoint-Einzeldateien `.pending`, dann wie „Folien-Cache leeren“ einreihen, `layoutRevision` erhöhen, Suche auffrischen. **Entscheidung (Ruling: keine Treffer aus dem alten Layout):** anders als `requestLayout(kind:)` bleiben die alten Wörter nicht suchbar, bis neu gesetzt ist; die Decks zeigen bis dahin „Wird für die Anzeige vorbereitet …“ und werden nicht gefunden. Word bleibt unberührt.
- **Renderer-Identität (Task 12):** PowerPoint meldet den Renderer, der wirklich setzt: Quick Look `quicklook:1`; der SlideKit-Adapter `slidekit:101` („wie PowerPoint“) bzw. `slidekit:102` („ähnliche Schrift“) – die Schrift steckt in der Version des Adapters; der frühere Zusatz `+similar` entfällt seit dem Wiring. Damit bekommen Kacheln nach einem Wechsel neue Schlüssel und der Indexer setzt Ordner, die beim Wechsel nicht geladen waren, beim nächsten Lauf neu (`adoptLayoutRenderer`). **Neu im Indexer (Review 2):** wechselt der erwartete PowerPoint-Renderer eines Index, der schon einen hatte, löscht `adoptLayoutRenderer(…, clearingPages: true)` die alten Seiten **in derselben Transaktion** wie der neue `meta`-Wert – scheitert das Löschen, bleibt der alte Wert stehen und der nächste Lauf versucht es erneut (Test mit Trigger `failedResetKeepsOldRendererForNextRun`). Gilt auch für Versionswechsel von Quick Look; Word behält das Verhalten aus Teil A. **Beim Öffnen und zu Beginn jedes Laufs (Review 3, Runde 2):** `FolderIndex.adoptPowerPointRenderer()` macht denselben Abgleich beim Öffnen (läuft schon abseits des Main Actors) und am Anfang jedes `update`/`layOut` **innerhalb des Zugs des Indexers** (Haken `atTurnStart` von `Indexer.update`/`layOutPending`, nach `acquireTurn`, vor Phase 1 bzw. dem Layout; Runde 3: sonst könnte ein noch laufendes Layout des alten Renderers sein Deck nach dem Löschen speichern), **nicht** in `configure` – das läuft im Main Actor und fasst SQLite nicht an (eine große Löschung oder das Warten auf einen schreibenden Indexer hätte die Oberfläche blockiert); `configure` merkt sich nur die neue Layout-Quelle. Ist die Identität gleich der zuletzt übernommenen, entfällt die Transaktion ganz. Bekanntes kurzes Fenster: zwischen einem Wechsel, den ein nicht über `renderingChanged` erfasster Index erst beim nächsten Lauf sieht, und dem Start dieses Laufs kann eine Suche noch alten Folientext finden; der AppModel reiht die Ordner beim Wechsel sofort ein, das Fenster ist also kurz. `renderingChanged` ruft für geladene Ordner `adoptPowerPointRenderer()` (detached) statt `resetLayout`: der neue erwartete Renderer wird mitgespeichert, der nächste Lauf setzt nicht noch einmal zurück. Dieser Aufruf läuft außerhalb des Zugs; sicher, weil `renderingChanged` ein laufendes Layout vorher anhält und abwartet (`stopQueue`, späte Ergebnisse verworfen), Phase 1 PowerPoint nur ohne Seiten speichert, die Texterkennung PowerPoint nicht anfasst und ein danach startendes Layout im eigenen Zug zuerst übernimmt (gleiche Identität → kein zweites Löschen; die Übernahme ist idempotent). Fehler nur im Log/Hinweis; der Indexer versucht es vor dem Layout erneut. Fußzeile im Tab: „Nach einem Wechsel werden PowerPoint-Dateien erst wieder gefunden, wenn sie neu eingelesen sind.“
- **Vorübergehender Rückfall (Task 12) – erledigt (SlideKit-Wiring 1.3.0):** `OfficeLayoutSource.standard` trägt jetzt `SlideKitLayoutSource(fontSubstitution:)` als `slideKit`-Fabrik ein; der `TODO(slidekit merge)` ist entfernt. Ohne Fabrik (nur Tests, `OfficeLayoutSource(…)` direkt) setzt „Eigener Viewer“ weiter mit Quick Look.

### SlideKit-Wiring (1.3.0, Merge `slidekit-adapter` 97f7d92)

- **Merge:** `slidekit-adapter` (auf office d8e0844) ging ohne Konflikte in office 8563c0a; Tasks 9/11/12 unverändert. Suite 1562 → 1616 Tests.
- **Eine Wiring-Stelle je Seite:** Layout `OfficeLayoutSource.standard(cache:rendering:)` (eigener Viewer → `SlideKitLayoutSource(fontSubstitution:)`, Quick Look → `QuickLookSlideSource(cache:)`, gelesen bei jedem Aufruf aus `PowerPointDisplaySetting`); Seiten `OfficeDisplay.pages(for:cache:renderers:)` (eigener Viewer → `SlideKitPages(fontSubstitution:fallback: OfficePages)`, Quick Look → `OfficePages`). Beide bekommen dieselbe `FontSubstitution` aus demselben `OfficeRendering`. OfficeKit hängt dafür an SlideKitAdapter/SlideKit/OOXMLKit; ViewerUI nicht (nur `ForeignPageProvider`).
- **Wechsel:** `AppModel.renderingChanged` setzt die Auswahl, ersetzt `foreignPages` (nur wenn die Seiten sich unterscheiden: Renderer anders oder SlideKit mit anderer Schrift, `OfficeDisplay.samePages`) und erhöht `foreignPagesRevision`; `SlideDeckCache.shared.removeAll()` (`OfficeDisplay.releaseOpenDecks`). `ContentShell` baut bei neuer Revision den `ThumbnailCache` mit dem neuen Anbieter neu (statt eines umschaltenden Anbieters: so passen Kachel-Schlüssel und Zeichnung auch für Renders, die während des Wechsels laufen, zusammen); `PageDetailView` lädt eine gezeigte Word/PowerPoint-Seite neu. Ein im `init` übergebenes `foreignPages` (Tests) bleibt. Reset/Neusetzen wie Task 12, nur bei Identitätswechsel (jetzt auch beim Schriftwechsel unter SlideKit: 101 ↔ 102).
- **Ausgabe = Anzeige (Spec §9):** Sichern, Drucken und „Fehlende Seiten entfernen“ nehmen `foreignPages`, also denselben Renderer wie Kachel und Vorschau; mit SlideKit ist eine gesicherte Folie eine Vektorseite in Foliengröße mit echtem Text (Tests `savedSlideIsAVectorPageOfTheSlideSize`, `savesSlideKitSlide`). Markierungen auf SlideKit-Kacheln/Vorschau kommen über den OCR-Pfad aus den gespeicherten Wortrahmen (`highlightsOnSlideTilesComeFromStoredWordBoxes`).
- **`slidesMissing` unter SlideKit:** kein Folien-Cache, also kein Fehltreffer: es wird kein Neusetzen angefordert (und kein Deck nur zum Zählen geöffnet); die Prüfung „Datei geändert → Phase 1“ bleibt. Unter Quick Look und bei übergebenem Anbieter unverändert. Start-Pflege und „Folien-Cache leeren“ bleiben (betreffen nur den Quick-Look-Cache).
- **Erster Start dieses Builds über alten Indizes:** `FolderIndex` gleicht beim Öffnen ab (`quicklook:1` → `slidekit:101`) und löscht die alten Foliensätze in derselben Transaktion; vor Phase 1 und während des Neusetzens ist kein alter Folientext suchbar (Test `firstStartWithSlideKitDropsQuickLookTextAtOnce`).
- **Nachbesserung nach Review (`fix(office): slidekit switch polish`):** (1) `foreignPages`/`foreignPagesRevision`/`releaseOpenDecks()` wechseln erst **nach** `adoptPowerPointRenderer()` (alte Wörter weg), unmittelbar vor dem Neusetzen; ohne Identitätswechsel sofort (Test `pagesChangeOnlyAfterTheOldWordsAreGone`). (2) `ContentShell` stoppt vor dem Ersetzen den Prefetch des alten `ThumbnailCache` (`prefetch([])`), damit er keine Decks mit alter Schrift wieder öffnet. (3) Unter SlideKit prüft `slidesMissing` je Pfad und Dateiversion höchstens einmal den Index (Schlüssel „checked|…“ nach einem `stat`). (4) `ThumbnailTile.loadID` enthält `pagesRevision` (Word/PowerPoint, auch mit Bild), sichtbare Kacheln laden beim Anbieterwechsel neu. (5) Test-`AppModel`s bekommen eine eigene `PowerPointDisplaySetting()`; `.shared` schreibt nur die App.
- **Abschluss-Review (`fix(office): final review fixes`):** „Folien-Cache leeren“ unter dem eigenen Viewer leert nur den (Quick-Look-)Cache – kein Anhalten, kein `requestLayout(kind: .powerpoint)`, kein Neusetzen (Test `clearUnderSlideKitOnlyFreesTheCache`); Fußzeile je Renderer (`ViewerText.slideCacheFooter`). Fußzeile der Dateitypen nennt .docx, .docm, .dotx, .doc, .pptx, .pptm. Test `switchDuringSingleFileLayoutRelaysItOut` (Einzeldatei-Layout beim Wechsel abgebrochen, neu gesetzt, alter Text nie gefunden). Adapter-Test vergleicht nicht mehr `SlideDeckCache.shared.count` (andere Suites im selben Prozess), sondern prüft das Deck dieser Datei (`contains`, intern).
- **Office-Schriften (Merge `slidekit-officefonts` 54f4e6f):** `AppModel.startMaintenance()` (einmal je Start, auch im UI-Test-Pfad, wo die verzögerte Registrierung sonst beim ersten Deck dasselbe täte) ruft `DispatchQueue.global(qos: .utility).async { OfficeDisplay.prewarmFonts() }` (= `SlideDeck.prewarmFonts()`): nicht auf dem Main Thread, nicht als `Task.detached` (eine offene Systemabfrage hielte einen Pool-Thread); idempotent, die verzögerte Registrierung beim ersten Schriftzugriff bleibt Rückfall. Test `startPrewarmsOfficeFontsOnceInTheBackground` (Haken `prewarmFonts`). `office.officeFonts` (all/bundled/off, Vorgabe all) liest **nur OOXMLKit selbst**, einmal je Prozess; die Office-Verdrahtung (Layoutquelle, Seiten, Renderer-Identität) liest ihn nicht, und es gibt bewusst keine Einstellung dafür. Eine Änderung (per `defaults`) wirkt erst beim nächsten Start und setzt Decks nicht neu (die Identität `slidekit:101/102` hängt nicht davon ab) – angenommen, solange es keine Oberfläche dafür gibt. Die Ligatur-Korrektur ist drin: `mergedOutputKeepsSlideText` prüft „Dritte Folie“ jetzt ohne `withKnownIssue`.
- **TextKit und Schriftregistrierung (Absturz gefunden nach dem Merge):** die prozessweite Registrierung der Office-Schriften, während auf einem anderen Thread ein Word-Dokument mit TextKit gesetzt wird, ließ TextKit mit „attempted layout while textStorage is editing“ abbrechen (OfficeKitTests 2 von 5 Läufen; mit `PDFSUCHER_NO_OFFICE_FONTS=1` 6 von 6 grün). `TextKitWordDocument.init` ruft deshalb zuerst `FontResolver.prewarm()` (blockiert einmal bis die Registrierung fertig ist, danach sofort zurück): kein TextKit-Dokument entsteht vor dem Ende der Registrierung. Danach 7 von 7 Läufen und die volle Suite grün. Folge: das erste Word-Dokument wartet einmal auf die Registrierung (~250 ms, bzw. auf die Antwort der macOS-Abfrage).
- **Release-Prüfung 1.3.0 (offen):** das Lesen des Office-Schrift-Caches (`~/Library/Group Containers/UBF8T346G9.Office`) kann einmal die macOS-Abfrage „PDFSucher möchte auf Daten anderer Apps zugreifen“ auslösen – mit der signierten App im 1.3.0-UI-Durchlauf prüfen (erscheint sie beim Start, nicht beim ersten Deck?).
- **Alter Quick-Look-Folien-Cache nach dem Update:** unter der SlideKit-Vorgabe bleibt er ungenutzt liegen; die Start-Pflege baut ihn über den 180-Tage-Prune ab, sofort geht es mit „Folien-Cache leeren“. Kein automatisches Löschen beim Update (wer auf Quick Look zurückschaltet, hat ihn noch).
- **Ligatur „tt“ (erledigt):** seit dem Merge von `slidekit-officefonts` (2e1819b, ohne Standardligaturen) behalten gesicherte Folien ihren Text; `mergedOutputKeepsSlideText` prüft es ohne `withKnownIssue`. **Bekannt:** Quick Look zeichnet die Test-Decks ohne Hintergrundangabe grau, SlideKit weiß (Screenshots office-07/08).

### 1.3.2: Office-Schriften erst beim ersten Word/PowerPoint-Layout (Branch `office-fonts-lazy`)

- **Warum lazy:** der Prewarm in `startMaintenance()` (siehe „Office-Schriften“ oben) las bei **jedem** Start den Office-Schriftcache (`~/Library/Group Containers/UBF8T346G9.Office/FontCache`), und macOS fragte „PDFSucher möchte auf Daten anderer Apps zugreifen“ – auch wer nie Word/PowerPoint öffnet. Jetzt kommt die Abfrage erst, wenn wirklich Office-Dateien gesetzt werden (nie ausgelöst durch Suchen, Tippen, Kacheln oder Vorschau; läuft die Layoutphase gerade, während jemand sucht, kann sie trotzdem dann erscheinen). `startMaintenance()` wärmt nichts mehr vor; der Test `startPrewarmsOfficeFontsOnceInTheBackground` ist durch `startDoesNotPrewarmOfficeFonts` ersetzt. (Die Abfrage nach dem Ordner „Downloads“ beim Start kam vom Prune des Kachel-Caches; behoben in 1.3.1.)
- **Auslöser (einmal je Modell = je Prozess, idempotent über `OfficeFontPrewarm`, ein `Mutex<Bool>`):** `prewarmFonts` (= `OfficeDisplay.prewarmFonts()` = `FontRegistrationGate.shared.wait()`) läuft per `DispatchQueue.global(qos: .utility).async` (nicht Main Thread, nicht `Task.detached`), nur mit „Word/PowerPoint“ an, wenn
  - **Ordner:** der Layoutlauf `layoutFolder` seinen ersten Fortschritt mit `total > 0` meldet. Den meldet der Indexer (`runLayout`) direkt nach `pendingLayoutJobs()` und **bevor** die Layoutquelle das erste Dokument bekommt; `total` zählt genau die wartenden Word/PowerPoint-Jobs (auch die, die ein Rendererwechsel neu anstößt). Gewählt statt `layoutCounts().waiting` vorab (zusätzliche Abfrage, und Rendererwechsel kämen erst im Lauf hinzu) und statt „Layoutlauf startet“ (jeder Ordner bekommt nach Phase 1 einen Layoutlauf, auch reine PDF-/Bildordner mit `total == 0`). Der Haken sitzt im Fortschritts-Callback des abgelösten Laufs, nicht im Main-Actor-Strom (der puffert nur den neuesten Wert). **Grenze:** `total` kennt keine Arten; ein Ordner nur mit Decks unter Quick Look wärmt deshalb auch vor (nicht billig beobachtbar – dafür wäre eine Zählung je Art im Index nötig).
  - **Einzeldatei:** `layoutFile` eine Word-Datei zu setzen beginnt, oder ein Deck unter SlideKit (unter Quick Look nicht: Quick Look zeichnet selbst; `singleDeckUnderQuickLookDoesNotPrewarm`).
  - PDF/Bild allein, „Word/PowerPoint“ aus, oder ein Ordner ohne Office-Dateien → kein Prewarm.
  - Nie aus Suche, Tippen, Kacheln oder Vorschau (`searchingAndBrowsingNeverPrewarm`).
- **Sicherheitsnetz mit Zeitlimit, Anzeige tritt nur bei:** `TextKitWordDocument.init` wartet auf die Registrierung (ae4c89e: TextKit darf nicht neben der Registrierung setzen) über `FontRegistrationGate.shared` (OfficeKit), **höchstens 3 s insgesamt** (mehr als OOXMLKits 2-s-Grenze für den Cloud-Schriftcache plus die DFonts-Registrierung). Der erste Starter führt `FontResolver.prewarm()` einmal auf einem eigenen `Thread` aus (in der QoS des Aufrufers, sonst verhungert er unter Last; nicht GCD, siehe „Registrierung verhungerte hinter den Wartenden“) und setzt die Frist; alle Wartenden warten bis fertig oder Frist vorbei, danach nie wieder. **Starten** dürfen nur das Layout (`TextKitWordSource` → `cached(url:fonts: .start)`) und der AppModel-Prewarm; die Anzeigewege (`OfficePages`: Kachel, Vorschau, Sichern/Drucken, Seitenzahl → `cached(url:)`, Vorgabe `.join`) **treten nur bei**: sie warten auf eine schon laufende Registrierung bis zur selben Frist, sonst gar nicht, und setzen mit den bis dahin registrierten Schriften. Eine Anzeige bringt also nie die Abfrage. Folge: solange eine Abfrage offen ist, kann ein Thread (auch einer aus Swifts Pool, der eine Kachel oder Vorschau zeichnet) einmal bis zu 3 s warten. Verweigerte oder unbeantwortete Abfrage → Word wird mit Ersatzschriften gesetzt. Tests `FontRegistrationGateTests` (blockierende Registrierung über den Seam `fontGate:`, `join` vor/nach dem Start, `displayPathOnlyJoins`).
- **Spätregistrierung (gemeldet, upstream behoben):** endete die Registrierung nach der Frist doch noch (OOXMLKit registrierte die Cloud-Schriften verspätet), während TextKit setzt, wäre der alte TextKit-Abbruch wieder möglich – beim ersten Start mit offener Abfrage der Normalfall, nicht selten. Behoben upstream, indem `slidekit-fontpaths` die verspätete Registrierung streicht (Cloud-Schriften dann erst ab dem nächsten Start; Folge-Hash, vom Koordinator gemergt). Ebenso dort: 2-s-Grenze für SlideKits eigene Schriftauflösung (Folientext, Kacheln) und die einsetzbaren Schriftwurzeln.
- **Restrisiko Anzeigeweg, mit dem Font-Gate ausgeschlossen (Merge `02fe043`):** ein Anzeigeweg, der beitritt, bevor irgendwer gestartet hat, setzt ohne zu warten; startet danach das Layout die Registrierung, liefen beide früher nebeneinander. Seit `02fe043` laufen Import + Umbruch in `TextKitWordDocument.init` sowie `page(_:)` und `draw(page:in:)` in `FontResolver.withStableFonts { }` (Lese-Sperre eines prozessweiten Readers-Writer-Locks), und jede `CTFontManagerRegisterFontsForURL` in `OfficeFonts.register` nimmt ihn exklusiv: Registrierung und TextKit-Layout schließen sich aus, gleich ob beigetreten, gestartet oder nach Ablauf der 3 s. Reihenfolge: zuerst unser `FontRegistrationGate.pass(.start/.join)` (darf `FontResolver.prewarm()` anstoßen), **danach** das Font-Gate, nie darin.
- **Verklemmung geprüft (Merge `02fe043`):** (1) Im Font-Gate ruft nichts FontResolver auf (AppKit-Import, `WordPageSetup`/ZIP/XML, `TextNormalizer`, `SlideSnapshotter.wordRanges`, TextKit-Zeichnen) – die Registrierung (exklusiv, auf der Schriftenqueue) wartet also nur auf Leser, die selbst auf nichts warten. (2) Keine Verschachtelung: `thumbnail` → `draw` betritt das Gate einmal, `page` und `draw` rufen einander nicht, `OfficePages.wordPage` ruft `draw` außerhalb. (3) Sperrreihenfolge immer Instanz-`lock` → Font-Gate; die Registrierung nimmt nur das Font-Gate. (4) Unser 3-s-Warten liegt vor dem Gate; läuft die Registrierung nach der Frist weiter, wartet das Layout am Gate – korrigiert, siehe „Wartezeiten am Font-Gate“ unten. (5) Kein Aufrufer auf dem Main Thread: Indexer/Einzeldatei-Layout in abgelösten Tasks, Kacheln auf Render-Threads, Vorschau in `Task.detached`, Sichern/Drucken/„Fehlende Seiten“/Office-Prüfung in `Task.detached`. (6) Abbruch (`LayoutRace`: Zeitlimit oder Lauf-Abbruch cancelt die abgelöste Arbeit): `init` prüft `Task.isCancelled` je Seite und verlässt das Gate per `throw` (Sperre per `defer` freigegeben); eine abgehängte Arbeit hält das Gate höchstens bis zur nächsten Seite. Grenze: eine einzelne sehr lange Seite (oder `page`/`draw` eines riesigen Dokuments) hält eine wartende Registrierung so lange auf; keine Verklemmung, nur Verzögerung. Tests `WordLayoutFontStressTests` (12 parallele Word-Layouts mit `page`/`thumbnail` neben fortlaufenden echten Registrierungen, über ein Gate gestartet/beigetreten; abgebrochenes langes Layout neben wartender Registrierung): ohne das Font-Gate (lokal entfernt) stürzte der Testprozess in 1 von 13 Läufen à 60 Runden mit „attempted layout while textStorage is editing“ ab, mit ihm in 0 von 5 Läufen à 60 Runden und in keinem Suite-Lauf. Der Absturz ist selten; ein grüner Lauf beweist das Gate nicht, ein Absturz oder Zeitlimit wäre ein Befund. Länger: `PDFSUCHER_FONT_STRESS_REPEATS=60` (Vorgabe 6).
- **Upstream-Aussagen gelten hier nicht ganz:** die Einträge aus `slidekit-fontpaths` weiter unten („`TextKitWordDocument.init` … calls `FontResolver.prewarm()`“, „in the app the gate is uncontended anyway“) beschreiben deren Stand. Auf diesem Branch ruft `init` stattdessen unser `FontRegistrationGate` (`.start`/`.join`, höchstens 3 s) vor `withStableFonts`; Anzeigewege mit `.join` ohne laufende Registrierung und Layouts nach Ablauf der 3 s können zeitlich mit der Registrierung zusammenfallen. Das Font-Gate ist in der App also umkämpft, nicht frei; geordnet sind beide trotzdem.
- **Wartezeiten am Font-Gate (Korrektur zu Punkt 4 oben):** Darwins `pthread_rwlock` bevorzugt Schreiber. Ein neues Word-Layout kann deshalb so lange warten wie das am längsten laufende Layout plus eine Registrierung einer Schriftdatei. Umgekehrt nimmt die Registrierung das Gate je Schriftdatei exklusiv (~280 DFonts-Dateien); laufende Word-Layouts verzögern sie, und solange blockiert sie die serielle Schriftenqueue (SlideKit-Schriftanfragen ohne Treffer im Cache warten mit). Verzögerung, keine Verklemmung. Vorschlag an upstream: das Gate einmal exklusiv um die ganze `register(files)`-Schleife nehmen statt je Datei.
- **Registrierung verhungerte hinter den Wartenden (behoben):** `FontRegistrationGateTests.finishedRegistrationReturnsAtOnce` und `joinReturnsTrueOnceTheRegistrationIsDone` schlugen in einem von zwei Suite-Läufen fehl: trotz 5 s Frist hatte die Registrierung (ein leerer Zähler-Block) nicht einmal angefangen. Ursache: `start()` schickte sie per `DispatchQueue.global(qos: Aufrufer).async` auf GCDs globale (nicht-overcommit) Queues. Deren Threads lässt der Kernel nur zu, solange das Kontingent der QoS frei ist; Swifts kooperative Threads (16 bei 16 Kernen), die in `gate.wait()`/`join()` blockieren, zählen mit. Belegt: (1) Messung im Gate (Zeit von `start()` bis Blockbeginn) in 7 von 7 `--filter OfficeKitTests`-Läufen bis 4,0–4,9 s, immer QoS default (Testthreads), nie bei den userInitiated-Stressworkern; ein `sample` des Prozesses in diesem Moment zeigte alle 16 kooperativen Threads, u. a. `TextKitWordTests` → `TextKitWordSource.layout` → `FontRegistrationGate.shared.wait()` in `__ulock_wait`, nur ~33 Threads insgesamt (kein Erreichen des 80er-Thread-Limits, keine CPU-Sättigung). (2) Kleines Programm: 16 Tasks blockieren, jede schickt vorher einen Block an `DispatchQueue.global(qos: .default)` → 4 davon liefen nicht innerhalb 5 s; mit 15 Tasks alle sofort; mit `Thread` statt GCD alle sofort. CPU-Last allein (24 rechnende userInitiated-Threads) verzögerte nichts; >80 blockierte GCD-Blöcke ließen keine globale Arbeit mehr zu. Dasselbe in der App: Indexer-Layouts in Tasks warten in `wait()`, Kacheln/Vorschau in `join()`; ist das Kontingent voll, startet `prewarm()` erst, wenn eine Frist abläuft – jedes Layout wartet dann die 3 s und setzt mit Ersatzschriften. Lösung: die Registrierung läuft auf einem eigenen `Thread` (Name `OfficeKit.FontRegistrationGate`, `qualityOfService` aus der QoS des ersten Aufrufers), den kein Pool-Limit aufhält; „einmal starten“, gemeinsame Frist, `join` und „nie auf dem Main Thread“ unverändert, unser Warten weiter vor `withStableFonts`. `FontResolver.prewarm()` selbst nutzt die serielle `fontQueue` (eigene Queue → overcommit, bekommt immer einen Thread), ist also nicht betroffen. Regressionstest `registrationStartsWhileGlobalQueuesAreSaturated`: blockiert max(256, 16 × Kerne) Blöcke über alle QoS der globalen Queues, dann muss `wait()` in < 1 s wahr sein; mit der alten Umsetzung 4 von 4 Läufen rot (Registrierung lief nicht in 2 s), mit der neuen grün. Die globalen Queues des Testprozesses stehen dabei ~0,2 s. Nebenbefund (offen): in 1 von 20 `--filter OfficeKitTests`-Läufen mit dieser Änderung stürzte `WordLayoutFontStressTests` mit „attempted layout while textStorage is editing“ ab (Layout innerhalb `withStableFonts`); 0 in 12 Läufen ohne sie, 0 in 9 × 60 Stress-Runden mit ihr (5 davon neben 60-fach wiederholter GCD-Sättigung). Die Registrierung selbst läuft unverändert auf der `fontQueue`, die Änderung verschiebt nur Zeitpunkte; Verdacht: eine Folge der Registrierung (z. B. asynchron zugestellte Schriftänderungs-Mitteilung) bearbeitet Text Storages außerhalb des exklusiven Font-Gates – passt zu „ein grüner Lauf beweist das Gate nicht“ oben, nicht weiter untersucht; Rückfallebene siehe „Ein Word-Layout zur Zeit“.
- **Ein Word-Layout zur Zeit (Rückfallebene, Entscheidung Koordination):** Der Absturz „attempted layout while textStorage is editing“ (`NSLayoutManager _fillLayoutHoleForCharacterRange`, im Layout innerhalb `withStableFonts`) kam trotz Font-Gate und `09c1861` weiter vor: 1 von 20 `--filter OfficeKitTests`-Läufen auf 49fbf96 und 1 von 20 auf d1ab9e8. Ursache nicht belegt (Registrierungsfolge außerhalb des Gates oder TextKit 1 selbst, das abseits des Main Threads nicht als parallel nutzbar dokumentiert ist). Deshalb läuft jetzt **alle** TextKit-Arbeit an Word-Dokumenten prozessweit nacheinander unter einem `NSLock` (`TextKitWordDocument.textKit`): Import + Umbruch in `init`, `page(_:)`, `draw(page:in:)` (und damit `thumbnail`, `OfficePages.wordPage`). Er ersetzt das bisherige Instanz-`lock` (eine Sperre weniger, keine Reihenfolgefrage zwischen beiden). **Reihenfolge, immer:** `FontRegistrationGate.pass` (bis 3 s) → `textKit` → `FontResolver.withStableFonts` (Font-Gate, geteilt); nie umgekehrt, nie verschachtelt (`thumbnail` → `draw` nimmt ihn einmal, `page`/`draw` rufen einander nicht). Registrierungen nehmen nur das Font-Gate exklusiv, nie `textKit`, und warten auf nichts von uns; wer `textKit` hält, wartet höchstens auf eine laufende Registrierung (auf der `fontQueue`, overcommit) – keine Verklemmung. Kein Aufruf auf dem Main Thread (Aufrufer wie in Punkt (5) oben). Abbruch wie bisher je Seite; ein Wartender an `textKit` prüft keinen Abbruch, wartet also höchstens bis zur nächsten Seite eines abgebrochenen Layouts bzw. bis ein langes Layout fertig ist. **Kosten, gemessen** (`WordIndexBenchmark`, opt-in `PDFSUCHER_WORD_INDEX_BENCH=1`, 24 erzeugte Word-Dokumente / 227 Seiten, frischer Index je Lauf, Indexer-Vorgaben = App: 2 Layouts gleichzeitig, 16 Kerne): erstes Indexieren vorher Median 599 / 575 ms (zwei Prozesse à 5 Läufe), nachher 857 / 861 ms, also ca. +45 % für den Word-Anteil (≈ 2,5 → 3,8 ms je Seite). Erwartet: bei 2 parallelen Layouts höchstens ×2; PowerPoint (SlideKit/Quick Look) und PDF sind nicht betroffen. Folge in der App: während eines langen Word-Layouts warten Kacheln/Vorschau anderer Word-Dokumente, bis es fertig ist. Hingenommen gegen einen seltenen Prozessabsturz. Test `textKitWorkWaitsForTheProcessWideLock` (`init`, `page`, `thumbnail` warten je auf `textKit`); Tests, die AppKits Word-Import selbst aufrufen (`TextKitWordTests`, `QuickLookHTMLTests`), nehmen `textKit` ebenfalls. `init` prüft nach dem Erhalt von `textKit` sofort `Task.isCancelled`: ein abgebrochener oder abgelaufener Wartender importiert nicht mehr.
  - **Bekannte Folgen (hingenommen, Review 3ebec53):** (a) Das 120-s-Layout-Zeitlimit des Indexers enthält die Wartezeit an `textKit`. Ein pathologisches Dokument (sehr lang oder eine sehr teure Seite) kann so eine andere Datei ins Zeitlimit treiben; die wird mit „Zeitlimit“ markiert, bis sie sich ändert. Bei ~4 ms je Seite selten. (b) Kachel-Render-Threads (gemeinsam mit PDF-Kacheln) können hinter dem Indexlayout eines ganzen Word-Dokuments an `textKit` warten (`NSLock` ist nicht fair); während Word indexiert wird, können also Kacheln aller Art stocken. (c) `DocumentLRU` hat kein Single-Flight: zwei gleichzeitige Fehltreffer für dieselbe Datei layouten sie zweimal, jetzt nacheinander.
  - **Beleg, schwach:** 0 Abstürze in 20 Läufen beweist wenig – bei 1/20 Absturzrate bleiben 20 Läufe mit 0,95^20 ≈ 36 % Wahrscheinlichkeit trotzdem absturzfrei. Stärkerer Lauf (mit den Review-Fixes): `PDFSUCHER_FONT_STRESS_REPEATS=60 scripts/test.sh --filter OfficeKitTests` 3× (je 2 × 60 Stress-Runden neben der übrigen OfficeKit-Suite) und 20× `--filter OfficeKitTests` ohne Zusatz: 0 Abstürze, alle grün.
- **Tests lesen den echten Office-Schriftcache nie, ein Mechanismus:** `FontResolver.officeFontRoots` (OOXMLKit, aus `cdeb342`) ist in jedem Testprozess `.none` (Opt-in `PDFSUCHER_TEST_OFFICE_FONTS=1` nur für Korpusmessungen); `scripts/test.sh` setzt nichts mehr. Der UI-Test-Startpfad der App setzt vor jedem Schriftzugriff `OfficeDisplay.useNoOfficeFonts()` (= `FontResolver.officeFontRoots = .none`); das frühere `setenv("PDFSUCHER_NO_OFFICE_FONTS")` ist weg. Vorher hing ein AppCore-Lauf an der unbeantworteten Abfrage. Gate-Tests prüfen `officeFontRoots == .none`, bevor sie den echten Prewarm rufen.
- **Seam bleibt:** `AppModel.prewarmFonts` (Tests stubben ihn; `OfficeFontPrewarmTests` prüft Auslöser, Einmaligkeit und `Thread.isMainThread == false`). Der UI-Test-Startpfad setzt ihn weiter auf `{}`.

### 1.3.2: Speicher beim ersten Indexieren (Office)

- **Gemessen statt vermutet** (docs/performance.md „1.3.2“, `OfficeMemoryBenchmark`, synthetische Decks): das
  SlideKit-Layout der Indexphase braucht +4–5 MB für 8 Decks mit 240 großen Bildern, mit 1 oder 2 Layouts
  gleichzeitig; Quick Look im Prozess +66–145 MB, ohne klaren Unterschied zwischen 1 und 2, aber 50–150 % langsamer
  mit 1. Die AppModel-Warteschlange führt Phasen nacheinander aus (Layout und OCR überlappen nur, solange ein
  abgebrochenes Layout ausläuft); die Parallelität im Layout kommt allein aus `Indexer.layoutConcurrency` (2).
  **Entscheidung: keine Drosselung der Layoutphase** – sie spart nichts Messbares.
- **Der Hebel sind die offenen Decks der Anzeige:** ein groß gezeichnetes Deck hält bis ~375 MB dekodierte Bilder;
  `SlideDeckCache.shared` mit 4 Decks 1,5 GB, mit 2 Decks 0,77 GB. **`SlideDeckCache.shared` hat jetzt Kapazität 2**
  (immer, nicht nur beim Indexieren: einfacher, und ein Deck neu zu öffnen kostet 20–130 ms). Das Layout der
  Indexphase öffnet Decks ohnehin ohne Cache (`SlideKitLayoutSource(decks: nil)`) und gibt sie danach frei.
- **Nicht geändert (gemeldet):** SlideKits Bildcache je Deck (`ImageDecoder.maxCacheBytes` = 512 MB, Konstante in
  OOXMLKit) – kleiner ginge nur mit einer Änderung in OOXMLKit/SlideKit.
- Testhilfe: `OfficeFixtures.pptx(slideImages:)` legt je Folie ein Bild über die ganze Folie.

## 2026-11-12 — OOXMLKit / SlideKit

- **ZipArchive:** own reader (no third-party zip); file is memory-mapped with `.mappedIfSafe` (Foundation does not map network/removable volumes; a mapped file that vanishes there would raise an uncatchable SIGBUS), `init` parses only EOCD + central directory, `data(_:)` copies just the one entry. Stored and raw deflate (`compression_decode_buffer` with `COMPRESSION_ZLIB`); zip64 (EOCD locator + extra field 0x0001) supported.
- **ZipArchive CRC-32 is not verified** on read (speed; OOXML parsers fail on bad XML anyway). Entry sizes come from the central directory (also with data-descriptor flag bit 3); they are untrusted: entry capped at 512 MB, claimed size must be ≤ ~1100× compressed, offsets/sizes checked against file bounds, no `!` on file data; unexpected input throws `ZipError`, never traps.
- **ZipArchive names:** flag bit 11 → UTF-8; without it UTF-8 if valid, else ISO-8859-1 (not CP437). Lookup is exact on UTF-8 bytes (no NFC/NFD folding, no case folding, no fallback). Duplicate names: first wins. Unreadable file (I/O error) → `.corrupt`.
- **ZipArchive errors:** OLE magic `D0 CF 11 E0 A1 B1 1A E1` → `.oleCompound`; no EOCD in the last 64 KB + 22 but file starts with `PK` → `.truncated`; otherwise without EOCD → `.notAZip`. Encrypted (bit 0) entries → `.corrupt`.
- **ZipArchive inflate:** a deflate stream longer than the declared size is silently truncated to the declared size (no CRC check); a shorter one throws `.corrupt`. The EOCD search prefers the signature whose comment length reaches exactly the end of the file, so a fake `PK\5\6` inside a zip comment is skipped; otherwise the last signature found is used.
- **OOXMLNode:** `XMLParser` with namespace processing; Foundation delivers attribute names as qualified (`r:id`), so prefixes are resolved with our own scope stack (`shouldReportNamespacePrefixes = true` is required for `didStartMappingPrefix`). Attribute keys: unprefixed → local name, namespaced → `"<uri>|<local>"` (`xml:space` → `NS.xml`). Named `OOXMLNode` (not `XMLNode`) because Foundation on macOS defines `XMLNode`, which made the name ambiguous in every consumer file.
- **OOXMLNode text:** `text` is the raw concatenated direct character data (entities/CDATA decoded). Whitespace-only text of an element that has child elements is dropped unless `xml:space="preserve"` is set on it or an ancestor; `a:t` and `w:t` are always kept verbatim (leading/trailing spaces included). Only transitional namespaces are mapped; strict OOXML (purl.oclc.org/ooxml/...) is not supported yet.
- **XML security:** any `<!DOCTYPE` (UTF-8 or UTF-16 byte scan) is rejected with `XMLError.doctypeNotAllowed` before parsing (real OOXML has no DTD): no XXE, no billion laughs. Entity declarations abort too, `shouldResolveExternalEntities = false`. Nesting deeper than 256 → `XMLError.tooDeep` (also avoids recursive-deinit stack overflow).
- **mc:AlternateContent** is resolved at parse time: first `mc:Choice` whose `Requires` prefixes all resolve (in-scope declarations, including on the Choice itself) to a supported URI wins, else `mc:Fallback`, else nothing; spliced into the parent. Supported: p14, a14, p15, a16, wps, wpg, wp14, w14, w15, v (VML). Missing/empty `Requires` → unsupported. `mc:Ignorable` is not interpreted: unknown-namespace elements are kept.
- **OPCPackage:** `init(zip:)` is non-throwing; `[Content_Types].xml` is parsed in init (missing/broken → `mainPart` nil; only Overrides are used). Part lookup falls back to a case-insensitive match (OPC names are case-insensitive) and ignores a leading `/`. `resolve` handles `.`/`..` (clamped at the root), absolute targets and percent-decoding; fragments and external targets are not handled. `relationships(of:)` returns `[:]` for missing or malformed rels; first Id wins.
- **PresentationInfo:** presentation part = root rel ending in `/officeDocument` (must exist in the zip), else content-type override (pptx or pptm). Slides with an unresolvable rId, external rel or missing part are skipped and neither counted nor numbered (guess at PowerPoint behaviour). `hidden` = `show` is `0`/`false`; an unparseable slide counts as visible. `powerPointNumber` = position among listed slides + `firstSlideNum` (default 1) − 1. Slide size from `p:sldSz` EMU/12700, default 720×540.
- **Rename:** `XMLNode` → `OOXMLNode` (collided with Foundation's `XMLNode`); `XMLError` kept.
- **Colors (ColorResolver):** modifiers apply in document order on an sRGB base. lumMod/lumOff/satMod/satOff/hueMod/hueOff/comp work in HSL (matches PowerPoint's picker: accent1 4472C4 + lumMod 75% = 2F5597, lumMod 60% + lumOff 40% = 8FAADC). tint/shade work per channel in linear RGB, as LibreOffice does (oox color.cxx: shade c·v, tint 1−(1−c)·v after sRGB→linear); the spec (ECMA-376 §20.1.2.3) gives no formula. Confirmed in slidekit-ref: D2's Medium Style 2 table (accent1 F8981E) has band fills FCDDCC (tint 40 %) and FEEFE7 (tint 20 %) in PowerPoint's PDF, exactly SlideKit's values; an sRGB-space tint would give green channels D6/EB instead of DD/EF. red/green/blue(+Mod/Off) also linear (LibreOffice), inv = sRGB 1−c, gray = BT.601 luma, gamma/invGamma = sRGB↔linear, alpha/alphaMod/alphaOff on the alpha channel. Unknown modifiers are ignored; unknown scheme names, prstClr names and unparseable base values → nil.
- **Colors (context):** `phClr` → `ColorContext.placeholderColor`, nil → black and `resolveDetailed` reports `placeholderMissing`. sysClr uses `lastClr`, else a small table of system names. Default `ColorMap` = bg1→lt1, tx1→dk1, bg2→lt2, tx2→dk2, rest identity; `ColorMap(override:)` returns nil for `a:masterClrMapping` ("inherit"). Theme falls back per entry to the Office 2013–2022 theme; per-script fonts (`a:font script`) kept in `majorScripts`/`minorScripts`. `prstClr` covers ~75 common names (dk*/lt* per LibreOffice), not all 140.
- **FontResolver order:** theme shorthand (`+mj-lt/+mn-lt/+mj-ea/+mn-ea`; `+mj-cs/+mn-cs` → Arial, the theme has no cs font; nil/empty → minor latin, or minor EA for `.eastAsian`; no theme → Calibri Light / Calibri) → installed family (CTFontManager family list, case-insensitive; installed always wins, even Calibri/Verdana) → weight/width words stripped from the end of the name and the base tried as installed family (so "Calibri Light", which macOS lists only as a style of "Calibri", resolves to Calibri + light) → substitution table → pattern classification → Helvetica Neue.
- **FontResolver substitution table** (first installed candidate; reason: closest metrics/look among fonts that ship with macOS, so line breaks stay near the original): Calibri, Aptos, Segoe UI, Open Sans, HP Simplified, Verdana, Tahoma, Arial, `TeleGrotesk*`, `TeleNeo*` → Helvetica Neue (humanist/grotesque sans; never a serif); Lato → Lato, then Helvetica Neue; Cambria, Constantia → Georgia, Times New Roman; Georgia (missing) → Times New Roman; Consolas, Courier New, Lucida Console → Menlo; MS PGothic / ＭＳ Ｐゴシック / MS Gothic / Meiryo / any name with "gothic"/ゴシック → Hiragino Sans, MS Mincho / 明朝 → Hiragino Mincho ProN; other names containing CJK characters → Hiragino Sans; Wingdings* / Symbol (missing) → Helvetica Neue (text is mapped to Unicode beforehand, see below). Names are NFKC-normalised and lowercased before lookup (full-width Latin in CJK font names).
- **FontResolver pattern classes** for unknown names (checked in this order): CJK gothic/mincho words; mono (Mono, Courier, Consolas, Code, Menlo, Typewriter, Fixed); explicit sans (Sans, Grotesk, Arial, Helvetica, Gothic, Neo …, so "Sans Serif" stays sans); serif (Times, Georgia, Garamond, Cambria, Serif, Roman, Book, Minion, Palatino, Baskerville, Bodoni, Didot, Caslon …); everything else sans → Helvetica Neue.
- **FontResolver weight/width:** "Black/Heavy/Extrabold/Semibold/Medium/Light/Thin/Ultralight" and "Condensed/Narrow" suffixes on a name that is not itself an installed family become `kCTFontTraitsAttribute` weight/width on the substitute. Width is best effort (Helvetica Neue has condensed faces only in bold/black; a bare "Condensed" keeps regular width).
- **FontResolver bold/italic:** `CTFontCreateCopyWithSymbolicTraits`; if the family has no such face the regular face is kept (bold+italic falls back to bold, then italic only). Nothing is synthesized (no fake bold, no skew).
- **FontResolver cache/concurrency:** key (resolved family, size, bold, italic, weight, width) → CTFont in a `Mutex`; hits return the identical object (also under 200 parallel tasks: first insert wins). CTFont is not `Sendable` (checked by compiling a `Sendable`-constrained generic), so it is stored in an `@unchecked Sendable` box; safe because CTFont is immutable and Core Text is thread-safe. Cache capped at 4096 entries (cleared when full). Measured: the simple design (creation on the caller's thread, outside the lock, installed-family list lazily on first use) hangs reproducibly in the 200-task TaskGroup test on a 16-core Mac (first run of the 200-task test; `sample` showed all 16 cooperative threads in `dispatch_mach_send_with_result_and_wait_for_reply` from `XTCopyFontsWithProperties`, one idle workqueue thread, no progress for >3 min). Creating under the cache lock hung the same way, so a single in-flight request is not enough. Single tests and a standalone `concurrentPerform` stress (400 creations) do not hang. Root cause NOT proven: hypothesis is that the XPC reply needs a thread the saturated cooperative pool does not leave free. Smallest workaround kept: on cache misses (and for the one-time installed-family list) the creation runs on one dedicated serial GCD queue and the caller waits on a semaphore (`dispatchPrecondition(.notOnQueue)` forbids re-entry); hits never hop. Cost: a miss blocks the calling thread for the duration of the XPC round trip, as it would anyway.
- **Wingdings 2/3 tables** are built from the real glyph names (post table) of the installed macOS fonts, not from memory: Wingdings 2 4F ✗, 50 ✓ (the usual Office check), 51/53 ☒, 52 ☑, A3 □; Wingdings 3 70 ▲, 71 ▼, 72 △, 73 ▽, 74 ◄, 75 ►, 76 ◁, 77 ▷. Unverified codes are omitted. Wingdings 0x46 is ☞ (handptright).
- **Symbol fonts:** `FontResolver.mapSymbolText` maps Wingdings / Wingdings 2 / Wingdings 3 / Symbol codes (0x20–0xFF and U+F020–U+F0FF) to Unicode (e.g. Wingdings A7/FC/D8 → ▪ ✓ ➢, Symbol B7 → •, Symbol letters → Greek). Partial tables (bullets/checkmarks/arrows/Greek that occur in decks, not the full fonts). Mapped text is returned with typeface nil (Core Text's font cascade supplies ✓ ➢ ▪ …; Menlo and Apple Symbols cover them); text with no mappable character is returned unchanged with the original typeface.
- **PresetGeometry data:** all 187 presets of ECMA-376 Part 1 Annex D `presetShapeDefinitions.xml` (copy from the LibreOffice repository) are embedded in the generated `Drawing/PresetShapeDefinitions.swift` as one raw string literal, one preset per line (whitespace between tags removed, the per-child `xmlns` hoisted to the preset element; avLst/gdLst/ahLst/cxnLst/rect/pathLst kept). Generator script lives outside the repo. Cost: ~340 KB in the binary, the file compiles in ~0.1 s, so no SwiftPM resource. The line index is built once; each preset is parsed with `OOXMLNode.parse` on first use and cached in a `Mutex`.
- **Geometry coordinates:** `GeometryBuilder.paths(_:size:)` takes the size in points and returns paths and `textRect` in shape space, origin top left, y down (the renderer draws under a flipped CTM). Guides are evaluated in EMU (size × 12700) and scaled back, so literal EMU numbers in custGeom formulas and paths without `w`/`h` come out right. A path's own `w`/`h` (> 0) scale its coordinates to the shape size. Sizes that are negative/NaN → 0, larger than 1e8 pt → clamped.
- **Guides:** builtins (w h l t r b hc vc wdN hdN ss ls ssdN cd2 cd4 cd8 3cd4 3cd8 5cd8 7cd8), then avLst defaults, then the caller's adjust values (from the file's `gd fmla="val N"`; other formulas in a prstGeom avLst are ignored), then gdLst in document order. Division by zero → 0, any non-finite result → 0, unknown guide name or operator → 0, missing arguments → 0. Angles in 60000ths of a degree.
- **arcTo:** starts at the current point; stAng/swAng are visual angles (clockwise from +x in y-down space) and are converted to parametric ellipse angles (`atan2(wR·sin θ, hR·cos θ)`, as PowerPoint/LibreOffice do), the centre is derived from the current point. Emitted as cubic Béziers of ≤ 90°; sweeps beyond ±360° keep their end point but are capped at two turns. Drawing commands without a current point start at (0,0); a command after `close` starts a new sub-path at the closed sub-path's start.
- **Unknown/unusable preset → rectangle** (full-size path, textRect = bounds). A custGeom without usable paths yields no paths (nothing drawn). `textRect` is nil when the geometry has no `a:rect`. Path `fill` (norm/none/lighten/lightenLess/darken/darkenLess) and `stroke` are kept per path; `extrusionOk` is ignored (2D only). `GeometryPath` is a named struct (not the plan's tuple), `@unchecked Sendable` because CGPath is not annotated; it stores an immutable copy.
- **Drawing coordinates:** `DrawingRenderer` draws into a context whose CTM maps points with origin top left, y down (the caller flips once per page). `Transform2D` is in points (EMU converted in `init(xfrm:)`, values clamped to ±1e8, negative/unparseable extents → 0); `affine` = flip about the centre, rotate clockwise about the centre, translate to `offset`. `childToParent` maps chOff/chExt onto the group's shape space (missing/zero chExt → 1:1). Deviation from the plan: offset/extent are `CGPoint`/`CGSize` (the plan said `CGRect`), childOffset/childExtent likewise.
- **Drawing API deviations:** tuples in Hashable/Equatable types replaced by `SrcRect { l, t, r, b }` (fractions; also used for `fillRect`/`fillToRect`) and `GradientStop { position, color }`; the gradient case carries a `Gradient` struct (stops, angle, scaled, path, fillToRect); `pattern` also carries the preset name. Resolvers take no separate `theme:` (it is `ColorContext.theme`); `drawShape` takes no `colors:` (models hold resolved colors). New `PartContext(package:part:)` resolves `r:embed` ids for blip fills and pictures. `EffectResolver.shadow` added next to `FillResolver`/`LineResolver`. `DecodedImage` has only `.bitmap(CGImage)` until the EMF task; CGImage is `Sendable` in the macOS 26 SDK, so no box is needed.
- **Fill resolution:** first fill child of spPr wins (noFill, solidFill, gradFill, blipFill, pattFill, grpFill); otherwise `p:style/a:fillRef idx` → theme fillStyleLst[idx−1] (idx ≥ 1001 → bgFillStyleLst[idx−1001], idx 0 or out of range → none) with phClr = the fillRef's own color. Nothing specified → no fill. An explicit fill with an unresolvable color → none (no fallback to the style). Theme blip fills are not resolved (their rels belong to the theme part). `grpFill` → the nearest enclosing group's explicit fill (a group without a fill inherits; outermost → none).
- **Gradients:** linear axis through the box centre at `ang` (clockwise, y down), spanning the box's projection on the axis; `scaled="1"` computes it in a unit square stretched to the box. Path gradients: `circle` radial from the fillToRect centre to the farthest corner, first stop at the centre; `rect` and `shape` approximated by a radial gradient that reaches the farthest side. Stops sorted, clamped to 0…1; one stop = solid; none = no fill.
- **Pattern fills** (`pattFill`) are drawn as one solid color: fg/bg blended by the preset's ink share (`pctN` → N %, `dk*`/`wd*`/`solidDmnd` → 50 %, everything else → 33 %). Real hatch tiles would need a CGPattern per preset; patterns are rare in decks.
- **Lines:** the theme line style of `lnRef` (phClr = its color) is the base, spPr `a:ln` overrides property by property (w, cap, fill, dash, join, head/tail). No fill anywhere or `noFill` → no line. Missing `w` → 0.75 pt (PowerPoint's default); `w="0"` → CG line width 0 (device hairline). Default cap flat, join round (miter limit from `lim`, default 8). prstDash in multiples of the width (LibreOffice values): dot 1/3, dash 4/3, lgDash 8/3, dashDot 4/3/1/3, lgDashDot 8/3/1/3, lgDashDotDot 8/3/1/3/1/3, sysDash 3/1, sysDot 1/1, sysDashDot 3/1/1/1, sysDashDotDot 3/1/1/1/1/1; custDash d/sp in 100000ths of the width. Gradient/picture line fills are drawn by clipping to the stroke outline; arrowheads use the first stop / pattern fg.
- **Arrowheads:** only on the first open sub-path of the stroked paths (head at its start, tail at its end), direction from the nearest distinct neighbouring point (control point for curves). Size: width/length sm/med/lg = 2/3/5 × max(line width, 2 pt) — the 2 pt floor gives thin (0.75–1 pt) connectors visible heads (a 0.75 pt med triangle is 6×6 pt instead of 2.25×2.25 pt); confirmed in slidekit-ref: D5's 0.25 pt connector with a med triangle tail is pixel-identical to PowerPoint's at 1600 px (a head without the floor would be 0.75 pt wide). The open `arrow` is stroked at the real line width (hairline → 0.75 pt). triangle, stealth (notched), diamond and oval are filled with the line color; `arrow` is an open V stroked at line width with round joins. The line end is pulled back so it does not poke through the tip: triangle 0.9 × length, stealth 0.5 × length, arrow ½ line width, diamond/oval 0; never more than 95 % of the last segment. Heads are never dashed.
- **Pictures and blip fills:** `a:blip r:embed` via the part's relationships (`r:link`/external/unknown ids → nothing drawn); an `asvg:svgBlip` extension is ignored and the blip's own PNG fallback is used. srcRect crop (negative = padding) maps the visible source region onto the target; `a:stretch/a:fillRect` insets the target; `a:tile` is drawn stretched (approximation); `alphaModFix` → `ctx.setAlpha`. Images are clipped to the geometry; the picture line is drawn on top. Pictures have no default line.
- **ImageDecoder:** ImageIO for PNG/JPEG/GIF (first frame)/TIFF (first page)/BMP. Parts with extension wdp/jxr/hdp (HD Photo, Office keeps a PNG fallback next to it), emf/wmf/emz/wmz (vector, comes with the EMF task) and svg/svgz → nil; data starting with the JPEG XR magic `II BC 01` → nil whatever the extension (OPCPackage exposes no per-part content type for Default entries, so `image/vnd.ms-photo` is detected by extension/magic). Images larger than 8192 px on the long side are downsampled by ImageIO (memory bound, decompression bombs). Cache: part path → decoded image (failures cached too) in a `Mutex`, decoding outside the lock (first insert wins), emptied when the decoded bytes would exceed 512 MB. Missing or bad data → nil → the element is not drawn; nothing throws.
- **Shadow:** only `a:outerShdw` (blurRad, dist, dir, color with alpha) from spPr `a:effectLst`, else from the theme effect style picked by `p:style/a:effectRef` (phClr = its color); an explicit empty `effectLst` (or an `effectDag`) means no shadow. Other effects (glow, soft edge, inner shadow, reflection, sx/sy/kx/ky/algn) are ignored. Drawn with `setShadow` around a transparency layer holding fill + line, so they cast one shadow; text is outside the layer (no text shadow). CG shadow offsets/blur are in base space and ignore the CTM, so the y-down page offset is mapped through `ctx.ctm` (flip and zoom included) and the blur scaled by the CTM's scale — assumes base space = the space of `ctx.ctm`, true for bitmap and PDF contexts. The direction is page-relative (rotWithShape ignored).
- **Text hook:** `drawShape` calls `text(ctx, rect)` after fill and line, with the CTM in shape space (rotation applied, never mirrored; flipV turns the text by 180°, as PowerPoint does) and the geometry's `a:rect` (or the bounds). Groups pass the mirror parity down (a group with exactly one of flipH/flipV mirrors; nested groups accumulate); when it is odd the text pass mirrors back horizontally about the text rect's centre, so text in a flipH group stays upright and in a flipV group is turned by 180°, like a shape's own flipV. A zero-size shape still gets the callback (no fill/line); a non-finite transform draws nothing. `path@fill` lighten/darken modulate a solid fill (tint 60/80 %, shade 60/80 %); `fill="none"` sub-paths are only stroked.
- 2026-11-12 22:44 — Chris: PowerPoint goes via Quick Look first (office thread); the own SlideKit renderer follows as a replacement once better. This branch continues with SlideKit Tasks 8–14 after OOXMLKit.
- **ParagraphSetter API (shared with WordKit):** everything public, Sendable, Equatable where possible, memberwise inits with defaults (`RunStyle.default` = minor font, 18 pt, black). Deviations from the brief: tuples replaced by `InlinePlacement {id, rect}` and `WordRect {range, rect}`; `wordRects` returns `[WordRect]`; `underline` is an enum `Underline {none, single, double}` (Word needs double; other PowerPoint kinds map to single); added `SetLine.top` (line top, needed to draw/split line ranges) and `SetLine.width` (visible width); added `SetParagraph.spaceBefore/spaceAfter` (points, not in `height`) and `SetParagraph.bullet: SetBullet?` (text, picture id, origin, rect); `ParagraphSetter.init(fonts:lineHeightBase:)` with default `.fontSize(factor: 1.2)` (PowerPoint) and `.fontMetrics` (ascent+descent+leading, for Word's "auto"). `SetParagraph` has no public init (it carries Core Text lines; only the setter makes it). Units: anything named percent is 0–100 (`baselineShift`, `sizePercent`, `Spacing.percent`); `LineSpacing.multiple` is a factor; `lineSpaceReduction` a fraction (0.2 = 20 %); `RunStyle.spacing` in points (caller converts spc/100).
- **plainText and indices:** `plainText` = run texts concatenated, tab → "\t", lineBreak → "\n", inline → U+FFFC (one UTF-16 unit each). Bullet/number text is drawn but NOT in plainText (search/index text comes from the runs). `SetLine.range` and `WordRect.range` are UTF-16 offsets into plainText (NSString semantics); a line range includes its trailing spaces and line-break character. The attributed string Core Text sees has the same length: line breaks are U+2028 (line separator, no new CT paragraph), caps are applied per character only when the uppercase has the same UTF-16 length (ß stays ß).
- **Line height (ParagraphSetter defaults, WordKit):** natural = max(single, ascent + descent of the line), single = 1.2 × largest font size on the line, ascent/descent from the actual CTFonts (incl. baseline shift, inline objects as ascent = height, descent 0, the bullet on line 1). **SlideKit differs** (measured against PowerPoint, slidekit-ref): it sets `fontMetricsGrowLines: false` (natural = max(single, tallest inline object); ascent + descent and baseline shift do not grow lines), `lineBreakSetsLineHeight: false` (a break's own size does not count for the line it ends) and moves the body's first line up (first-line rule) — see the bullets "Line break size", "First line above 100 % spacing" and "Font metrics do not grow PowerPoint lines" below. The 1.2 factor is confirmed: 262 same-size line pairs at 100 % differ from PowerPoint's pitch by 0.02 pt on average, 214 at 90 % by −0.02, 80–120 % within 0.7 pt (fonts Arial/Calibri/Lato/Verdana/Aptos in the PDFs; PDF positions are quantized to 0.96 pt). `multiple(f)` → natural × max(f − lineSpaceReduction, 0); `exact(pt)` → pt (inline objects do not grow it); `atLeast(pt)` → max(pt, natural). The baseline sits at top + height − descent: extra space goes above the text (in SlideKit except for the body's first line, see the first-line rule). lineSpaceReduction applies to `multiple` only; fontScale scales all font and bullet sizes, not character spacing or inline sizes. Empty paragraph: one line (range n..<n) from endRunStyle; a trailing line break adds such an empty line too.
- **Space before/after:** resolved to points in `SetParagraph`, never folded into `height`. `percent` = percent / 100 × single line height of the first text run (1.2 × size after fontScale), so 100 % = one single line; points are taken as is. Not reduced by lnSpcReduction.
- **Indents and bullets:** first line starts at marginLeft + indentFirst, others at marginLeft; no clamping, negative x is legal (Word outdents into the page margin; tab stops are absolute from x = 0, so the setter must not move lines; SlideKit clamps marL + indent itself if PowerPoint needs it); right edge = width − marginRight. Bullet at marginLeft + indentFirst on the first baseline; first-line text at marginLeft when the bullet ends at or before it, otherwise after the bullet + 0.25 × first-run size (PowerPoint's own fallback is the next tab stop; approximation — slidekit-ref found 5 such first lines in 2 shapes, D1 and D5, within 1.4 pt of PowerPoint's text start, so it is kept). Center/right alignment moves the bullet with the first line. Bullet font/color/size follow the first text run unless given; symbol typefaces go through `FontResolver.mapSymbolText` (mapped text is drawn in the run's font, not bold/italic). Empty paragraphs get no bullet unless `set(bulletOnEmpty: true)` (Word numbers empty list items; PowerPoint does not, default false); the empty line then includes the bullet metrics and the bullet follows endRunStyle. Picture bullets: only placed (`SetBullet.rect`, bottom on the baseline); the caller draws them.
- **Auto numbers:** `<arabic|alphaLc|alphaUc|romanLc|romanUc><Period|ParenR|ParenBoth|Plain>`; unknown → arabicPeriod; alpha repeats letters after z (27 → aa); ≤ 0 or roman > 3999 → arabic digits. The caller passes the resolved number (nil → startAt).
- **Tabs:** positions are measured from the paragraph's left edge (x = 0, the text inset / page margin), the same origin as marginLeft — not from marginLeft (deviation from the ruling: DrawingML `a:tab@pos` and Word `w:tab@w:pos` are both relative to the text margin, as the ruler shows). Lines are created with `CTTypesetterCreateLineWithOffset(x)`, so CT measures stops from x = 0 for every line (verified). Default stops are multiples of defaultTab from x = 0; Core Text would continue from the last explicit stop, so those after it are added as explicit left stops up to one interval past the right edge. Hanging indent adds an implicit stop at marginLeft. Core Text mishandles negative line offsets (probe: offset −10 puts a default tab at 0 instead of 72), so with a line starting left of x = 0 the tab coordinates (offsets and stops) are shifted right by that amount and all default stops are added explicitly. Decimal = right tab with the current locale's decimal separator as column terminator; Core Text centres the separator on the stop.
- **Justify:** `CTLineCreateJustifiedLine` (factor 1, available width) on every line except the last and lines ending in a line break; `distributed` also justifies the last line (approximation, no inter-character spreading). `rtl` only sets the base writing direction; indents/alignment are not mirrored.
- **Caps/decoration:** caps all/small change only the drawn text; small caps = lowercase letters drawn as capitals at 80 % size (fonts rarely have real small caps). Underline is drawn by CTLineDraw from `kCTUnderlineStyleAttributeName` (verified with a pixel probe: it is drawn); strike is drawn manually at baseline − xHeight/2 with the font's underline thickness; highlight is a rect behind the run covering the line's ascent/descent box; baselineShift via `kCTBaselineOffsetAttributeName` (size not reduced); character spacing via `kCTKernAttributeName`.
- **Drawing:** `draw(lines:in:at:fonts:)` expects a y-down CTM; each CTLine is drawn under a local translate + scale(1, −1) with text matrix identity inside save/restore, and the caller's text matrix (not part of the gstate) is restored. Line range `r` is drawn with lines[r.lowerBound].top at `at`; the bullet with line 0. CTLine is stored in an `@unchecked Sendable` box (immutable CF object), like FontResolver's CTFont.
- **Word rects:** a word is a maximal run of letters, digits and combining marks (Unicode: umlauts count); ' and ’ between two such characters belong to the word; hyphens and other punctuation split words (E-Mail → E, Mail; a search hit across them unions the rects). Rect x from `CTLineGetOffsetForStringIndex`, y = the line's ascent/descent box, paragraph coordinates (y from the paragraph top, independent of the requested line range). A word broken across lines yields one rect per line with the sub-range on that line.
- **EMF/WMF player (Task 13), API:** `EMFDocument` / `WMFDocument` (`init(data:) throws`, `bounds` = frame in 0.01 mm, `draw(in:rect:)`), `Metafile` (`.emf`/`.wmf`, `bounds`, `draw`), `MetafileError` (`invalidHeader`, `truncated`); `DecodedImage` gained `case vector(Metafile)` (additive; WordKit must handle it in exhaustive switches). Extra: `EMFDocument.isEMFPlusOnly`. Records are parsed at init into an immutable device-independent list (shared by EMF and WMF; DIBs decoded then); `draw` replays it (MetafileRenderer). A record with size < 8 (EMF) / < 3 words (WMF), not 4-aligned (EMF) or running past the end stops parsing, keeping what was read; unknown records are skipped and counted.
- **Metafile mapping:** logical → world transform → page (window/viewport ext/org per map mode) → device → `rect`. EMF device = reference-device pixels: px/mm from szlDevice/szlMillimeters (szlMicrometers if the header extension is really there — writers like Adobe put the description string at offset 88, so the extension is read only when it ends before `offDescription`); `rclFrame` converted to device pixels is what maps onto `rect` (fallback: rclBounds + 1). MM_TEXT, ISOTROPIC (min scale, signs kept), ANISOTROPIC exact; LO/HIMETRIC, LO/HIENGLISH, TWIPS from the header's px/mm with y up (approximate: no viewport offsets beyond org). `draw` clips to `rect`. WMF: device space = placeable bbox (logical units, bounds = bbox × 2540 / unitsPerInch); window and viewport both start as the bbox and the file's window org/ext map onto it whatever the map mode (only ISOTROPIC is honoured); without placeable header the first SETWINDOWORG/EXT is the frame, taken as 96-dpi pixels for `bounds`.
- **Metafile pens/brushes:** paths are built in device units; geometric pen width × sqrt(|det|) of the logical→device transform; every pen is at least one "hairline" wide, cosmetic pens (width 0 or PS_COSMETIC) exactly that: EMF = max(1 device px, 0.1 mm), WMF = one 96-dpi pixel. End cap/join from the PS_ENDCAP/PS_JOIN bits of geometric pens (default round), cosmetic: butt/miter. Dashes: DASH 3:1, DOT 1:1, DASHDOT 3:1:1:1, DASHDOTDOT 3:1:1:1:1:1 × width (cosmetic: × 3 hairlines), USERSTYLE entries as given. Brushes: solid, null; hatched = hatch color at 40 % (mixed with bkColor in OPAQUE mode, else alpha); DIB pattern brushes = their average color. ROP2: NOP draws nothing, BLACK/WHITE force the color, others copy.
- **Metafile raster idioms:** BITBLT without a source: PATCOPY fills with the brush, BLACKNESS/WHITENESS fill, everything else (DSTINVERT, NOP, …) is skipped so nothing paints black boxes. The XOR mask idiom of GDI+'s fallback (PATINVERT with brush A, fill under a non-COPYPEN ROP2, PATINVERT again) paints A over the filled area with alpha = share of dark pixels of the fill brush (exact for black/white masks, pattern approximated by coverage). Bitmaps: SRCCOPY and unknown ROPs draw as SRCCOPY; a 1-bit SRCPAINT is held as a mask and the following SRCAND at the same place is drawn through it (white = paint; Office's transparent-bitmap pair); a lone SRCAND draws with multiply blend; NOP skipped. ALPHABLEND uses constant alpha and, with AC_SRC_ALPHA, the (premultiplied) 32-bit alpha; 32-bit BI_RGB alpha is ignored otherwise. DIBs: core/info/V4/V5 headers, BI_RGB 1/4/8/16(555)/24/32, BI_BITFIELDS 16/32, BI_JPEG/BI_PNG via ImageIO, bottom-up and top-down, ≤ 40 M pixels; RLE and DIB_PAL_COLORS palettes (→ gray ramp) not supported. StretchDIBits source rects of bottom-up DIBs count from the bottom row; BitBlt/StretchBlt source rects from the top.
- **Metafile text:** EXTTEXTOUTW (and A / WMF TEXTOUT, EXTTEXTOUT with Windows-1252; symbol charset bytes kept) with the selected font through `FontResolver` (theme nil): negative height = em size, positive = cell height (em scaled by ascent + descent), 0 = 12 device units; weight ≥ 600 bold; Wingdings/Symbol through `mapSymbolText`. Size = |height| × the transform's vertical scale; drawn upright in device space at the transformed reference point, rotated by the world transform's angle minus escapement, flipped locally for Core Text. TA_LEFT/CENTER/RIGHT, TA_TOP/BASELINE/BOTTOM and TA_UPDATECP honoured; dx positions each UTF-16 unit (ETO_PDY pairs: x only); ETO_OPAQUE fills the rect with bkColor, ETO_CLIPPED clips to it, OPAQUE bk mode fills the text box. ETO_GLYPH_INDEX text is skipped (glyph ids of a font we may not have); text inside a path bracket is drawn, not added to the path.
- **Metafile clipping/state:** clip and meta region are CGPaths in device units combined with CGPath boolean ops (RGN_AND/OR/XOR/DIFF/COPY; INTERSECTCLIPRECT = AND, EXCLUDECLIPRECT = DIFF, SELECTCLIPPATH with the poly fill rule, EXTSELECTCLIPRGN rects, RGN_COPY without data resets, SETMETARGN moves the clip into the meta region); they live in the DC state, so SAVEDC/RESTOREDC (relative and absolute) restore them along with pen, brush, font, colors, modes, transforms, window/viewport and current position; each drawing operation applies them inside its own gstate save/restore. Stock objects 0x80000000|n: brushes 0–5, 18; pens 6–8, 19; fonts 10–17 (fixed → Courier New, others → Arial).
- **EMF+:** GDICOMMENT records are skipped (EMF+ ones counted); dual files play their EMF part; files whose EMF part draws nothing but have EMF+ records draw nothing and report `isEMFPlusOnly` (6 of Chris' 59 EMFs, all in D5). Embedded PDF in EMR_COMMENT_MULTIFORMATS: see the embedded-PDF bullet below.
- **Metafiles in ImageDecoder/DrawingRenderer:** EMF/WMF are recognised by content (EMF record 1 + " EMF" at 40, WMF placeable key or standard header, gzip magic for EMZ/WMZ inflated with the Compression framework, ≤ 64 MB) whatever the extension; cache cost = records × 64 + file size + decoded bitmaps. `drawImage` maps the metafile frame onto the same crop-extended rect as a bitmap (srcRect/fillRect, geometry clip); alphaModFix composites the metafile in one transparency layer.
- **OLE compound probe (`OLECompound`, OOXMLKit, shared with WordKit):** minimal CFB parse — header (sector shift 9 or 12 only), FAT sector list from the header's 109 DIFAT entries plus the DIFAT sector chain, the directory chain via the FAT, UTF-16LE entry names (types storage/stream/root). Every read is bounds-checked; chains stop at 4096 sectors or the first repeated sector. `isEncryptedOOXML` = a directory entry named "EncryptionInfo" or "EncryptedPackage" (case-insensitive). If the directory cannot be parsed, it falls back to searching the first 4 MB for the UTF-16LE bytes of "EncryptionInfo" (a hit on garbage is harmless: the file is unreadable either way, only the error kind changes).
- **SlideDeck loading (Task 8):** `SlideDeck` is a Sendable struct holding the `OPCPackage` and internal `SlideRef {partPath, powerPointNumber}` for visible slides only (from `PresentationInfo.visibleSlides`, no re-parse). `init(url:)` is plain `throws` as in spec §5 but only throws `SlideKitError`. Extension check first, case-insensitive: pptx/pptm accepted; ppt and everything else (ppsx, potx, key, …) → `.unsupportedFormat` without touching the file. ZipError mapping: notAZip → `.notAZip`; oleCompound → `.encrypted` if `OLECompound.isEncryptedOOXML`, else `.unsupportedFormat`; truncated/corrupt/unreadable/other → `.malformed(reason)`; `PresentationInfoError` (no presentation part, unparseable presentation.xml) → `.malformed`. A deck with zero visible slides opens (slideCount 0). Opening reads the zip directory, presentation.xml and each slide's root (PresentationInfo parses the slide XML for `show`); corpus: 7 decks open in 68–410 ms (debug build), the 79 MB deck in ~410 ms.
- **MERGE POINT — `OCRWord` (done, slidekit-ref):** `wordBoxes(_:)` returns `[IndexKit.OCRWord]` (spec §5) now that `OCRWord {range: NSRange, box: CGRect}` is on main; the interim `SlideWord` (same shape) is removed rather than kept as a deprecated typealias (no caller outside SlideKit and its tests used it). IndexKit unchanged; SlideKitTests depends on IndexKit to name the type.
- **SlideDeck stubs:** `slideText` → "", `wordBoxes` → [], `draw` → nothing, `thumbnail` → nil until their tasks; an out-of-range index never traps and behaves like an empty slide.
- **Metafile hostile-input limits (Task 13 review):** uncompressed DIB pixel data must be complete (stride × height bytes), so decoded memory is proportional to the input; ≤ 40 M pixels per bitmap and ≤ 100 M decoded pixels per metafile (later bitmaps are skipped); BI_BITFIELDS channels are scaled in 64 bit (full-width masks). EMZ/WMZ inflate into min(ISIZE, compressed × 1100 + 1 KB, 64 MB). At most 2 M records are read per file. EMF CREATEPEN widths > 0 are geometric (logical units, round caps/joins), like WMF pens; width 0 stays cosmetic.
- **EMF embedded PDF:** a GDICOMMENT "GDIC" of type 0x40000004 (EMR_COMMENT_MULTIFORMATS: rclOutput in device units, nFormats, EmrFormat {signature, version, cbData, offData relative to the comment data}) whose format has signature 0x50444620 (what Office/Adobe write) or "%PDF" and data starting with "%PDF" is kept; page 1 (crop box) is stretched onto rclOutput, upright, inside the current clip. It is used only when the EMF part draws nothing (shapes inside a path bracket, e.g. a clip path, do not count): 30 of Chris' 59 EMFs carry such a PDF, 27 also have a full EMF rendering (used, so nothing draws twice), the 3 D4 EMFs have only a clip path — their PDF is an Illustrator file whose page content is empty (`/OC /MC0 BDC EMC`), so they still draw nothing, as in Office.
- **SlideKit model and caching (Task 9):** `SlideDeck` stays an immutable Sendable struct; init additionally creates one `DeckStore` (final class, shared by all copies) holding the package, one `ImageDecoder`, one `FontResolver` and one `DrawingRenderer`. Slide/layout/master parts (`SlideLayer`: root, spTree, bg, top-level placeholders, PartContext), themes and resolved `SlideModel`s are parsed lazily on first use and cached by part path behind one `Mutex`; parsing happens outside the lock, the first insert wins; missing/broken parts are cached as nil. Opening still reads only the zip directory and presentation.xml. `FontResolver` is created with theme nil because masters can have different themes: Task 10 substitutes +mj-lt/+mn-lt/… from the slide's `Theme` itself.
- **Part chain:** slide → first `…/slideLayout` rel (lowest Id) → its `…/slideMaster` → its `…/theme`. Rels are read from the .rels part, so a slide with unparseable XML still gets its layout/master background. No layout → the slide's own slideMaster rel, else the presentation's first master. No master → no inherited shapes, `Theme.fallback`, default clrMap. Missing theme → `Theme.fallback`. Nothing throws; a missing piece is skipped.
- **Colors:** effective map = `ColorMap(override: slide clrMapOvr) ?? ColorMap(override: layout clrMapOvr) ?? ColorMap(xml: master clrMap)`, applied to every layer drawn on the slide (master and layout shapes included) and to the background.
- **Background:** first of slide → layout → master with `p:bg`. `p:bgPr` → `FillResolver.explicitFill` with that layer's part; `p:bgRef idx` → theme bgFillStyleLst[idx−1001] (fillStyleLst[idx−1] for 1…999, 0 → none) with phClr = the bgRef's own color, blip fills resolved against the theme part. The slide is first filled white, then the background is drawn as a slide-sized rect shape (pictures stretch; tile is drawn stretched as elsewhere). An unresolvable background (missing image) leaves white.
- **showMasterSp:** master shapes are drawn when the layout's AND the slide's `showMasterSp` are not "0"; layout shapes when the slide's is not "0". Deviation from the brief's literal wording (master shapes depend on the layout only): PowerPoint's "Hide background graphics" on a slide hides master graphics too.
- **Placeholders:** type normalised: missing → `obj` (ECMA-376 ST_PlaceholderType default), ctrTitle → title, subTitle → body. Matching (slide → layout, and the matched layout placeholder — or the slide's own if none — → master): explicit idx equal AND types compatible, else equal type, else obj ↔ body. Compatible = equal, or one side `obj` and the other a content type (obj, body, chart, tbl, dgm, pic, media, clipArt). The compatibility check keeps a layout content placeholder idx 2 from matching the master's date placeholder idx 2. Master/layout placeholders are never drawn; dt/ftr/sldNum appear only through the slide's own placeholders. Inherited per property kind, nearest first (slide, layout, master): xfrm (first with off/ext), geometry, fill (blip fills resolved with the part that holds them), `a:ln` (whole element, not merged attribute by attribute), effectLst, `p:style`. Text is never inherited (layout text is prompt text); the chain's txBody nodes are kept for bodyPr/lstStyle (`ShapeText.inheritedTxBodies`).
- **Element model:** `SlideElement` = shape (sp, cxnSp) | picture | group(GroupModel without children, [SlideElement]) | graphicFrame(GraphicFrameModel: transform, graphicData, part, tag) — own enum instead of OOXMLKit's `DrawingElement` so groups can hold graphic frames; graphic frames draw nothing until Task 12. `p:contentPart` and unknown elements are ignored; `cNvPr hidden="1"` elements are skipped; `useBgFill="1"` shapes get the slide's background fill. Shapes with a txBody or a placeholder get `ShapeModel.tag` = index into `SlideModel.texts` (`ShapeText`); the text callback is a no-op in Task 9.
- **draw/thumbnail:** `draw(i, in:rect:)` takes a y-up context; the slide is aspect-fit and centred in `rect`, flipped to y-down inside save/restore and clipped to the slide. `thumbnail` renders into an sRGB premultipliedLast RGBA8 bitmap whose long side is maxPixel (clamped to 16384), short side rounded (≥ 1); the slide is stretched onto the whole bitmap (< 1 px aspect error, no transparent edge). Outer-shadow offsets assume base space = CTM space (true for bitmap/PDF contexts); PDFView tile contexts are checked in Task 12.
- **Text style cascade (Task 10):** per level 0–8, lowest priority first: base = presentation `p:defaultTextStyle` for non-placeholders, master `p:txStyles` for placeholders (titleStyle for title/ctrTitle; otherStyle for dt/ftr/sldNum/hdr/sldImg; bodyStyle for everything else incl. obj/subTitle/content types; defaultTextStyle is not used under placeholders — txStyles are the placeholders' complete base, review fix) → the shape's `p:style/a:fontRef` as a synthetic run default (color → solidFill, idx major/minor → latin +mj-lt/+mn-lt) → (placeholders only) master placeholder `a:lstStyle` → layout placeholder `a:lstStyle` → the shape's `a:lstStyle` → `a:pPr` → `a:rPr`. The fontRef sits above defaultTextStyle because real decks' defaultTextStyle always sets `solidFill tx1` and `latin +mn-lt` (all 7 corpus decks), which would otherwise hide e.g. white lt1 text in accent shapes. In each list style `a:defPPr` applies before `a:lvlNpPr`. Merge is attribute by attribute; child elements override per group (bullet kind buNone/buChar/buAutoNum/buBlip, buClr/buClrTx, buSz*, buFont/buFontTx, the fill choice, …); `a:defRPr` is the run default and merges the same way. Non-placeholders get defaultTextStyle only; theme `objectDefaults` (spDef/txDef) are not applied (PowerPoint writes them into new shapes; LibreOffice ignores them too — not verified against PowerPoint).
- **Text color/typeface fallback:** color: cascade fill (solid; noFill → transparent; gradient → first stop; fontRef included in the cascade) → tx1 through the clrMap. Typeface: cascade `a:latin` → minor. Theme shorthands (+mj-lt, +mn-lt, +mj-ea, +mn-ea) are resolved from the slide's theme in SlideKit (the store's FontResolver has no theme); +mj-cs/+mn-cs → Arial. Latin typeface only: `a:ea`/`a:cs` are ignored (Core Text's cascade covers CJK/complex glyphs). Hyperlink runs (`a:hlinkClick`) get the theme hlink color and an underline unless the link's extLst asks for `hlinkClr val="tx"`. `a:sym` maps private-use characters (U+F020–F0FF) through `FontResolver.mapSymbolText`; a latin symbol typeface (Wingdings, Symbol) maps the whole run and draws it in the default typeface.
- **rPr/pPr mapping:** sz 1/100 pt; u: any value but none → single, dbl/wavyDbl → double; strike sngStrike/dblStrike → strike; baseline 1/1000 %; cap small/all; spc 1/100 pt; highlight. algn l/ctr/r/just(+justLow)/dist(+thaiDist); marL/marR/indent EMU, indent clamped so marL + indent ≥ 0; spcBef/spcAft spcPts (1/100 pt) or spcPct (→ percent of the single line); lnSpc spcPct → multiple, spcPts → exact; tabLst, defTabSz, rtl. buSzPts becomes a percent of the first run's size. Picture bullets (`a:buBlip`) are square, first-run size × buSzPct, drawn with DrawingRenderer as a blip fill.
- **bodyPr:** attributes inherited one by one slide → layout → master placeholder; the autofit choice (normAutofit/spAutoFit/noAutofit) as a whole from the nearest. Insets default 91440/45720 EMU; anchor t/ctr/b (just/dist → top); anchorCtr centres the block of lines horizontally (single column only). wrap="none": set at an unbounded width left-aligned, then (ctr/r) set again at its natural width + 1 pt and placed by algn within the box. vert/eaVert/mongolianVert = text rotated 90° clockwise, vert270 = 90° counter-clockwise (box width and height swap; insets stay in shape orientation — a guess); wordArtVert(Rtl) drawn horizontally; `rot` adds to the rotation. normAutofit fontScale and lnSpcReduction are taken from the file as is; spAutoFit/noAutofit change nothing. numCol/spcCol: columns are supported (lines flow to the next column at the box bottom; anchor uses the tallest column). Text is never clipped; overflow goes past the box and a bottom anchor overflows upwards.
- **Paragraph stacking:** paragraphs stack with spaceAfter(previous) + spaceBefore(next); the first paragraph's spaceBefore is ignored (confirmed in slidekit-ref: 307 first lines whose paragraph has 1–18 pt spaceBefore sit within 1.9 pt of PowerPoint's baseline, median −0.09 pt; honouring it would move them down by the full amount). Line height base `.fontSize(factor: 1.2)`. Space given in points is not scaled by fontScale.
- **Group scaling and text:** a group whose chExt ≠ ext scales its children's boxes but not their text (PowerPoint). The group chain M is split into a scale S (hypot of its columns) and the rest R; the shape's offset/extent are scaled by S, the text is laid out in that effective box and drawn under R. Since Task 14 the shape itself is drawn the same way (scaled box under R, `GroupScale`), so `DrawingRenderer.drawGroup`'s text callback gets the scaled shape and its box in a context under R; nothing is mapped back with an inverse. Rotated shapes inside non-uniformly scaled groups are not skewed (approximation). Found on D4 slide 2 (text stretched 3× vertically).
- **Auto-numbering:** per text body, one counter per level. A numbered paragraph continues its level's count when scheme and startAt equal those of the previous numbered paragraph of that level, else starts at startAt. A non-numbered paragraph with text ends its level's list; any paragraph with text ends the lists of deeper levels (so 1., 2., a), 3.). Empty paragraphs show no number and change nothing. Modelled on PowerPoint's visible behaviour; edge cases not verified.
- **Fields:** `slidenum` → `SlideRef.powerPointNumber` (hidden slides before it count); the stored text ("<#>", "‹#›" or a stale number) is never shown. `datetime*` and any other type → the stored `a:t` text.
- **Empty placeholders:** a slide placeholder whose txBody has no run or field with text (or no txBody) and whose own spPr has no fill and no line with a fill draws nothing, inherited fill/line included (PowerPoint shows empty placeholders only in edit view). A slide `p:pic` placeholder without an embedded image draws nothing.
- **Placeholder matching slide → layout:** a slide placeholder with an explicit idx that the layout lacks matches by type (or obj ↔ body) only if its type is a singleton (title, ctrTitle, dt, ftr, sldNum, hdr) or the candidate has no idx, so a slide body idx 14 does not take the layout body idx 13. Layout → master matching is unchanged (lenient).
- **Laid-out text cache (Task 11 API):** `DeckStore.textLayout(SlideRef) -> SlideTextLayout`, cached per slide part (immutable, Sendable, first insert wins). `shapes: [ShapeTextLayout]` in draw order (master, layout, slide; groups depth-first), each with `layer`, `placeholder`, `paragraphs`, `sets`, `pieces` (paragraph, line range, origin in text space), `toShape`, `toCallback`, `toSlide`, and `slideWordRects()` → paragraph index, UTF-16 range in that SetParagraph's plainText, axis-aligned rect in slide points.
- **FontResolver (Task 10 fixes):** face names ending in a regular-weight word ("Avenir Book", "… Regular", "… Roman") use the installed family's plain face when that family is installed (before: "Book" classified Avenir Book as serif). Wingdings DF–E6 map to the arrows ←→↑↓↖↗↙↘ (glyph names barb2left … barb2se in the macOS Wingdings font).
- **Hostile text values:** numCol clamped as a Double before conversion (1…16); buAutoNum startAt clamped to 1…32767 (PowerPoint's range), the counter saturates; `lvl` clamped to 0…8 for styles and numbering.
- **slideText (Task 11):** raw text = the slide's own shapes in z-order (groups depth-first), built from the same laid-out `SetParagraph.plainText` that is drawn (`DeckStore.textLayout`), paragraphs joined with "\n", shapes with "\n\n", then `TextNormalizer.normalizeMapped`. Master/layout shapes are left out (a slide's own slidenum field shows its number); hidden shapes, empty placeholders (no text) and bullet/number glyphs contribute nothing. U+FFFC (inline object) is replaced by a space before normalizing (the normalizer keeps it as a symbol); tabs are control characters and become whitespace in the normalizer.
- **Original → normalized ranges:** IndexKit has no inverse of `originalRange(for:)` and is not changed. Per slide an inverse table is built once: for every normalized UTF-16 unit k, `originalRange(for: k..<k+1)` gives its source span (made non-decreasing). A word's normalized range is the smallest one whose units' spans intersect the word's original range (two binary searches, O(n + w log n) per slide); words the normalizer dropped entirely are left out. Hyphen-joined words (`Ver-\ntrag` → `Vertrag`) keep two boxes, "Ver" and "trag", each pointing at its part of the joined word.
- **wordBoxes:** rects from `ShapeTextLayout.slideWordRects()` (axis-aligned bounding box in slide points, rotation included) divided by the slide size, clamped to 0…1; a word with no area left on the slide is dropped (its text stays in slideText). A word broken across lines gives one entry per line, each with the normalized range of its own part (not the whole word's range), which is what that line draws.
- **Caching:** `DeckStore.slideText(_:slideSize:)` memoizes text + boxes per slide part (same Mutex memo, first insert wins), so indexing and highlighting share one computation.
- **Whitespace-only word ranges (Task 11 review):** a word whose normalized range consists only of collapsed spaces (e.g. made of private-use symbols or ZWSP between spaces) gets no box (nil range), like words the normalizer drops entirely.
- **Tables (Task 12a):** `a:tbl` in a `p:graphicFrame` → `GraphicFrameModel.table` (`TableModel`, built with the slide model), laid out with the slide's text (`SlideTextLayout.tables`, keyed by `TableModel.id`), drawn by `TableRenderer`. Position = the frame's `p:xfrm` offset; rotation, flips and the frame extent are ignored (PowerPoint does not rotate tables). Column widths = `gridCol w`; row height = max(`tr h`, every single-row cell's laid-out text height + marT + marB); a cell spanning rows grows the last spanned row by what is missing. Tables inside scaling groups scale with the group, text included (unlike shapes; rare).
- **Table merges:** the k-th `a:tc` of a row is grid column k. An anchor claims `gridSpan` × `rowSpan` slots (clamped to the grid): its first row up to the first claimed slot, then each further row only while all of that row's slots in its columns are free (it stops at the first row that is not), so anchors are rectangles of their own slots and never overlap; linear in the grid size. `hMerge`/`vMerge` cells inside it are continuation cells (no drawing, no text). Old-style merges: an `hMerge` cell outside any span extends its left neighbour only if that is a single-row anchor ending at it; a `vMerge` cell extends its upper neighbour only if that starts in its column, ends at the row above and the whole row of its width is free (claimed at once); otherwise the cell is dropped and the slot stays empty. Limits: 1000 columns, 1000 rows, 250 000 slots; lengths 0…1e6 pt; bad numbers → 0 / span 1.
- **Table cells:** margins `tcPr marL/marR/marT/marB` (defaults 91440/91440/45720/45720 EMU), anchor t/ctr/b (`vert`, `anchorCtr`, `horzOverflow` ignored); fill = `tcPr` fill (noFill included) → style → none; borders lnL/lnR/lnT/lnB/lnTlToBr/lnBlToTr override the style only when they contain a fill element (noFill = no line); no arrowheads. Each cell draws its own edges, so a shared edge is drawn by both neighbours (later on top). Order: table background (`tblPr` fill → style `tblBg`), cell fills, borders, text. Text is not clipped.
- **Table cell text:** non-placeholder cascade: presentation `defaultTextStyle` → the applicable table-style parts' `tcTxStyle` (b/i on/off, own color element else fontRef color, `a:font/a:latin` else fontRef major/minor) → cell `a:lstStyle` → pPr → rPr; set with the same ParagraphSetter/placement code as shapes (`TextBodyLayout.Builder.place`).
- **Table styles:** `ppt/tableStyles.xml` via the presentation's …/tableStyles relationship (cached per deck). Lookup: no `tableStyleId` → no style (ECMA's `def` is for new tables; the D1 tables with an empty `tblPr` style every cell explicitly) → deck style with the ID → built-in with the ID → built-in "Medium Style 2 – Accent 1" (slidekit-ref: the deck `def` step is gone, see the corpus bullet). Built-ins are XML literals parsed like deck styles: Medium Style 2 – Accent 1 {5C22544A-…}, Light Style 2 – Accent 1 {69012ECD-…} and Themed Style 2 – Accent 2 {18603FDC-…} (verbatim as PowerPoint writes them into decks, the latter two copied from D7's tableStyles.xml, Microsoft's built-in definitions), Light Style 2 {7E9639D4-…} (Light Style 2 – Accent 1 with tx1 for accent1, slidekit-ref), plus "No Style, No Grid" and "No Style, Table Grid" (Microsoft's built-in style IDs, see `TableStyles.swift`; from memory; added so these never turn blue). Part precedence (lowest first): wholeTbl < band1H/band2H (bandRow; rows other than header/footer, counted after the header) < band1V/band2V (bandCol) < lastCol < firstCol < lastRow < firstRow < nwCell/neCell/swCell/seCell (LibreOffice's order). Borders: an edge on the table's outside uses left/right/top/bottom, inside insideV/insideH, except that row parts own their top/bottom, column parts their left/right, corner cells all four; `a:ln` or `a:lnRef` (theme). Fill: `a:fill` or `a:fillRef` (theme).
- **Corpus table styles:** used IDs missing from their deck: D2 {18603FDC} (Themed Style 2 – Accent 2), D3 {69012ECD} ×3 (Light Style 2 – Accent 1, now built in), D5 {5C22544A} ×2 (def only, no definition → built-in), D7 {3C2FFA5D}, {7E9639D4}. Against PowerPoint's PDFs (slidekit-ref): {7E9639D4} is drawn with a tx1 (black) header and tx1 lines = "Light Style 2", now built in as Light Style 2 – Accent 1 with tx1 for accent1; {18603FDC} (Themed Style 2 – Accent 2) is now built in verbatim from D7's tableStyles.xml (D2's white body text); {3C2FFA5D} ("Themed Style 1 – Accent 1") shows an accent1 header and accent1-tinted, slightly graded body bands in PowerPoint — its definition is not known here, so it falls back to Medium Style 2 – Accent 1 (orange header and tinted bands, close) instead of the deck's def (Light Style 2 – Accent 6, a teal header PowerPoint never shows). The old "unknown ID → deck def" rule was wrong in both D7 cases; "no tableStyleId → no style" is confirmed (D1's tables with an empty `tblPr` show only their explicit cell formatting in PowerPoint). Built-ins now: Medium Style 2 – Accent 1, Light Style 2 – Accent 1, Light Style 2, Themed Style 2 – Accent 2 and the two "No Style" styles.
- **Table text (Task 12a):** from the laid-out cells (`SetParagraph.plainText`, symbol mapping and fields as drawn): anchor cells in row-major order, empty cells skipped, paragraphs/cells/rows joined with "\n", one block per table; word boxes from each cell's `slideWordRects()`. On the corpus the new text equals the old XML text for every table.
- **thumbnail (review fix):** `SlideDeck.thumbnailSize`: long side min(maxPixel, 16384); short side = (a / b) · long — the ratio first, since long · a overflows to infinity for sizes near CGFloat's maximum (cx = cy = 1.7e308 EMU) — rounded, clamped to 1…long before the Int conversion. Non-positive or non-finite slide sizes give nil (cx="0" never reaches it: PresentationInfo falls back to 720×540).
- **SmartArt (Task 12b):** drawn from the stored drawing (`dsp:drawing/dsp:spTree`) as a group at the frame's xfrm (child space = frame space 1:1), shapes and text through the same model builders and the slide's colors; blip r:ids resolve against the drawing part. A shape's `dsp:txXfrm` becomes an invisible text-only rect shape right after it (else the shape's own text rect). Drawing part lookup: the data part's `dsp:dataModelExt relId` decides when present (unresolvable → no drawing, so a SmartArt without a stored drawing never borrows another's), Without a dataModelExt, the slide's single diagramDrawing relationship is used as a fallback, or failing that the drawingN.xml numbered like dataN.xml, then the first diagramDrawing relationship. So in a rare file with two SmartArts and only one stored drawing, the one without an ext could reuse that drawing (accepted: PowerPoint always writes the ext when it stores a drawing). No drawing part → empty frame. Text goes into slideText/wordBoxes in shape order like any group.
- **mc:AlternateContent and VML (Task 12b):** slide, layout and master parts are parsed with `OOXMLNode.parse(_:preferringFallbackOver: [NS.v])`: a Choice requiring VML is taken only when there is no other supported Choice and no Fallback. The VML Choice of an OLE object has no image; its Fallback has the `p:pic`. Other parsers (Word) are unchanged.
- **OLE objects (Task 12b):** still image at the graphicFrame's xfrm (not the inner pic's dummy xfrm): `p:oleObj/p:pic` (also the Fallback's), else the legacy VML shape named by `spid` in the part's vmlDrawing (`v:imagedata o:relid`/`r:id`). No image → empty frame. The frame's own `hidden` decides visibility. All 11 corpus OLE frames are hidden think-cell objects (1588 EMU, hidden=1) and draw nothing, as in PowerPoint.
- **Charts (Task 12b):** plot = the first barChart/bar3DChart (2D), lineChart, pieChart/pie3DChart/doughnutChart of the plot area; further chart groups of the same family are kept with their own grouping and share one value axis (the corpus chart is two lineCharts on two deleted axes); any other type → empty frame (title included). Values from the caches/literals, missing/non-finite/|v| > 1e15 → gap; ≤ 4096 points, ≤ 255 series; pies skip values ≤ 0. Colours: series `c:spPr` solid fill (line charts: the `a:ln` fill first), else accent (c:idx mod 6) + 1; points (pie wedges and bars): `c:dPt` fill, else accent by point index when varyColors (default on for pies; bars only with a single series), else the series colour. Unnamed series: "Series1", "Series2" … (PowerPoint). Axes: those named by the first group's axIds; labels unless `delete`/tickLblPos none, gridlines only with `c:majorGridlines` (D9D9D9 0.75 pt), category axis line BFBFBF; nice-number ticks (1/2/5 × 10ⁿ, ~5 steps), c:scaling min/max honoured; bars/lines always include 0; horizontal bars put the first category at the bottom; gapWidth honoured, overlap ignored (clustered bars touch). Legend at r/l/t/b (tr and unknown → r), series names (pie: categories). Title: `c:title` rich text (or strRef); a title without text, or none with autoTitleDeleted=0, shows the single series' name. Text sizes from `c:txPr` (chart space, then element), else 10 pt; title without a size: 1.4 × base. Not drawn: data labels, markers, trendlines, secondary axes, 3D effects.
- **Chart text (Task 12b):** slideText gets one block per chart: title, category labels (only when drawn), legend entries, one paragraph each; value-axis numbers are drawn but not indexed. Word boxes for all of these (same set paragraphs as drawn). More than 100 categories: every k-th label.
- **Video/audio (Task 12b):** `p:pic` with `a:videoFile`/`p14:media` is an ordinary picture (Task 9); the blip is the poster frame, no blip → nothing. The "black rectangle" on D5 slide 53 (task-9 report) is that slide's video poster: `media/image101.png` is an all-black 1920×1080 frame in the file — correct, not a rendering bug.
- **SlidePDFPage (Task 12c):** `SlidePDFPage(deck:index:)`, a `PDFPage` subclass; every box = (0, 0, slideSize), unrotated whatever `rotation` is; `draw(with:to:)` = `deck.draw(i, in: ctx, rect: bounds)` without super (under `transform(_:for:)` when rotated, see the rotation bullet). `string` = `deck.slideText(i)` (normalized, as indexed; `normalizeMapped` of it is the identity, so highlight offsets stay valid). PDFKit's own text features (`selection(for:)`, find in PDFView) see no text on the live page: it has no PDF text layer; highlighting uses `wordBoxes`. `copy(with:)` returns another SlidePDFPage with the same slide and rotation (`label` is read-only, derived from the document).
- **PDFKit saves the subclass as vectors (Task 12c, early test):** yes. `PDFDocument.dataRepresentation()` and `write(to:)` call `draw(with:to:)` (box mediaBox, identity CTM, on the calling thread) into PDFKit's PDF context; a 2-slide fixture gave 20 704 bytes, reloaded page text "Quartalsbericht Wärmepumpe" / "Zweite Folie Ausblick", media box 960×540, edges sharp at 4×, 2 fonts embedded. So no `SlidePages.makePage`; the merger inserts SlidePDFPages directly. Colours exact, except inside a shadow's transparency layer: CG's PDF form of it turns sRGB FF0000 into FF2500 on reload (plain fills are exact).
- **PDFKit drawing paths (Task 12c):** `PDFPage.thumbnail(of:for:)` ignores subclasses (all white), so SlidePDFPage overrides it: own sRGB bitmap at 2 px/pt, slide aspect-fit on white. PDFView calls `draw(with:to:)` for cropBox on a **background thread** (CTM uniform scale + 1 px translation, not a bitmap context); the deck is Sendable, the page's stored properties are immutable, so that is safe. SlidePDFPage itself is not Sendable: confine instances to their PDFDocument/PDFView like any PDFPage.
- **Shadow base space (Task 12c):** in a lazy `NSImage(size:flipped:drawingHandler:)` context (2× rep, CTM 2) DrawingRenderer's shadows land 2× too far (base CTM ≠ identity there) and colours shift (display colour space) — hence the bitmap thumbnail above. Bitmap and PDF contexts are correct (deck thumbnails, saved PDFs, SlidePDFPage via `thumbnail`). PDFView tiles could not be read back headless (no bitmap data, layer render empty); their CTM looks like the NSImage case, so on Retina shadows in the live PDFView may be up to 2× offset. Not fixed (≤ 2×, cosmetic); a fix would derive the base scale from the context (e.g. `userSpaceToDeviceSpaceTransform` vs. a known scale) in DrawingRenderer.
- **SlidePDFPage rotation (final review):** probed with a PDFPage subclass rotated by 90: PDFKit does not rotate the context before calling `draw(with:to:)` — PDFView's tiles and printing (`printOperation`, saved to PDF) pass page space without rotation and rely on the page to apply it, as `PDFPage`'s own `draw(with:to:)` does ("takes into account page rotation"); `bounds(for:)` stays unrotated for every page. Saving (`dataRepresentation`) calls `draw(with:to:)` with an identity CTM and writes /Rotate 90; the recorded content came out unrotated whether or not the subclass applied `transform(_:for:)` (PDFKit neutralises it there). So SlidePDFPage applies `transform(_:for:)` when `rotation` ≠ 0: live drawing and printing are rotated, a saved page is the unrotated slide with /Rotate (PDFKit's drawing of the reloaded page equals ours, `rotatedPageDrawsRotatedLikeAnOrdinaryPage`), the thumbnail override draws the rotated slide aspect-fit. Rotation 0 keeps the old path unchanged. Not verified pixel-exact in a live PDFView (tile CTM checked only).
- **Group scaling never stretches children (Task 14):** a group chain M (chExt ≠ ext, nested groups multiplied) is split into a per-axis scale S (hypot of its columns) and the rest R (`OOXMLKit.GroupScale`); every child is drawn with its box scaled by S under R, in `DrawingRenderer.drawGroup` (shared with WordKit) and SlideKit's renderer alike. So line widths, arrowheads, preset geometry (corner radii, adjust values) and text keep their absolute sizes, as in PowerPoint. Before, children were drawn under M and a 3 pt line in a group with 820-EMU child units (old decks) became a ~1000 pt band (D3 slide 29 covered in yellow/black). Box scaling: centre × S; extent × S in the box's visual orientation, i.e. sx/sy swapped for rotations 45°…135° (mod 180°), so an upright box keeps its visual shape (D1 slide 16). The text callback of `DrawingRenderer.drawGroup` now gets the scaled shape and box (text no longer stretched: behaviour change for WordKit groups with chExt ≠ ext). Graphic frames (tables, charts) inside groups are still drawn under M (rare). Rotations inside non-uniformly scaled groups are not skewed (approximation).
- **Zero-axis group scale (final review):** `GroupScale` accepts a chain that collapses an axis (ext cy = 0 with chExt cy > 0, e.g. a group of horizontal lines saved flat): S has the 0, R's unit column for that axis is the other column turned by 90° (identity columns when both are 0), so R stays orthonormal and finite (no NaN) and the children are drawn with a flat box — lines still show. Only non-finite chains give nil (nothing drawn). Before, such a group drew nothing.
- **Wingdings white arrows (Task 14):** EF…F4 → ⇦ ⇨ ⇧ ⇩ ⬄ ⇳ (glyph names bleft, bright, bup, bdown, bleftright, bupdown in the macOS Wingdings font); F3 was the only unmapped symbol code in the corpus (a "⇔" in D1, drawn as a missing-glyph box before). A corpus scan found no other unmapped Wingdings/Wingdings 2/3 codes.
- **Size-aware image decoding (Task 14):** `ImageDecoder.image(_:maxPixel:)` / `image(part:maxPixel:)` (new, additive; `image(_:)` / `image(part:)` unchanged, full resolution ≤ 8192 px) decode a bitmap only as large as needed: the long side rounded up to a power of two (64…8192, via `CGImageSourceCreateThumbnailAtIndex`); at or above the native size the full image (same object) is returned. `image(_:pixelSize:)` / `image(part:pixelSize:)` (final review) take the drawn size per axis: for a native w × h the long side is max(W / w, H / h) · max(w, h), so a picture stretched to another aspect ratio gets enough pixels on its short axis (a 4000×200 image in a 300×300 pt box at 1× was decoded at 512×26 and drawn 300 px tall, blurred); the native size is read from the image header once per part and cached. `DrawingRenderer` asks for the device pixels per axis (CTM column lengths × the crop-extended image rect, so a crop raises the need by 1/(1−l−r) and 1/(1−t−b)), for pictures and blip fills alike, but only in bitmap contexts (`ctx.width > 0`); PDF/printing/other contexts keep the full image, so saved slides lose no resolution. The cache keys (part, bucket) and evicts least-recently-used entries beyond 512 MB instead of emptying itself (an entry larger than the limit is returned, not kept). Measured (release): warm 256 px thumbnails max 61 → 4 ms on D5, 19 → 2 ms on D3; cold times barely change (dominated by parsing and first draw); renders visually identical (≤ 1.5 % pixels differ by resampling).
- **Quick Look comparison (Task 14):** 227 of 233 visible slides complete in content (97.4 %; 226 before the Task 14 fixes), per-slide list in `docs/slidekit-vergleich.md` (decks only as D1–D7; label mapping and contact sheets stay in `~/Developer/PDFSucher-spikes/slidekit-vergleich/`). The 6 incomplete slides are all D5 slides whose icons are EMF+-only metafiles (no EMF+ player, out of scope). Quick Look was treated as a rough reference only; disagreements were decided against the slide XML. `CorpusTests` (PDFSUCHER_PPTX_CORPUS) writes the sheets; `SlideKitBenchmark` (plus PDFSUCHER_BENCH=1, release) the timings in `docs/performance.md`.
- **Line break size (slidekit-ref, measured):** PowerPoint does not let a `a:br`'s own font size grow the line the break ends (D1: a 20 pt line ended by a 36 pt break has a 21.1 pt baseline pitch at lnSpc 90 % in the PDF; the old rule gave 35.5 pt). `ParagraphSetter(lineBreakSetsLineHeight: false)` (SlideKit) drops break-only runs from a line's metrics when the line holds anything else; a line that is only a break keeps the break's size (not measured, no corpus case). Default `true` (WordKit unchanged). The empty line after a trailing break keeps `endParaRPr` (measured: D1 title block within 0.6 pt).
- **First line above 100 % spacing (slidekit-ref, measured):** PowerPoint puts the text body's first baseline at max(0.75 × the line height, single − descent) below the text top (single = 1.2 × the size of the first run with text × fontScale), not at height − descent; the following lines keep their pitch and the block is shorter by the difference (matters for ctr/b anchors). The rule only bites above single spacing (lnSpc above ~105 %, exact spacing above the single height) and is monotonic in the spacing (review fix: the first version used 0.75 × height for every lnSpc > 100 %, which put 100–110 % higher than 100 % and made exact spacing jump at the single height). Measured on top-anchored first lines (baseline − text top, in units of the font size; PDF positions are quantized to 0.96 pt): 110 % 0.999 (rule 0.99), 120 % 1.079 (13 lines, rule 1.08), 130 % 1.202 (1.17), 150 % 1.337 (9 lines, rule 1.35); before the fix SlideKit was 1.5–4.7 pt low. At ≤ 100 % the old rule (height − descent) is right: 100 % 0.996 (378 lines, rule 0.988), 90 % 0.855 (315 lines), 80 % 0.744. Only the body's first line: paragraph gaps at 120 %/150 % match SlideKit (median −0.11/0.00 pt). Open: one D5 body where a 125 % paragraph follows a 100 % one sits 2 pt high in PowerPoint (not modelled), and bottom-anchored 150 % titles (D1, 2 shapes) stay 4.5 pt low.
- **Superscript/subscript size (slidekit-ref, measured):** `rPr baseline` ≠ 0 → the run is set at 2/3 of its size and shifted by baseline % of the full size (`baselineShift` × 1.5 on the reduced size). D7: a 28 pt title's `baseline="30000"` digit is a 18.67 pt glyph in the PDF (written as Tf 19, PowerPoint's PDF rounds glyph sizes to whole points) raised 7.9 pt (30 % of 28 = 8.4, 0.96 pt quantization); before, SlideKit drew it at 28 pt, which also made the title line taller. The setter's own rule (size not reduced) stays for WordKit.
- **Picture recolouring (slidekit-ref):** `a:blip` duotone, grayscl, clrChange, biLevel and lum are applied to the decoded bitmap in document order (`OOXMLKit.BlipEffect`, `ImageRef.effects`, cached in ImageDecoder per part, decoded size and effects; metafiles with effects are rasterized at device resolution — bitmap contexts; 2 px/pt elsewhere, ≤ 4096 px a side — then recoloured; D2's duotoned EMF pin). PowerPoint's PDFs show them (D2: a magnifier, cloud and pin icons duotoned; the corpus has 47 duotone, 17 clrChange, 10 grayscl, 7 biLevel, 58 lum uses in D1–D3, D6, D7); SlideKit drew the originals. Formulas are not in the spec: luminance = BT.601 luma of sRGB; duotone = first colour + (second − first) × luminance; clrChange matches within 2.5/255 per channel (rounding of 8-bit sources) and takes clrTo with its alpha (`useA` is ignored: the alpha of the source pixel never takes part in the match); biLevel white at luminance ≥ thresh; lum contrast c as (v − ½)·k + ½ (k = 1/(1 − c) for c > 0, 1 + c otherwise) then + bright. Checked visually on the D2 sheets, not measured per pixel. `a14:imgProps` artistic effects (saturation, colour temperature) are ignored. Because the effects live on `ImageRef` (built by `PictureModel` and `FillResolver`), WordKit pictures and blip fills get them too (intended: same DrawingML).
- **Font metrics do not grow PowerPoint lines (slidekit-ref, measured):** SlideKit sets `ParagraphSetter(fontMetricsGrowLines: false)`: natural = single (1.2 × size) even when the font's ascent + descent is larger (default true keeps max(single, ascent + descent) for WordKit). Evidence: every corpus line pair where the old rule exceeded 1.2 × size × factor (9 pairs in D1/D3, e.g. Avenir 16 pt at 100 %: old 21.9 pt, PowerPoint 19.9 pt; Avenir 20 pt at 110 %: old 28.2, PowerPoint 25.9–27.1, rule 26.4) follows the 1.2 rule within the 0.96 pt quantization. The first-line rule above also covers exact spacing above 1.2 × the first run's size (D1: 36 pt spacing with 20 pt text → baseline 26.9 pt below the top, rule 27; 30 pt with 16 pt → ~23.0, rule 22.5).
- **Picture outlines outside (slidekit-ref, measured):** PowerPoint draws a `p:pic` outline entirely outside the picture's geometry (D1 and D2 screenshots with a 6 pt frame: in the PDF the frame covers the 6 pt outside the picture edge and the image starts at the edge; SlideKit's centred line covered 3 pt of the image and stood 3 pt less far out). `DrawingRenderer.drawPicture(_:in:lineOutside:)` (SlideKit: true; default false for WordKit) strokes at twice the width clipped to the outside (even-odd against the geometry; dash lengths kept). Shape lines stay centred.
- **PowerPoint reference (slidekit-ref):** Chris' 7 decks exported to PDF by PowerPoint (Mac) are the ground truth; `SlideKitTests.PowerPointReferenceTests` scores every visible slide against its PDF page at 1600 px and `TextLineMeasurements` reads PowerPoint's baselines and font sizes from the PDF content stream (CGPDFScanner: q/Q/cm, BT/Tm/Td/TD/T*/TL/Tf, form XObjects) next to SlideKit's laid-out lines. The exports hold only visible slides (D1, D2, D5, D7 each hide one), so page i = visible slide i. Results in docs/slidekit-vergleich.md (PowerPoint section). Verdicts on the earlier guesses: line height 1.2, first spaceBefore ignored, arrowhead floor, tint/shade in linear RGB, "no tableStyleId → no style" and the bullet gap are confirmed (see their bullets); wrong and fixed: a break's size counted for its line, font ascent + descent grew lines, the first line above 100 %/exact spacing, superscript size, unknown table style IDs → deck def, picture outlines centred, picture recolour effects ignored. Table part precedence and shared-edge borders could not be isolated (no corpus table with conflicting parts); the D2/D3 Medium Style 2 and Light Style 2 – Accent 1 tables match PowerPoint pixel for pixel in fills and lines (coarse score ≤ 0.3 %), which is consistent with both rules.
- **What PowerPoint does with missing fonts (slidekit-ref):** the earlier observation ("everything missing → Arial") was read from the embedded-font list only and is superseded by the measured rule in "FontSubstitution" below. PowerPoint's PDF also writes glyph sizes rounded to whole points (Tf 19 for 18.67 pt) while the layout (pitch, wrapping) uses the exact size.
- **FontSubstitution (measured PowerPoint rule, slidekit-arial):** matched every run with an explicit `a:latin` typeface (≥ 5 chars) in D1–D7 to the font PowerPoint's PDF draws its text in (PDFKit attributed page text, CGPDF `Tf` scan per page). Missing fonts (D1's corporate faces, D7's HP Simplified, D5's Google Sans / `-webkit-standard`, ~110 runs) are drawn in **Calibri**, not Arial: regular, bold/italic from the run (Calibri-Bold, Calibri-Italic), no weight from the name ("… ExtraBold", "… Headline Ultra" → regular Calibri), panose/pitchFamily ignored (pitchFamily 2, 34 and none alike). The Arial in the PDFs comes from the decks' Arial theme fonts and explicit Arial, not from substitution. Installed families and faces stay (Avenir Book/Heavy, Helvetica Neue Medium → HelveticaNeue-Medium, Arial Black, Verdana, Calibri, Courier New); Office's own fonts are drawn in their own face (Lato, Lato Black, Aptos, Open Sans, Candara; "Lato Medium", which Office's Lato lacks, → Lato Regular). The corpus has no missing serif or mono run; since PowerPoint ignores panose and pitch, serif/mono names are assumed to go to Calibri as well (unverified). Theme shorthands resolve first, then the same rule.
- **FontSubstitution policy:** `public enum FontSubstitution: String { case powerPoint, similar }`, `FontResolver(theme:substitution:)`, default **`.powerPoint`** (also for WordKit and the metafile player, which use the default: Word thread to re-check its look; EMF/WMF text inside a deck opened with `.similar` still uses `.powerPoint`, accepted). `.powerPoint`, Latin runs: installed family / face as before; a missing name PowerPoint draws in its own face keeps the look-alike mapping: `FontResolver.officeFonts` (what Office for Mac ships in Microsoft PowerPoint.app/Contents/Resources/DFonts — Garamond, Book Antiqua, Century Gothic, Franklin Gothic, Gill Sans MT, Rockwell, … —, the Windows/Office core faces, Lato and Open Sans), CJK names, symbol fonts; every other missing name → Calibri (Arial if Calibri is not installed), no weight/width words applied. Corporate names that the look-alike table lists (HP Simplified, TeleGrotesk, TeleNeo) are not "own faces": PowerPoint draws them in Calibri (D7, D1). East Asian and complex-script runs keep the table (the measurement covers Latin runs only). `.similar` = the look-alike table. The Core Text serial-queue workaround is untouched.
- **CJK names (review fix, slidekit-arial, both modes):** only explicit East Asian names (ＭＳ ゴシック, MS (P)Gothic, Yu Gothic, Meiryo, Hiragino, Malgun, Gulim, SimHei, YaHei, JhengHei, DengXian, mincho/明朝, SimSun, MingLiU, Batang, …) or CJK characters count as CJK. Before, any name containing "gothic" went to Hiragino Sans, so Latin faces such as Trade Gothic or News Gothic were drawn in a Japanese font. The corpus has none of them: its scores under `.similar` are unchanged.
- **Measured result (slidekit-arial):** near-identical slides 129 → 146 of 233, coarse mean 3.07 → 2.82 % (`.similar` → `.powerPoint`; per deck in docs/slidekit-vergleich.md). **Decision: PowerPoint substitutes missing fonts with Calibri; SlideKit follows it by default (`.powerPoint`), `.similar` stays selectable.**
- **No standard ligatures (slidekit-ligatures):** `ParagraphSetter` (runs and bullets) and the metafile player set `kCTLigatureAttributeName` = 0 (`ParagraphSetter.noLigatures`, only required ligatures). Found by the SlideKit adapter's merge test: a PDF that PDFKit saves from a `SlidePDFPage` gave Calibri's "tt" ligature no text of its own ("Dritte" read back as "Dri$e" or "Dri/e", depending on the page order), so search in merged or printed-to-PDF slides missed such words. Office draws without standard ligatures by default (and GDI for metafiles never), so this is also closer to PowerPoint: reference scores `.powerPoint` 146 → 147 near-identical of 233, coarse mean unchanged at 2.82 % (D7 5.44 → 5.40 %). Regression test `SlidePDFPageTests.savedDocumentKeepsWordsWithLigatureCandidates` (Calibri, 12–44 pt). WordKit, once it draws through ParagraphSetter, gets the same (Word's default is no ligatures as well). The test is skipped where Calibri is not installed (e.g. a Mac without Office).
- **Office's own fonts (slidekit-officefonts, Chris' decision 2026-11-13: "use them when present"):** `OfficeFonts` (OOXMLKit) registers the fonts Microsoft Office for Mac brings along — `<Office app>.app/Contents/Resources/DFonts` (PowerPoint, Word, Excel, Outlook, OneNote; identical copies) and Office's cloud font cache `~/Library/Group Containers/UBF8T346G9.Office/FontCache/<n>/CloudFonts` (Lato, Open Sans, Segoe UI, Aptos Display, …; `PreviewFont` menu previews left out) — with `CTFontManagerRegisterFontsForURL(.process)`: read in place, never copied, installed or changed, gone when the app quits. Once per process, lazily, on FontResolver's font queue right before it first lists the installed families; a file whose PostScript names are all available already is skipped (system-wide Arial, Calibri, … stay the ones used; the three DFonts copies count once). On this Mac: 862 files, 264 registered, 157 new families, ~250 ms once. Without Office nothing changes. `PDFSUCHER_NO_OFFICE_FONTS=1` turns it off (measurements); `FontResolver.registerFonts(in:)` registers other folders the same way (tests use a renamed macOS font, no Office needed). Fonts a resolver created before a registration stay cached in it. Both modes see the fonts as installed, so substitution no longer applies to them.
- **Regular face for a bare family name (slidekit-officefonts):** Office's cloud "Aptos Display" is family "Aptos", style "Display"; Core Text picked it for runs naming "Aptos". `FontResolver.makeFont` now keeps Core Text's face only when its style is a regular one (Regular, Roman, Book, Normal, Plain); otherwise it takes the family's face with such a style (upright, weight and width closest to 0), if there is one. Measured: no change without Office fonts (system families already resolve to a regular style).
- **Office fonts, review fixes (slidekit-officefonts):** (1) A name that is a face's full or PostScript name ("Aptos Display" = family Aptos, style Display, the heading font of the current Office theme; "Avenir Book", "Lato Light") resolves to exactly that face (memoized per name, `kCTFontNameAttribute`); checked on this Mac: Aptos Display → AptosDisplay, Lato Light → Lato-Light, Avenir Book → Avenir-Book, Helvetica Neue Medium → HelveticaNeue-Medium. (2) A font file is registered only when none of its PostScript names exists yet (a collection overlapping system fonts is left out whole, nothing is shadowed). (3) Office apps are looked for in /Applications and ~/Applications (1.3.1: only /Applications, see below). (4) The regular-face lookup is memoized per family; both memos are emptied by `registerFonts(in:)`. (5) Setting `office.officeFonts` (`OfficeFontUse`: all / bundled / off, default **all** per Chris' decision; `OfficeRenderSettings.officeFontsKey`), read once at the lazy registration, so a change applies at the next start. (6) The fonts are registered for the whole process: PDFKit (PDFs with non-embedded fonts), metafiles and any font UI see them too, not only SlideKit; text extraction of such PDFs can change accordingly.
- **Office's cloud font cache and the macOS access prompt — decided (Chris, 2026-11-13: "Alle Office-Schriften"):** `office.officeFonts` stays **all** by default (DFonts and the cloud font cache in `~/Library/Group Containers/UBF8T346G9.Office`). Reading another vendor's group container may make macOS 15+ ask "PDFSucher would like to access data from other apps"; so that the question comes at launch rather than when the first deck opens, the app registers the fonts in the background at launch: `FontResolver.prewarm()` (OOXMLKit) or `SlideDeck.prewarmFonts()` (SlideKit), both `public static func … ()`, blocking, idempotent and thread-safe, called once off the main thread and off Swift's concurrency pool (`DispatchQueue.global(qos: .utility).async { SlideDeck.prewarmFonts() }`; `Task.detached` would hold a pool thread for as long as the prompt is open). All font work runs on one serial queue, so a deck opened while the prompt is still pending waits for the answer; prewarm moves the prompt earlier, it does not take it off that path. The lazy registration on first font use stays as the fallback. Whether the prompt really appears is checked by the app thread with the signed 1.3.0 build.
- **Measured (Office fonts, slidekit-officefonts):** `.powerPoint` near-identical 147 → 169 of 233, coarse mean 2.82 → 2.09 % (D5 17 → 39 slides, 4.51 → 1.91 %; D3 1.44 → 1.42 %; others unchanged); `.similar` 129 → 152, 3.07 → 2.35 %. Details in docs/slidekit-vergleich.md.
- **Font embedding in our PDF output — decided (Chris, 2026-11-13: "Ja, wie bisher"):** PDFs that PDFSucher writes from slides (merge, print to PDF; PDFKit `dataRepresentation` of a `SlidePDFPage`) embed subsets of the fonts used (checked: `Lato-Regular` and `AptosDisplay` as /FontFile2 subsets). Office font subsets may be embedded like any system font; nothing changes in output.
- **SlideKit option:** `SlideDeck(url:fontSubstitution: = .powerPoint)` passes it to the deck's own FontResolver; every deck has its own DeckStore (layouts, text, images), so two decks of one file with different options never share caches. Text layout, rendering and wordBoxes depend on it: callers re-render and re-index when the setting changes. Meant for an app setting.
- **Office settings keys (SlideKit `OfficeRenderSettings`):** main had no Office settings module, so the keys live in SlideKit: `office.fontSubstitution` ("powerPoint"/"similar", default powerPoint) and `office.powerPointRenderer` (`PowerPointRenderer` "slideKit"/"quickLook"). Default renderer **SlideKit, Quick Look stays selectable: Chris' decision (2026-11-13)**. Missing/unknown values → default. No UI here (app integration thread).

## 2026-11-13 — 1.2.4 Nachtrag: unzuverlässiger Test `changedFileReplacesItsTiles`

- **Ursache**, ermittelt mit Zählern in der Schreibwarteschlange: Im Fehlerfall gab es `staleDrops: 1` und `pending 0`. Die Vermutung „`flush` wartet nicht“ trifft also nicht zu.
  - Die `source`-Datei speicherte das Änderungsdatum in Sekunden seit 1970. `Date` rechnet aber intern in Sekunden seit 2001.
  - Beim Zurücklesen konnte das Datum dadurch um eine Rundungsstelle *später* sein als das der Datei.
  - Die Regel „ältere Version ersetzt keine neuere“ (Review M7) verglich exakt und verwarf so eine Kachel derselben Version.
  - Ob das passiert, hängt von den Nanosekunden des Dateidatums ab. Deshalb trat der Fehler nur manchmal auf, und nur unter Last, wenn viele Tests parallel laufen.
- **Behebung:**
  - Das Datum wird jetzt als `timeIntervalSinceReferenceDate` gespeichert und kommt damit exakt zurück.
  - „Älter“ gilt erst ab 1 ms Abstand, mit derselben Toleranz wie `matches`.
- **Tests:**
  - Der Test `roundTripNeverLooksOlder` mit 20.000 zufälligen Daten war vorher rot und ist jetzt grün.
  - `changedFileReplacesItsTiles` lief danach 20-mal hintereinander im vollen ViewerUI-Testziel grün.
  - Die Zähler (`TileDiskCache.counters`) bleiben für die Diagnose. Die Fehlermeldung des Tests zeigt sie zusammen mit dem Inhalt der Platte.
- **Warnungen:** Die 18 Warnungen in den Testdateien sind behoben: unnötiges `await` an synchronen Zählern und `SearchTextField.trailingInset` jetzt `nonisolated`.
- **Gemeldet, nicht geändert:** `BrowseViewTests.stepIsFastWithTenThousandFiles` (500-ms-Grenze im Debug-Build) schlug in 2 von etwa 30 vollen Läufen unter Last fehl. Der Test stammt nicht aus 1.2.4.
- **`stepIsFastWithTenThousandFiles` (Nachtrag):** gemessen, nicht geraten.
  - Isoliert brauchen 200 Schritte ‹ › über 10.000 Dateien stabil etwa 295 ms, also 1,5 ms pro Tastendruck. Der Code ist linear in der Zahl der Zeilen, für Menschen-Tempo aber unkritisch.
  - Unter der Last des parallelen Testlaufs war der erste Durchlauf 330–620 ms langsam, die folgenden blieben bei etwa 305 ms.
  - Die Ausreißer kommen also aus Aufwärmen und Last. Der Test vergleicht jetzt den besten von 5 Durchläufen mit unveränderter Grenze von 500 ms. Er lief unter Last 10 von 10 grün.
  - Kosten, falls das falsch ist: Eine echte Verlangsamung um weniger als das 1,7-Fache fiele nicht auf.

## 2026-11-13 — Ordnerleiste (folder-tree, kommt mit 1.3.0)

- **Modell:**
  - Der Baum entsteht aus den Dokumentlisten aller Quellen. Sie werden unabhängig von der Suche im Hintergrund gelesen (`refreshFolderTree`): nach dem Hinzufügen und Entfernen von Quellen sowie nach dem Indexieren. Das Dateisystem liest die App dafür nicht.
  - Gezeigt werden nur Ordner mit Dateien, bis Tiefe 10. Tiefere Dateien zählen beim Ordner auf Ebene 10.
- **Filter:**
  - `hits` ist das Ergebnis nach dem Ordnerfilter und `extraFilters`, die mit UND verknüpft sind. Ein Dateityp-Filter des Office-Threads kommt als weiterer `DocumentFilter` dazu.
  - Eine neue Sortierung sortiert die ungefilterte Liste, damit ein späterer Filterwechsel die Reihenfolge behält (Review I1).
  - Häkchen außerhalb des Filters bleiben gesetzt, wie bei einer Suche.
- **Auswahl:**
  - Ein Klick auf einen Ordner filtert sofort, mit ⌘-Klick werden es mehrere.
  - Auch die Pfeiltasten im Baum filtern sofort, wie die Seitenleiste im Finder; das kostet unter 100 ms. Die Spec sah dafür Return vor; Return wählt den Filter jetzt ebenfalls, ohne Unterschied.
  - „Alle Quellen“ und Ordner schließen sich gegenseitig aus. ⌘-Klick aus „Alle Quellen“ heraus wählt den Ordner (Review I5).
  - Wird die Leiste wieder eingeblendet, zeigt sie den aktiven Filter (Review I6).
- **Orte:**
  - Orte gehören nicht zur Listenauswahl. Nur ein Mausklick öffnet einen Ort, die Pfeiltasten fügen also nie eine Quelle hinzu (Review I3/I4).
  - Das Hinzufügen läuft in derselben Warteschlange wie Drop und ⌘O. Ein Ort, der nicht geladen werden konnte, hinterlässt keinen wartenden Filter (Review I7).
  - Die Liste wird nur bei Mount und Unmount neu gelesen.
- **Tastatur:**
  - Tab im Baum führt in die Vorschau.
  - Die Pfeiltasten bleiben im Baum: Die Liste ist ein AppKit-Steuerelement (Regel aus 1.2.4).
  - Buchstaben gehen ins Suchfeld.
- **Nachgezogen:**
  - Bei aktiver Suche zeigt die Kopfzeile „(3 von 37 Dateien)“.
  - „Einzelne Dateien“ als Filter umfasst auch später hinzugefügte Einzeldateien.
- **Zurückgestellt:**
  - Tab aus dem Raster führt nicht zurück in den Baum. Das bräuchte eine eigene Fokusart für eine AppKit-Liste.
  - Die Unterordner eines Ortes werden einmal gelesen und dann nicht mehr aktualisiert.

## 2026-11-13 — Ordner beobachten (folder-tree)

- **Befund:** Im Probelauf blieben Ordner, die im Finder umbenannt oder gelöscht wurden, im Baum stehen, auch nach dem Aktivieren der App.
- **Entscheidung:** Ein FSEvents-Strom über alle Ordnerquellen (`FSEventsFolderWatcher`). Eine Änderung stellt die betroffene Quelle wieder in die Index-Warteschlange (inkrementell). Wenn der Lauf fertig ist, wird der Baum neu gebaut. Ein Neu-Indexieren beim Aktivieren gibt es nicht.
- **Begründung:**
  - FSEvents kostet im Ruhezustand nichts: Der Kernel meldet, die App fragt nicht ab. Der Baum folgt auch, während die App vorn ist, etwa wenn ein Download fertig wird.
  - Ein Durchlauf bei jeder Aktivierung würde bei jedem ⌘Tab alle Quellen neu einlesen und eine laufende Texterkennung unterbrechen. Bei einem Home-Ordner als Quelle sind das Sekunden.
  - Gemessen im Probelauf: Der Baum zeigte die Umbenennung etwa 1,6 s danach (1,5 s FSEvents-Latenz plus 50 ms Indexlauf für 70 Dateien).
- **Filter (wie `FolderScanner`, nach Review nachgeschärft):**
  - Gemeldet werden nur Ordner und unterstützte Dateien bis Tiefe 10. Bilder zählen nur bei „Bilder einbeziehen“ (`accepts(…, includeImages:)`).
  - Nichts unter Punkt-Ordnern, versteckten Ordnern oder Paketen zählt. Pakete werden über den Typ (`.app`, `.photoslibrary`) und über die Platte erkannt. `~/Library` und die Mediathek von Fotos ändern sich in einer Home-Quelle ständig.
  - Es zählen nur Anlegen, Löschen, Umbenennen und Ändern. xattr-, Rechte-, Finder-Info- und Besitzer-Änderungen zählen nicht. „In Vorschau öffnen“ schreibt `com.apple.lastuseddate#PS`, ein Download sein Quarantäne-Flag; sonst würde die App sich mit ihrer eigenen Aktion neu indexieren.
  - Verlorene Ereignisse (`MustScanSubDirs`, Kernel/Dienst verworfen) und eine geänderte Wurzel zählen immer als Änderung.
  - FSEvents nennt den aufgelösten Pfad (`/private/var/…`), die App den standardisierten (`/var/…`). Der Filter vergleicht mit `realpath`, gemeldet wird die Quelle so, wie die App sie führt.
- **Rate:**
  - Nach dem Ende eines Laufs, den eine Änderung ausgelöst hat, wartet eine Quelle 10 s. Gezählt wird ab dem Ende, damit ein Lauf, der länger dauert als die Sperre, nicht sofort den nächsten nach sich zieht (Nach-Review).
  - Meldungen während dieser Zeit, während des eigenen Laufs oder in der Warteschlange ergeben genau einen Nachlauf.
  - Ein langer Kopiervorgang nach Downloads unterbricht die Texterkennung so höchstens alle 10 s statt alle 1,5 s.
  - Die erste Änderung nach dem Hinzufügen oder dem Start kommt sofort dran. Ein neuer Download ist gleich durchsuchbar, und eine Umbenennung kurz nach dem Start wartet nicht.
  - Ein Lauf übernimmt beim Start die Änderungsmarke seiner Quelle. Eine Meldung während des Laufs bleibt für den nächsten Lauf markiert, dessen Baum dann über den Filter entscheidet.
  - Eine Wurzel, die verschwindet oder wiederkommt (`RootChanged`, `Unmount`, `Mount`), umgeht die Sperre. Im Probelauf zeigte ein ausgeworfenes Volume sonst bis zu 10 s lang „aktuell“.
- **Probelauf mit DMG** (`hdiutil`, ohne sudo):
  - Auswerfen klappte ohne „busy“. Danach zeigte die App „Ordner nicht erreichbar · Suche im gespeicherten Index“. Baum und Treffer des Volumes bleiben aus dem gespeicherten Index, Kacheln werden nicht gelöscht.
  - Nach dem Einhängen stand der Index wieder auf „aktuell“, und das Volume erscheint wieder unter „Orte“.
- **Filter im Raster:**
  - Nach einem erfolgreichen Lauf verlässt ein gewählter Ordner den Filter, wenn der neue Baum ihn nicht mehr hat. Das gilt für umbenannte (auch nur in der Groß- und Kleinschreibung), gelöschte und geleerte Ordner.
  - Der Baum entscheidet, nicht die Platte. Ein fehlgeschlagener Lauf, etwa bei einem ausgeworfenen Volume, lässt den Filter stehen, denn der Baum zeigt die Ordner weiter.
- **Neuer Versuch:** Scheitert `FSEventStreamCreate`, versucht der Watcher es nach 1, 2, 4, 8, 16, 32 und 60 s erneut, zusammen etwa 2 Minuten. Danach erst wieder beim nächsten `watch`-Aufruf (Quellen oder Bild-Einstellung geändert). Neue Quellen brechen einen wartenden Versuch für die alten ab. Läuft der Strom nach einem Fehlschlag, kommt einmal eine Meldung für alle Quellen, damit Änderungen aus der Lücke gefunden werden (Review). Ohne Strom folgt der Baum nur über „Index neu aufbauen“ oder einen Neustart.
- **Lebensdauer:** Der Strom hält ein eigenes Objekt mit dem Filter, nicht den Watcher. Freigegeben wird es auf der Queue des Stroms, nach einem schon eingereihten Rückruf.
- **Tests:** In den Modelltests gibt es keinen Watcher, außer einem Fake. Echte FSEvents in Temp-Ordnern hätten sonst zusätzliche Indexläufe in die genau geprüften Abläufe anderer Tests gebracht. Den echten Strom prüfen eigene Tests mit 0,1 s Latenz.
- **Grenzen:**
  - Ein `deleteIndex`, der gerade läuft, hält eine Änderungsmeldung nicht auf. Der Lauf danach bringt den Index wieder in Ordnung (Review, offen).
  - Netzlaufwerke (SMB/AFP) melden Änderungen anderer Rechner nicht über FSEvents. Dort hilft weiter „Index neu aufbauen“.
  - Die Unterordner eines Ortes werden weiterhin nicht beobachtet.
- **Kopfzeile:** Bei einer Suche steht immer „x von y Dateien“, auch wenn alle Dateien treffen. Im Probelauf trafen alle 10 Dateien, und „(10 Dateien)“ sah aus wie Blättern.

## 2026-11-13 — Baum klappt bis zur Auswahl auf (folder-tree)

- **Befund:** Ein verschachtelter Ordner, gewählt per Code, Ort-Klick oder wiederhergestelltem Filter, blieb im zugeklappten Baum unsichtbar. `OutlineGroup` hat keinen Aufklapp-Zustand, den die App setzen könnte.
- **Entscheidung:** Rekursive `DisclosureGroup`s, deren Zustand in `FolderBarSettings.openState` liegt (Pfad → offen/zu).
  - Gemerkt wird der Zustand auch für den nächsten Start (`layout.folderBar.open`).
  - Ohne gemerkten Zustand ist eine Quellwurzel offen, ein Unterordner zu, wie bisher.
  - Ordner, die den Baum verlassen, bleiben gemerkt; ein Volume kann wiederkommen.
- **Aufklappen:**
  - Ändert sich der Filter (auch beim Einblenden der Leiste), klappt `reveal` die Elternordner auf. Der Ordner selbst bleibt, wie er war.
  - Die Liste scrollt dann zum ersten gewählten Ordner in Baum-Reihenfolge. Die Scroll-ID ist die Identität des ForEach, der Pfad.
  - Fehlt der Ordner noch im Baum (ein Ort, der noch lädt), wartet das Aufklappen auf den nächsten Baum.
- **Nur Neues klappt auf (Review):**
  - Aufgeklappt und gescrollt wird nur für Ordner, die neu in den Filter kommen.
  - Klicks, ⌘-Klicks und Pfeiltasten in der Liste selbst lösen das nicht aus, die Liste springt also nicht unter der Hand weg.
  - Auch spätere Anpassungen durch das Modell nicht: ein verschwundener Ordner, abgeglichene Einzeldateien.
  - Ein vom Nutzer zugeklappter Elternordner bleibt zu, bis wieder ein Ordner darunter von außen gewählt wird.
- **Gespeichert wird nur Abweichendes:** Ein Zustand, der dem Standard entspricht, wird nicht gespeichert (Wurzel offen, Unterordner zu). Ein ⌥-Klick, der einen großen Teilbaum zuklappt, speichert also nichts.
- **Teilweise gefunden:** Fehlt einer von mehreren gewählten Ordnern noch im Baum, wartet das Aufklappen für ihn auf den nächsten Baum.
- **Scrollen:** Zwei Main-Actor-Runden nach dem Aufklappen, damit die neuen Zeilen in der Outline-View sind. UI-Tests decken alle drei Wege ab: Einblenden der Leiste, Filteränderung bei sichtbarer Leiste, und Wahl vor dem ersten Baum. Debug-Haken dafür: `-uiTestSelectFolder`, `-uiTestSelectFolderDelay`.
- **Speichern:** Ein Schreibvorgang pro Main-Actor-Runde. Gemessen schrieben 2.501 einzelne `setExpanded` zusammen 6,5 s, weil jedes Mal der ganze Zustand gespeichert wurde. Zusammengefasst sind es 0,23 s (⌥-Klick klappt einen Teilbaum Ordner für Ordner auf).
- **Leistung mit 10.000 Dateien** (2.501 Ordner, Debug-Build, `FolderSidebarPerformanceTests`):

  | Messung | vorher (OutlineGroup) | jetzt |
  |---|---|---|
  | Anzeigen | 0,10 s | 0,10–0,12 s |
  | Filter auf einen tiefen Ordner | 0,06 s (ohne Aufklappen) | 0,07–0,10 s (mit Aufklappen) |
  | alle Ordner offen | – | 0,54 s |
  | ein Auf- oder Zuklappen bei allem offen | – | 0,14 s |

- **UI-Test:**
  - `testFolderBarFiltersAndClears` war schon auf ce42f80 rot: macOS 26 meldet den Text einer Zeile ohne Dreieck als `value`, nicht als `label`. Ein ausdrückliches `accessibilityLabel` ändert daran nichts. Die Tests suchen jetzt nach `label` oder `value`.
  - Neu ist `testFolderBarRevealsChosenFolder`: Ein tiefer Ordner unter 40 anderen wird gewählt und sein Elternordner zugeklappt, die Liste nach oben gescrollt, die Leiste aus- und eingeblendet. Danach ist der Ordner offen und sichtbar.

## 2026-11-13 — Einstellungsfenster: Reiter „Speicher“, Messung wie die App (folder-tree)

- **Befund:** `testSettingsTabsFitAndSizeIsKept` war seit 1.2.4 rot.
  - Der Unit-Test `SettingsWindowTests` baute `SettingsView` ohne `tileCache:` und maß 848 pt.
  - Die App übergibt `.standard`. Damit brauchte „Allgemein“ 985 pt, mit 5 Quellen 1.023,5 pt, bei einem Budget von 880 pt. „Kachel-Cache leeren“ lag etwa 100 pt unter der Unterkante.
- **Entscheidung:** „Index“ und „Kachel-Cache“ ziehen in den neuen Reiter „Speicher“ (Symbol `internaldrive`, Datei `StorageTab.swift`, `SettingsTab.storage`).
  - Der Name kollidiert nicht mit „Word/PowerPoint“ aus dem Office-Zweig.
  - Das Fenster bleibt so groß wie bisher, 680 × 920 pt.
  - Gemessen braucht „Allgemein“ jetzt 748 pt und „Speicher“ 270–309 pt.
- **Messung wie die App:** `neededHeight` baut die Einstellungen mit jedem optionalen Teil wie in `App/PDFSucherApp.swift`, also mit OCR, Verlauf, Index löschen und Kachel-Cache. Gemessen wird jeder Reiter mit 0, 1 und 5 Ordnerquellen; mehrere Quellen fügen eine Auswahl hinzu.
- **Weitere verdeckte Fehler:** Erst danach lief der UI-Test weiter. Drei Fehler kamen zum Vorschein:
  - „Tastatur“: Der Schalter ist kein `checkBox`. Er hat jetzt die Kennung `tabSkipsSearchToggle`, die Wartezeit-Auswahl in „Allgemein“ die Kennung `debouncePicker`.
  - Der Test zog am Hauptfenster: `app.windows.element(boundBy: 0)` war nach dem Ziehen das Hauptfenster. Der Test spricht das Einstellungsfenster jetzt über `com_apple_SwiftUI_Settings_window` an.
  - Das Einstellungsfenster war gar nicht vergrößerbar. SwiftUIs Settings-Fenster kommt ohne `.resizable`, und das Vergrößern aus 1.2.4 war nie wirksam. `WindowFrameKeeper(makesResizable:)` setzt es jetzt.
  - Ein Reiterwechsel behält die vom Nutzer gewählte Größe dann ohne weiteres Zutun. Zwei zusätzliche Mechanismen habe ich probiert und wieder entfernt, weil sie nicht nötig waren: Idealgröße aus der Nutzergröße und Zurücksetzen nach programmgesteuerten Größenänderungen.
- **Offen:** „Texterkennung“ wächst um etwa 51 pt pro Ordnerquelle (5 Quellen: 447 pt) und scrollt ab etwa 9 Quellen. Das ist eine Liste und als solche hinnehmbar.

## 2026-11-13 — 1.3.1: Downloads prompt at launch (TileDiskCache, not the fonts); Office font discovery hardened

- **Report (1.3.0 UI run):** at app start macOS asks "PDFSucher.app would like to access files in your Downloads folder", in the Debug build after every rebuild; `SlideDeck.prewarmFonts()` was suspected (the UI-test mode switched prewarm off for it).
- **Root cause (measured):** not the fonts. The v1.3.0 Debug app, UI-test mode with prewarm on, was run with an interposer library (`open`, `openat`, `stat`, `lstat`, `fstatat`, `access`, `faccessat`, `getattrlist`, `getxattr`, `statfs`, `pathconf`, `opendir`, `readlink`, `realpath`) that logged every path under ~/Downloads, ~/Desktop, ~/Documents with its backtrace and refused it with EPERM before TCC (no dialog). 142 accesses in 25 s (6 in ~/Downloads, the rest in ~/Documents), every one from `ViewerUI.TileDiskCache.init(directory:byteLimit:pendingWriteLimit:)` → `pruneStaleNow(under:)` → `TileDiskCache.Source.current` (`FileManager.attributesOfItem` → `lstat`) and `FileManager.fileExists` (`stat`) on the source PDFs and folders the tile cache remembers. Trigger: `TileDiskCache.standard` at launch (`App/PDFSucherApp.swift`: `model.tileDisk = .standard`, `tileCache: .standard` in the settings scene), also in UI-test mode, which uses the user's real tile cache. The font prewarm made no access outside the Office roots: in the app, in a window-less .app replica of its steps and on the command line. Fix of the tile cache: app thread (ViewerUI).
- **Office font discovery hardened anyway (slidekit-fontpaths):** `OfficeFonts.defaultDirectories` reads only fixed places: `/Applications/Microsoft {PowerPoint, Word, Excel, Outlook, OneNote}.app/Contents/Resources/DFonts` and `~/Library/Group Containers/UBF8T346G9.Office/FontCache/<n>/CloudFonts` (no LaunchServices, no search; ~/Applications dropped, not needed). Every path component below `/Applications` resp. the home folder is checked with `lstat`; a symbolic link anywhere drops that place without following it. `fontFiles` walks with directory listing + `lstat` and takes regular files only; links to files or folders are skipped. Before, an Office app that is a link (e.g. into ~/Downloads) was followed by `fileExists` and the enumerator (checked with the old logic); links to font files and subfolders were already not followed. All file access of the discovery goes through `OfficeFonts.DiscoveryFS`, whose `record` hook the tests use; Core Text later opens the files found by path (registration, outside the seam). The home folder itself is trusted (a network or automount home that is a link is followed once); everything below it is a fixed name checked with `lstat`. Path checks are lexical (`URL.standardizedFileURL`), ".." is rejected.
- **Tests:** `OfficeFontsTests.discoveryNeverTouchesUserFoldersNorFollowsLinks` (fake home with Downloads/Desktop/Documents full of fonts, links into them from an Office app, a DFonts entry, a DFonts subfolder, the group container and a CloudFonts entry: only the two real fonts are found, no recorded path lies in a user folder or outside the Office roots, and no ancestor of any recorded path is a link, checked with lstat outside the seam), `realDiscoveryStaysInOfficeRoots` (the same check on this Mac's real places; since the follow-up below only with `PDFSUCHER_TEST_OFFICE_FONTS=1`), `linkedFontIsNotRegistered`, `plainDirectoryChecksAreLexicalAndBounded`, `defaultDirectoriesFollowOfficesLayout` (updated: no ~/Applications).
- **Cloud font cache with a time limit (slidekit-fontpaths, agreed with the office thread):** reading Office's cloud font cache (another vendor's group container) can block while macOS holds it for an access prompt; observed here: a listing that took 4–6 s, then hung without end while a prompt was pending. `OfficeFonts.registerDefault` reads the cloud folders on a thread of their own and waits at most 2 s from the start (`cloudTimeout`; the DFonts are registered meanwhile), so neither `prewarm()` nor the lazy first use blocks longer than about 2 s. After the timeout the caller goes on without cloud fonts (see the next entries: no late registration).
- **Office font roots injectable, off in tests:** `FontResolver.officeFontRoots: OfficeFontRoots` (`applications`, `home`; `.standard` = /Applications and the user's home, `.none`), set before the first font resolution. Default `.standard`, but `.none` in a test process (XCTest / Swift Testing, detected from the environment, process name or a loaded `XCTestCase`), so no OOXMLKit, SlideKit or AppCore test reads the real Office folders or group container; `PDFSUCHER_TEST_OFFICE_FONTS=1` opts a test run in (corpus measurements). Every discovery with the production seam is recorded in `OfficeFonts.processLog`; `testProcessNeverReadsTheRealOfficeFolders` fails if a real Office path shows up. The app's UI-test mode is not a test process: the app thread sets `FontResolver.officeFontRoots = .none` there if UI tests must not read them either. `FontResolver.officeFontDirectories` was removed (unused; it read the cloud cache without a limit).
- **Tests (timeout):** `blockedCloudReadDoesNotHoldTheCallerAndRegistersLate` (superseded below by `blockedCloudReadIsDroppedAndRegistersNothingLate`), `cloudReadInTimeIsRegisteredAtOnce`, `bundledAndOffSkipTheCloudRead`.
- **Review fixes (cloud timeout):** name lookups (face by full name, regular face) store their result only if no registration happened meanwhile (`Memos.generation`), so a late cloud registration never leaves a stale "not installed" behind; an empty late result changes nothing; `OfficeFonts.processLog` records only in test processes; `defaultDirectories` has no real-path defaults any more (tests pass their roots); setting `officeFontRoots` after the registration started is asserted in debug builds. The 2 s limit covers the cloud read; registering files that arrived in time follows it. Not verified here: that an app started by XCUIApplication gets no `XCTest*` variables (it would only switch that app to `.none`, which is harmless).
- **No late registration (office thread review of cdeb342, variant a):** a cloud read that misses the 2 s limit is dropped for the rest of the process, even when it arrives later; Office's cloud fonts then come with the next app launch (the read normally succeeds once the user has answered the macOS prompt). Reasons: (1) a font registration while TextKit lays out a Word document on another thread raises „attempted layout while textStorage is editing“ (2 of 5 test runs before ae4c89e), and the late case is the normal one when the user answers the prompt after more than 2 s; (2) index text, slide layouts and tiles must not be laid out with different fonts within one process.
- **Every registration finishes before font users go on (checked):** the only production registration is the once-per-process one inside the first build of FontResolver's installed-family list, on the serial font queue; every font-resolving caller waits for that build, and Word layout (`TextKitWordDocument.init`, the only off-main-thread TextKit layout in the app) calls `FontResolver.prewarm()` before it lays out, so it waits too. `FontResolver.registerFonts(in:)` is internal now (tests only); `OfficeFonts.register` asserts it runs on the font queue. Test `callersReturnOnlyAfterTheRegistrationFinished` runs the real once-path again with injected roots and a slow fake cloud read: 12 concurrent callers (`prewarm`, `resolvedFamily`, `font`) all return after the last registration ended and find the registered fonts. Remaining, not changed here: text that AppKit/SwiftUI lays out on the main thread during the launch-time registration (prewarm runs in the background then) is not ordered against it; no crash seen there, the TextKit crash needs a text storage laid out off the main thread.
- **Tests (no late registration):** `blockedCloudReadIsDroppedAndRegistersNothingLate` (fake read blocking 3 s: the caller returns after 1.9–2.5 s with the DFonts, the late result is dropped and counted, the cloud font stays unavailable), `callersReturnOnlyAfterTheRegistrationFinished`.
- **Font gate (review of 09d39b9):** the ordering above held for the app, not for the test process, where registering tests (`registerFonts(in:)`, the once-path re-run) could overlap a Word layout of a parallel suite. Now a process-wide readers-writer lock orders them: `FontResolver.withStableFonts { }` (shared) around TextKit import + layout in `TextKitWordDocument.init` and around `page(_:)` and `draw(page:in:)`; `OfficeFonts.register` takes it exclusively once per registration pass (first it reads which files are new outside the gate, then registers them all inside one exclusive hold, errors per file; holding it per file let waiting layouts slow every file down and kept the font queue blocked; test `oneExclusiveGateHoldPerRegistrationPass`). Rules: `prewarm()` before the gate, never inside (a registration waiting for the gate would wait for itself); no FontResolver call inside; no nesting. Test `registrationWaitsForLayoutInsideTheGate` (proves the ordering, not the crash fix). Assumed, not verified: that TextKit's failing edit happens during the synchronous `CTFontManagerRegisterFontsForURL` call; should it come from the fonts-changed notification delivered later, the gate would not cover it. No stress test reproduces the original crash (it was seen in 2 of 5 suite runs before ae4c89e); in the app the gate is uncontended anyway, because the only registration finishes before the first Word layout (prewarm). pthread return codes are checked (precondition). The "late registration" wording of the earlier review-fix entry is history: today only tests register after the once-path. `resetOfficeFontsForTests` restores the previous roots override (corpus opt-in keeps working).
- **Font gate held until AppKit delivered the font-set changes (investigation of the rare crash in WordLayoutFontStressTests, office-fonts-lazy, 1 in 20 runs):** measured with a probe (registrations under the exclusive gate, background TextKit layout under the shared gate, main run loop running, hooks on `NSTextStorage`): AppKit posts one `NSFontSetChangedNotification` per registered or unregistered file, never coalesced, asynchronously on the main thread after `CTFontManagerRegisterFontsForURL` has returned, i.e. after the gate was released (also `CTFontManagerFontChangedNotification` on the local CF center and the NS one). TextKit observes it: `+[NSTextStorage _fontSetChanged:]` calls `-fontSetChanged` on the live text storages, on the main thread, outside any gate; storages a background thread was laying out at that moment (cached Word documents: `page(_:)`, `draw(page:in:)`) were hit ~350 times per probe run. That cross-thread access is the remaining path to „attempted layout while textStorage is editing“ (the probe also raised exactly that exception, though in a variant with an extra race of its own; without it the overlap was frequent but no crash in 5 runs, consistent with 1 in 20). Fix: `FontGate.exclusiveFontChange` keeps the exclusive hold until as many notifications as files changed have been delivered (own observer plus one main-queue round, so TextKit's observer of the same post has run), at most 0.5 s; `OfficeFonts.register` uses it. Probe with the hold: 0 overlaps in 5 runs, ~0.1 ms extra per registration, no time-outs. Test `registrationHoldsTheGateUntilAppKitDeliveredTheFontSetChanges` (counts deliveries at the moment the hold ends; red in 2 of 3 runs with the wait switched off). No wait when TextKit is not loaded, on the main thread, or when nothing changed. Deadlock: the wait needs the main thread; if it is blocked (e.g. waiting on the font queue, which holds this registration), the 0.5 s limit ends the wait (counted in `deliveryTimeouts`) and that delivery may overlap layout as before — bounded, no deadlock. Unregistrations must use the same hold, else their late posts count for a later hold and end it early (fixed here for the test cleanups in `FixtureFonts.deinit` and `oneExclusiveGateHoldPerRegistrationPass`; the office stress test's cleanup on office-fonts-lazy calls `fontGate.exclusive` directly and should call `exclusiveFontChange` returning the count). The observer is added inside the hold, right before the change. Cost: normally ~0.1 ms; up to 0.5 s per registration pass when the main thread is blocked meanwhile (two passes at launch: DFonts, cloud), so the "about 2 s" bound of the cloud read becomes about 2 s plus that. `deliveryTimeouts` counts holds that ended at the limit. The test raises the limit (`FontGate.defaultDeliveryTimeout`) to 10 s, so a busy main thread in the shared test process cannot fail it. Earlier claim corrected: in the app registration and Word layout can overlap too (office-fonts-lazy starts prewarm with the first Office file and Word waits at most 3 s), so this is not a test-only window.

## 2026-11-14 — Suche auch im Dateinamen (1.3.2 Teil A)

- **Regeln:** Der Dateiname ohne Endung und ohne Ordner wird mit `PageMatcher` geprüft, also mit denselben Regeln wie der Text. Ein Dokument erscheint, wenn der Name ODER der Inhalt passt. Begriffe, die sich auf Name und Inhalt verteilen, zählen nicht.
- **Kein neues Schema, abweichend von der Vorgabe „eigene FTS-Spalte“:**
  - `SearchService` liest für jede Suche ohnehin alle Dokumente.
  - Die Namensprüfung dauert gemessen 1,7 ms für 10.000 Namen (Release), 75 ms im Debug-Build der Tests.
  - Ein Schema 4 mit Migration hätte das Risiko eines Neuaufbaus gebracht, ohne messbaren Gewinn.
- **Anzeige:**
  - Ein reiner Namenstreffer hat keine Trefferseiten. Die Reihe zeigt deshalb wie beim Durchblättern alle Seiten.
  - Neben dem Namen steht „Treffer im Dateinamen“, der Begriff ist im Namen hervorgehoben, nicht in Endung oder Zählern.
- **Sortierung:** Bei Relevanz kommen Namenstreffer zuerst (`nameMatch`), die anderen Sortierungen bleiben.
- **Einzeldateien:** Ein PDF ohne Text wird über seinen Namen gefunden statt mit „kein Text“ abgewiesen.
- **Schalter:** „Auch Dateinamen durchsuchen“ unter Allgemein → Suche, Standard an. Eine Änderung sucht sofort neu.
- **Ältere Test-Doubles:** `FolderIndexing` hat die neue Suche mit einer Standardform, die nur den Inhalt durchsucht.

## 2026-11-14 — Vorschaubreite folgt dem Zoom (1.3.2 Teil B)

- **Was sich ändert:** Nur der Vorschaubereich neben dem Raster. Das Raster bekommt den frei werdenden Platz, das Hauptfenster bleibt gleich groß. Ist die Vorschau über dem Raster, bleibt ihre Breite gleich.
- **Bezugsbreite B:** die Breite, die der Nutzer am Teiler eingestellt hat; sie bleibt wie bisher als Anteil je Lage gespeichert.
  - `PDFPageView` rechnet Zoom-Stufen und „Ganze Seite“ gegen B (`PreviewZoom.referenceWidth`), nie gegen die gerade gezeigte Breite. So schaukelt sich nichts auf.
  - Die gezeigte Breite ist Seitenbreite × Maßstab + 24 pt Rand (+ Rollbalken), mindestens die Mindestbreite, höchstens B (`PreviewWidthMath`).
- **Flackerfrei:** Breitenwechsel werden gebündelt (`WidthBundler`, 120 ms) und mit 150 ms animiert. Beim Ziehen am Teiler gilt sofort B.
- **Zoom über die Breite hinaus (Standard aus):** Aus ist 100 % von B die Grenze.
  - `PDFView.maxScaleFactor` hält sie auch beim Trackpad-Zoom.
  - ⌘+ und der Plus-Knopf hören dort auf (`PreviewZoom.maxPercent`, `canZoomIn`); ein Schritt über die Grenze wird ⌘1.
  - An: weiter bis 800 %, die Breite bleibt B, waagerecht wird gescrollt.
- **Zoomen hält die Mitte:** PDFView behält beim Zoomen die Seitenmitte, wie in 1.3.1.
- **Gemessen im echten Fenster** (1.400 pt, Vorschau links, B = 627 pt): Seitenbreite 627 pt, 75 % 487 pt, 50 % 339 pt, 200 % mit Option 627 pt mit Rollbalken. Kontrollbilder per `PDFSUCHER_PREVIEW_SHOTS`.

## 2026-11-14 — Review von 1.3.2 (nach dem Merge von office-fonts-lazy)

- **Wackliger Leistungstest:** `BrowseTests.tenThousandFilesWithoutHang` schlug auf main einmal mit 3,45 s fehl (Grenze 3 s). Die Suite läuft auf dem MainActor; im parallelen Lauf misst die Wanduhr fremde MainActor-Arbeit mit. Gemessen unter doppelter Last: erster Durchlauf 2,3–3,2 s, zweiter und dritter 0,19–0,47 s. Der Test vergleicht jetzt den besten von 3 Durchläufen, Grenzen unverändert.
- **UI-Test-Modus und Office-Schriften:** `FontResolver.officeFontRoots = .none` (`OfficeDisplay.useNoOfficeFonts()`) ist der einzige Schalter. Jede Registrierung liest diese Wurzeln, das Vorwärmen darf also laufen und findet keine Office-Ordner. Den Stub `model.prewarmFonts = {}` aus 798b2bd habe ich entfernt; er hielt nur den frühen Start im AppModel auf, nicht das Word-Gate.
- **Behoben:**
  - Word-Dokument-Cache: Ein Dokument, das ein Anzeigeweg vor der Registrierung gesetzt hatte (Ersatzschriften), bekam die Layout-Phase als Cache-Treffer und speicherte Indextext und Wortboxen mit Ersatzschriften. Der Schlüssel enthält jetzt `fontsDone` (`FontRegistrationGate.isDone`); ein Lauf über die Frist hinaus gilt nicht als fertig, also wird nichts wiederholt neu gesetzt.
  - Zoom: ⌘+ über die Grenze ging auf Stufe 1, die unter 100 % eingestellt sein kann (Hineinzoomen verkleinerte). Jetzt geht es auf die Grenze selbst (`.percent(maxPercent)`). Ein gespeicherter Prozentwert über der Grenze erscheint in der Zoomleiste als Grenze.
  - Vorschau oben oder Breite folgt nicht dem Zoom: Ab dem zweiten Fenster-Resize lief die Breite durch den 120-ms-Bündler und wurde animiert. Jetzt gilt B sofort (Echtfenster-Test mit zwei Resizes).
- **Offen, zur Entscheidung (Chris):**
  - Nach einem Neustart ohne anstehendes Layout startet niemand die Schrift-Registrierung (Anzeigewege treten nur bei). Word-Vorschau und -Kacheln entstehen dann mit Ersatzschriften, Hervorhebungen können neben den Wortboxen liegen. In 1.3.1 wartete jedes Word-Dokument auf die Schriften. Vorschlag: das Vorwärmen starten, sobald ein Word-Dokument (oder ein Deck unter SlideKit) im Raster erscheint. Das widerspricht `OfficeFontPrewarmTests.searchingAndBrowsingNeverPrewarm` (die macOS-Frage nie mitten in einer Suche); praktisch kam die Frage für diese Dokumente aber schon beim Layout eines früheren Starts.
  - Frühe Teilergebnisse: Ein reiner Namenstreffer kann im Endergebnis Inhaltstreffer bekommen (Reihe und Sortierplatz ändern sich). So in der Spec gewollt; der Vertrag von `onPartial` nennt die Ausnahme jetzt.
  - `OfficeFonts`: Office in ~/Applications liefert keine Schriften mehr (bewusst in slidekit-fontpaths).
  - Aufräumen: `OfficeFontPrewarm` doppelt das Einmal-Flag des Gates und parkt einen GCD-Thread bis 3 s; die Rollbalken-Zugabe steht an drei Stellen.

## 2026-11-14 — Entscheidungen von Chris zu den offenen Punkten des Reviews

- **Schriften nach dem Neustart:** übernimmt der Office-Thread (starten, sobald ein Word- oder Deck-Dokument erscheint; sofort beim Start, wenn die Registrierung schon einmal gelang; nicht während der Eingabe; danach neu zeichnen).
- **Namenssuche auch für nicht lesbare Dokumente:**
  - Ordner: `SearchService` prüft die Namen aller Dokumente, den Inhalt weiter nur von Status `.ok`. Ein Dokument mit Status `.error` erscheint wie beim Durchblättern (`isUnreadable`, 0 Seiten), `.noText` mit seinen Seiten, ein noch nicht gelesenes mit 0 Seiten (Platzhalter).
  - Einzeldateien: Wirft die Textquelle (gesperrt, beschädigt, `StaleFileLayout`), sucht `AppModel.run` den Namen (`SingleDocumentSearch.nameMatches`) und zeigt die Reihe wie beim Durchblättern (`singleEntry`, bei `StaleFileLayout` als wartend). Der Fehler läuft weiter durch `apply` (ein geändertes Office-Dokument wird neu gesetzt), nur der Hinweis „nicht lesbar“ entfällt, solange die Reihe es zeigt.
  - Die Reihe zeigt Fehlersymbol oder Platzhalter samt „Treffer im Dateinamen“; die Ansicht brauchte dafür nichts Neues.
- **Springende Reihe bei frühen Namenstreffern** und **Office unter ~/Applications:** bleiben so.

## 2026-11-14 — Office-Schriften nach einem Neustart starten (1.3.2, Branch `office-fonts-start`)

- **Regression:** nach einem Neustart ohne anstehendes Layout startete niemand die Schrift-Registrierung (Anzeigewege treten nur bei); Word-Kacheln/-Vorschau mit Ersatzschriften, Hervorhebungen neben den Wörtern.
- **(a) Start bei sichtbaren Dokumenten:** `ViewerModel.officeDocumentShown(_:)` (Vorgabe: nichts). `DocumentRow.onAppear` (Word/PowerPoint-Zeile) und `PageDetailView` (Vorschau einer Office-Seite) rufen es auf dem Main Actor, nie Render-/Kachel-Threads. `AppModel` startet daraus die Registrierung über denselben Weg wie bisher (`OfficeFontPrewarm`, einmal je Modell, GCD utility → `OfficeDisplay.prewarmFonts()` → `FontRegistrationGate.shared.wait()`, eigener Thread), nur mit „Word/PowerPoint“ an, für Word und Decks unter SlideKit (Quick Look zeichnet selbst; PDF/Bild nie).
- **(c) Nicht mitten im Tippen:** `queryText`-Änderungen merken `lastTyping`; ein Start aus (a) wartet, bis das Suchfeld `typingIdleDelay` (1 s) ruhig ist (ein wartender Task, je Tipp neu bemessen). `searchingAndBrowsingNeverPrewarm` bleibt (Suchen allein startet nie), neu `typingDefersTheStartUntilInputIsIdle`. Layoutläufe starten wie bisher sofort.
- **(b) Beim Start nach früherem Erfolg:** `office.fontsRegisteredOnce` (UserDefaults des Modells) wird nur bei Erfolg gesetzt: `prewarmFonts` liefert jetzt `Bool` = Gate innerhalb der Frist fertig **und** der Cloud-Schriftcache rechtzeitig gelesen (`FontResolver.officeFontsIncomplete`, neu in OOXMLKit: die einmalige Registrierung hat den Cloud-Lesevorgang nach 2 s aufgegeben). Ist der Schlüssel gesetzt, ruft die App beim Start `startOfficeFontsIfRegisteredBefore()` (nur im normalen Startpfad, nicht im UI-Test-Modus; Tests haben eigene Defaults-Suiten). Grenze: eine **verweigerte** Abfrage liest sich wie ein leerer Cloud-Cache und zählt als Erfolg; macOS fragt nach einer Ablehnung nicht erneut (TCC), der frühe Start bringt dann keine Abfrage.
- **(d) Neu zeichnen nach Erfolg** („Schriften da“ heißt hier und in (e) `FontRegistrationGate.isComplete`: fertig und Cloud-Schriften nicht verpasst, siehe Korrektur unten): `OfficePages.contentVersion` für Word ist `textkit:1+fonts`, sobald `FontRegistrationGate.shared.isDone` (vorher `textkit:1`): eine mit Ersatzschriften gezeichnete Kachel wird weder im Speicher noch auf der Platte wiederverwendet. `fontsRegistered()` erhöht `foreignPagesRevision` einmal, wenn vor dem Erfolg ein Word-Dokument gezeigt wurde (neuer Kachel-Cache, Vorschau lädt neu); der Word-Dokument-Cache (35f8f55, `fontsDone` im Schlüssel) liefert dann neu gesetzte Dokumente. SlideKit: keine Änderung nötig – SlideKit löst Schriften über `FontResolver` auf und wartet dabei selbst auf die Registrierung, zeichnet also nie vor ihr.
- **(e) Index-Konsistenz – Befund** („fertig“/`isDone` unten ist seit c5b1d24 `isComplete`): 35f8f55 setzt nur den **In-Memory-Cache** neu; im Index blieb ein Word-Dokument, das die Layoutphase nach Ablauf der 3 s (offene/abgelehnte Abfrage) mit Ersatzschriften gesetzt hatte, dauerhaft als `textkit:1` mit falschen Wortboxen stehen, auch über Neustarts. Lösung: `TextKitWordDocument.laidOutWithOfficeFonts` (= `isDone` nach dem Gate); `TextKitWordSource` speichert solche Dokumente als Renderer `textkit-substitute` (Version 1; erwarteter Renderer bleibt `textkit` 1, also kein Neusetzen aller Word-Dateien). Neu `PageLayoutSource.staleRenderers(for:)` (Vorgabe leer): `TextKitWordSource` meldet `textkit-substitute`, sobald die Registrierung fertig ist; der Indexer setzt diese Dokumente zu Beginn jedes Layoutlaufs auf `needs_layout` (vorher nie – sonst würde bei dauerhaftem Zeitlimit immer wieder neu gesetzt). `fontsRegistered()` stößt Layoutläufe nur für Ordner an, deren Index `textkit-substitute`-Dokumente hat (`FolderIndexing.hasLayouts(byRenderer:)`), und reiht Word-Einzeldateien mit diesem Renderer neu ein. „vereinfacht“ gilt für beide Namen (`StoredDocument.isSimplifiedRenderer`).
- Reihenfolge Gate → `textKit` → `withStableFonts` und die Gate-Regeln (Anzeigewege treten nur bei) unverändert.
- **Korrektur nach Review von 229d93a – „Schriften da“ heißt vollständig:** `FontRegistrationGate.isDone` war auch wahr, wenn OOXMLKit den Cloud-Schriftcache nach 2 s aufgegeben hatte (Abfrage offen, Registrierung trotzdem innerhalb der 3 s fertig). Folge: Word mit Ersatzschriften als `textkit` gespeichert, Kacheln als `textkit:1+fonts` auf der Platte, beim nächsten Start (Abfrage erlaubt) nichts als veraltet erkannt. Jetzt gibt es ein Prädikat `FontRegistrationGate.isComplete` (= `isDone` und `complete()`; beim geteilten Gate `!FontResolver.officeFontsIncomplete`, Testgates injizieren es). Es entscheidet überall: `laidOutWithOfficeFonts`, Cache-Schlüssel `fontsDone` (35f8f55), `staleRenderers`, `+fonts` im Kachelschlüssel, `prewarmFonts`. In einem Prozess ohne Cloud-Schriften bleibt es falsch: keine Endlosschleife. `resetOfficeFontsForTests` setzt auch `defaultMissedCloud` zurück.
- **Später Erfolg:** endet `wait()` an der Frist, die Registrierung aber danach vollständig (Abfrage spät beantwortet), läuft dieselbe Erfolgsbehandlung (`fontsRegistered`) über `FontRegistrationGate.notifyWhenDone` (`OfficeDisplay.whenFontsComplete`, Seam `AppModel.fontsCompleteLater`). Wegen „keine Registrierung nach der Frist“ (OOXMLKit verwirft den späten Cloud-Lesevorgang) ist das nur dann „vollständig“, wenn der Cloud-Teil rechtzeitig kam – sonst bleibt es beim nächsten Start.
- **Grenzen der Abfrage-Zeitpunkte:** der Start aus (a) kommt frühestens 1 s nach dem letzten Tastendruck; die macOS-Abfrage kann danach noch bis ~2 s später erscheinen (Cloud-Lesevorgang) – tippt man dann wieder, kommt sie trotzdem. Neue oder Ad-hoc-Signaturen (Debug-Builds, neue Version) lassen TCC erneut fragen: der Start beim Programmstart (b) kann dann einmal die Abfrage bringen, ohne dass ein Office-Dokument sichtbar ist.
- **Merge `cc2ebbb` (Font-Gate bis zur Zustellung der Font-Set-Änderungen):** `StressFonts.remove` (`WordLayoutFontStressTests`) läuft jetzt über `FontGate.exclusiveFontChange` und liefert die Zahl der erfolgreichen `CTFontManagerUnregisterFontsForURL`-Aufrufe (sonst zählte eine spätere Registrierung deren Benachrichtigungen als ihre eigenen).
- **Main Thread während einer Registrierung (geprüft):** `withStableFonts` (Font-Gate geteilt) ruft nur `TextKitWordDocument` (`init`, `page`, `draw`); deren Aufrufer laufen alle abseits des Main Threads (Layout in abgelösten Tasks, Kacheln auf Render-Threads, Vorschau/Sichern/Drucken in `Task.detached`; die Word-Vorschauseite ist ein fertig gezeichnetes PDF, PDFView zeichnet kein TextKit). **Aber** über FontResolver kann der Main Thread warten: die Vorschau eines Decks unter SlideKit ist eine `SlidePDFPage`, die PDFView auf dem Main Thread zeichnet; deren Schriftauflösung geht bei leerem Cache (die Liste der installierten Familien wird während der ersten Registrierung neu gebaut) per `offPool` auf die serielle Schriftenqueue, auf der die Registrierung läuft und in `exclusiveFontChange` auf die Zustellung auf dem Main Thread wartet. Keine Verklemmung: die Registrierung gibt nach 0,5 s je Durchgang auf (DFonts und Cloud, also höchstens ~1 s), danach läuft der Main Thread weiter; in dieser Zeit steht die Oberfläche, und die verspäteten Zustellungen können wie früher neben einem Word-Layout landen (Rückfallebene: serielles Word-Layout `textKit`). Mit 1.3.2 wahrscheinlicher, weil ein in der Vorschau gezeigtes Deck die Registrierung jetzt selbst startet (fonts-start a). Hingenommen; gemessen ist es nicht.

## 2026-11-14 — Wacklige Tests nach dem Merge von office-fonts-start

- **`SettingsWindowTests.theSettingsWindowBecomesResizable` (behoben):** Gemessen im parallelen ViewerUI-Lauf: Die `HostView` des Keepers existiert nach 0,4 ms, aber das erste `Task.sleep(10 ms)` des Tests kehrte erst nach 9,8–12,5 s zurück. `sample` zeigt den Hauptthread in dieser Zeit zu zwei Dritteln in `everyTabFitsTheDefaultSize` (synchrone SwiftUI-Layoutmessung jedes Reiters). Jede Frist kann so ablaufen. Der Test wartet jetzt auf den Keeper-Schritt selbst: ein Block, der nach dem Layout auf die serielle Hauptwarteschlange gestellt wird, läuft nach dem des Keepers. Gegenprobe mit `makesResizable: false` schlägt fehl. 20 von 20 ViewerUI-Läufen grün.
- **`PageSelectionTests.unknownDocumentsGoLastSortedByPath` (Ursache nicht gefunden, nichts geändert):**
  - Belegt: 2 Fehler in etwa 120 vollen Läufen auf diesem Mac, beide mit derselben Ausgabe B, Z, A, C, beide in den ersten 0,08 s des OutputKit-Prozesses, wenn alle Suiten gleichzeitig starten. Z wird dabei vor A und C einsortiert, als wäre Z „bekannt“ oder kleiner als A.
  - Ausgeschlossen: Der Vergleich ist in allen 24 Eingangsreihenfolgen konsistent (`refs` ist ein `Set`, die Reihenfolge hängt vom Hash-Seed ab). `localizedStandardCompare` lieferte keine falschen Werte: 800.000 gleichzeitige Vergleiche, 400 Prozesse mit gleichzeitigem Erstaufruf, 200 Prozesse parallel zur AppKit-Druckinitialisierung. URL-Dictionary-Lookups in 2.000 Prozessen (Hash-Seeds): kein Fehltreffer. Kein Test im Prozess ändert Locale, Arbeitsverzeichnis oder Defaults.
  - Nicht reproduziert: 30 Läufe des Ziels allein, 111 unter Last anderer Test-Bundles, rund 25 Läufe mit gleichzeitig gestarteten Bundles, 20 Läufe zum Schluss. Der Test bleibt unverändert, bis ein neuer Fehlerlauf mehr zeigt (dann die volle Ausgabe sichern).

## 2026-11-14 — 1.3.3: der erste Treffer sofort in der großen Vorschau (Branch `release-1.3.3`)

- **Wunsch (Chris):** Hat eine Suche Treffer, zeigt die große Vorschau sofort das erste Dokument der Liste, ohne ↓.
- **Was gezeigt wird:** `FocusNavigator.firstHit(in:)` = erste Trefferseite (erste in `pageHits`, also Rasterreihenfolge) des ersten Dokuments mit Kacheln in der angezeigten Reihenfolge, nach allen Filtern. Ein nur über den Dateinamen gefundenes Dokument zeigt Seite 1; gesperrte/leere Dokumente ohne Kacheln werden übersprungen. Mit „Alle Seiten“ bleibt es die erste Trefferseite (nicht Seite 1). Gilt für PDF, Bild, Word und PowerPoint gleich (alles `DocumentHit`).
- **Wann (nach Review geändert):** Einmal je Suchbegriff, wenn dessen **Endergebnis** angezeigt wird (`show(...)`, `firstHitPending`). Frühe Zeilen einer langsamen Suche setzen nichts: Sie sind oft anders sortiert, die Vorschau hätte sonst zweimal gewechselt (Review 2). Spätere Ergebnisse desselben Begriffs (Indexierung, Texterkennung, Finder-Änderung, Sortierwechsel) lassen eine gezeigte Seite stehen, auch wenn jetzt ein anderes Dokument oben steht. Sonst würde das Raster beim Lesen nach oben springen, bei einer ersten Indexierung alle paar Sekunden (Review 1). Nur wenn die gezeigte Seite verschwindet (Filter, Datei weg) und die Vorschau leer würde, rückt der erste angezeigte Treffer nach (`refillEmptyPreview` am Ende von `publishFiltered`). Der Fokus wird nur gesetzt, wenn er sich ändert.
- **Wessen Auswahl:** `focusChosenByUser`. Jede Zuweisung an `focusedPage` von außen (Klick, Pfeile, ‹ ›) zählt als Wahl des Nutzers, auch wenn sie dieselbe Seite ist, die automatisch gewählt war. Das Modell setzt den Fokus nur über `setFocusByModel` (Flag `settingFocus`): das ist keine Wahl und keine „Ankunft“ für den Suchverlauf (`noteSearchArrived`), sonst würde jeder getippte Begriff sofort gespeichert. Setzt das Modell den Fokus auf nil, gilt auch keine Wahl mehr (Review 3). Ebenso das Nachrücken nach „Alle Seiten“ aus (`nearestShown`): bisher löste es eine Verlaufs-Ankunft aus, jetzt nicht mehr.
- **Neuer Begriff:** `show(...)` setzt `focusChosenByUser` zurück und `firstHitPending`, wenn sich die geparste Anfrage ändert. Mit Wahl des Nutzers bleibt sie bei neuen Ergebnissen desselben Begriffs stehen.
- **Gewählte oder gezeigte Seite verschwindet:** Wie bisher verliert sie den Fokus, und neu rückt der erste angezeigte Treffer nach (statt leerer Vorschau). Begründung: Die Regel „Treffer da → Vorschau zeigt etwas“ gilt dann wieder.
- **Tippen, Flackern:** Kein eigener Zeitgeber. Jedes Endergebnis ist schon entprellt (`typingDelay`); die Vorschau wechselt also höchstens einmal je gesuchtem Begriff. Die Vorschau lädt asynchron, das Tippen wartet nicht auf sie.
- **Leeres Suchfeld, keine Treffer:** Durchblättern wählt nichts automatisch; ohne Treffer bleibt die Vorschau leer. Wird das Suchfeld geleert, bleibt eine gezeigte Seite stehen (sie ist auch beim Durchblättern eine Kachel), genau wie es bisher eine gewählte Seite tat (Review 4, bewusst so).
- **Tastatur (Punkt 2, Chris 2026-11-14: „Erst auf den ersten Treffer“):** Der Fokus bleibt im Suchfeld (das Modell ändert nur `focusedPage`, nie `FocusState`). Zeigt die Vorschau den vom Modell gewählten ersten Treffer (`ViewerModel.focusIsAutomatic`: Seite gesetzt, keine Wahl des Nutzers, Suche statt Durchblättern), springt das erste ↓ aus dem Suchfeld ins Raster auf genau diese Kachel. Die Vorschau bleibt gleich, die Seite gilt jetzt als Wahl des Nutzers, und der Begriff kommt in den Suchverlauf (`KeyRouterApplier`, `.navigate(.down)`). So hakt „Tippen, ↓, Return“ wie vor 1.3.3 den ersten Treffer an. Jedes weitere ↓ geht wie gewohnt zum nächsten Dokument. Hat der Nutzer selbst eine Seite gewählt, oder wird nur durchgeblättert, wirkt ↓ wie bisher. ←/→/↑ aus dem Feld navigieren wie bisher von der gezeigten Kachel aus. Die zuerst umgesetzte Fassung („↓ geht gleich zum nächsten Dokument“, Commits 11e9145/2d55cf2) ist damit ersetzt.
- **Tests:** `FirstHitPreviewTests` (AppCore, 17, davon 4 nach dem Review: gleiche Suche aktualisiert, Sortierwechsel, frühe Zeilen, Suchfeld geleert; 2 für `focusIsAutomatic`), `FirstHitTests` (ViewerUI, 4), `KeyRoutingApplyTests` (erstes ↓ auf den automatisch gezeigten ersten Treffer, ↓ von einer gewählten Seite, andere Pfeile). Angepasst, weil sich das Verhalten bewusst ändert: `focusMovesToTheFirstHitWhenItsPageDisappears` (vorher `focusResetsWhenHitDisappears`, erwartete nil) und `focusOnHiddenPageIsCleared` (erwartet jetzt den ersten angezeigten Treffer). `testFirstStartTypeThenArrowSelectsFirstHit` prüft jetzt, dass die Vorschau schon vor ↓ das erste Dokument zeigt, ↓ diese Seite behält und Return sie anhakt (Review 6). XCUITest `testSearchShowsFirstHitInPreviewAtOnce` ist geschrieben und kompiliert, aber noch nicht gelaufen (der Lauf wartet auf Chris).

## 2026-11-15 — 1.3.4 zusammengeführt (Branch `release-1.3.4` von main d33865c)

- **Gemergt (--no-ff):** `tile-aspect` f8e47b1 (Kacheln folgen der Seitenform, Querformat-Reihen niedriger) und `folder-counts-tab` 988a5e2 (Ordnerzahlen folgen dem Dateityp-Filter; Tab-Reihenfolge Suchfeld → Ordner → Kacheln → Vorschau mit „Tab erreicht auch das Suchfeld“/„… die Vorschau“, ersetzt `keyboard.tabSkipsSearch`).
- **Konflikte:** keine. Beide Branches basieren auf d33865c und ändern keine gemeinsame Datei; Git musste nichts zusammenführen.
- **Geprüfte Berührungen:** `keyboard.tabSkipsSearch` kommt nur noch als Migrationsschlüssel vor (`KeyboardSettings.legacyTabSkipsSearch`, Test `tabSkipsSearchMigration`). Die 1.3.3-Regel „erstes ↓ aus dem Suchfeld auf den automatisch gezeigten ersten Treffer“ (`KeyRouterApplier`, `.navigate`) ist von der neuen Tab-Logik getrennt (Tab geht über `.moveFocus`/`.focusFolderTree`); ihre Tests laufen im selben Lauf mit. Die Kachelform (`PageShapes`) ändert nur Größe und Vorabladen der Kacheln, nicht `focusedPage`.
- **Offen:** Der Vorschau-Puffer (Branch `preview-buffer`) kommt später dazu. UI-Tests, main, Tag und Installation warten auf Chris.

## 2026-11-16 — Office-Vorschau schneller, Paket 1–4 (Branch `claude/project-thread-it2vzj`)

Grundlage: interne Messnotiz, Ergebnis in docs/performance.md „office-speed“.

- **1a Deck einmal öffnen, Grenze nach Speicher:** `SlideDeckCache` öffnet je Schlüssel nur einmal; gleichzeitige Fehltreffer warten auf dieses Öffnen und bekommen dessen Deck oder Fehler (`Opening`, `DispatchGroup`; ein Wartender blockiert seinen Thread für die 20–150 ms des Öffnens). `shared` = **10 Decks und 400 MB dekodierte Bilder** (statt 2 Decks). Die Bytes zählt SlideKit neu öffentlich (`SlideDeck.cachedImageBytes` = `ImageDecoder.cachedBytes`); Text und Folienmodelle sind daneben klein und nicht gezählt. Geprüft wird bei jeder Anfrage, weil Decks beim Zeichnen wachsen; das gerade angefragte Deck bleibt immer (auch allein über der Grenze). Gemessen mit dem synthetischen Bild-Deck aus „1.3.2“ (8 Decks × 30 Folien à 3000 × 2250, 1600 px, mit Layoutlauf, Debug): **+457 MB** gegen +772 MB mit 2 Decks (1.3.2) – unter dem bisherigen Stand. Vorsichtige Wahl: 400 MB (Vorschlag war 400–600); mehr bringt im Raster-Szenario nichts, weil 7 Decks × 6 Folien bei Kachelgröße weit darunter bleiben.
- **1b Word-Dokument einmal importieren:** `DocumentLRU.value` ist Single-Flight je Schlüssel (Fehler werden geteilt, nicht gemerkt). `cacheCapacity` 4 → **16**; `cacheMaxPages` (2000) bleibt die Speicherbremse. Damit ist „Bekannte Folge (c)“ von 1.3.2 (kein Single-Flight) erledigt.
- **1c Layout leiht offene Decks:** `SlideKitLayoutSource` nimmt ein Deck, das `SlideDeckCache.shared` gerade offen hat (`openDeck`: öffnet nichts, ändert keine Reihenfolge), sonst öffnet es wie bisher eines nur für sich. Die Regel „ein Indexlauf verdrängt keine Viewer-Decks“ bleibt. Umgekehrt (Kachel nach dem Layout nutzt dessen Deck) nicht gebaut: das hätte geheißen, Layout-Decks in den Viewer-Cache zu legen.
- **2a Word-Kacheln direkt:** neue optionale Methode `ForeignPageProvider.tile(_:) -> ForeignTile?` (OutputKit, Vorgabe nil). `OfficePages` liefert sie für Word: `TextKitWordDocument.draw` direkt in die Kachel-Bitmap, Text und Wortrahmen für Markierungen lazy aus `page(i)`. `ThumbnailCache` zeichnet sie mit derselben Optik (weiße Seite, `HighlightGeometry` exakt/vergrößert, Streifen); Markierungen aus den gespeicherten Wortrahmen (`ocr`, Index) haben Vorrang, sonst die eigenen. Folien behalten `SlidePDFPage` (der PDF-Umweg kostet dort nichts); Ausgabe, Drucken und große Vorschau bleiben Vektorseiten. Die Kachelschlüssel ändern sich nicht (gleiche Optik; Kantenglättung kann minimal anders sein).
- **2b Vorrang am `textKit`-Lock:** `TextKitWordDocument.withTextKit(.display/.layout)`. Anzeigewege zählen sich vor `lock()` in einen atomaren Zähler; Layoutarbeit wartet, solange dieser > 0 ist, und gibt nach dem Erhalt sofort wieder frei, wenn inzwischen einer wartet. Das Layout (`fonts: .start`) importiert in einem Schritt, umbricht dann in Häppchen und gibt `textKit` (und das Font-Gate) zwischen zwei Seiten frei, wenn eine Kachel oder die Vorschau wartet; die `page(i)`-Aufrufe des Index laufen als `.layout`. **Reihenfolge unverändert:** Gate → `textKit` → `withStableFonts`, nie verschachtelt; zwischen den Häppchen hält das Layout nichts. Andere Word-Arbeit zwischen zwei Häppchen ist so sicher wie vorher (immer noch eine zur Zeit; die Objekte gehören je einem Dokument). Ein Display-Pfad wartet höchstens auf einen Import, ein Häppchen oder eine Seite. Test `displayGoesBeforeARunningLayout`.
- **3 Deck öffnen:** Profil bestätigt die Vermutung (A3-Profil: 798 von 854 Samples in `DeckParser.open` stehen in `PresentationInfo.swift:63`, `OOXMLNode.parse` der ganzen Folie für `show`). Jetzt liest ein `XMLParser` nur den Wurzel-Tag und bricht ab (`rootShowsHidden`); nur Folien, deren Wurzel „versteckt“ sagt, werden wie bisher ganz geparst. Ergebnis damit **identisch**, auch für nicht parsebare Folien (bleiben sichtbar, Test `unparseableSlideCountsAsVisible`). Korpus-Test `CorpusSlideListTests` vergleicht für alle 7 Decks mit dem vollständigen Parsen.
- **4 Schriften:** Der Start der Registrierung bleibt, wie er ist (beim App-Start nach früherem Erfolg, sonst mit dem ersten sichtbaren Office-Dokument bzw. Layout, wegen der macOS-Abfrage). Neu: **keine Kachel und keine Vorschau wartet mehr darauf.**
  - OOXMLKit: `FontResolver.withoutWaitingForRegistration { }` (thread-lokal). Bis die Familienliste nach der Registrierung steht (`officeFontsReady`), lösen solche Aufrufe gegen die jetzt installierten Schriften auf, auf einer eigenen seriellen Queue (die Font-Queue ist während der Registrierung belegt) und merken sich prozessweit nichts (keine Memos, Liste nur vorläufig). Danach ist alles wie vorher. Thread-lokal statt globalem Schalter, damit Tests und Layout-/Ausgabepfade unverändert warten.
  - SlideKit: `SlideDeck(…, waitsForFonts:)`. `SlideDeckCache`-Schlüssel enthält `fontsReady`; ein vorher geöffnetes Deck zeichnet ohne zu warten mit Ersatzschriften und wird danach nicht mehr benutzt. `SlideKitPages.contentVersion` hängt bis dahin `~` an (Kacheln werden danach neu gezeichnet; die `~`-Kacheln auf Platte gehören nur zu diesem Zustand und werden nie als fertig gezeigt). `makePage` (Sichern/Drucken) und `SlideKitLayoutSource` warten wie vorher (`prewarmFonts`, startet sie notfalls): Ausgabe und Wortrahmen nie mit Ersatzschriften. Große Vorschau (`pageDocument`, `previewPage`) wartet nicht.
  - Word: Kacheln (`OfficePages.tile`) mit neuem `FontRegistrationGate.Mode.skip` (gar nicht warten); `+fonts` im Schlüssel gab es schon. Vorschau und Ausgabe treten wie bisher bei (`.join`).
  - AppModel: auch ein gezeigtes SlideKit-Deck setzt das „vor den Schriften gezeigt“-Flag; nach dem Erfolg werden die Kacheln einmal neu geladen (`foreignPagesRevision`). Test umbenannt: `successAfterDecksShownReloadsTilesOnce` (vorher: kein Neuladen, weil SlideKit stattdessen blockierte).
  - Risiko, nicht gemessen: SlideKit zeichnet jetzt mit Core Text, während registriert wird (vorher blockiert). Für TextKit (Word) schützt weiter das Font-Gate; Core Text selbst gilt als threadsicher.
- **Nebenbefund (nur notiert):** Folienkacheln ohne gespeicherte Wortrahmen haben keine Markierungen, weil `SlidePDFPage` keine Textebene hat. Mit Index-Wortrahmen (`ocr`) sind sie da (Test `highlightsOnSlideTilesComeFromStoredWordBoxes`). Über `ForeignPageProvider.tile` ließe sich das nachrüsten.

## 2026-11-16 — 1.3.9: Mess-Protokoll der Indizierung (Branch `index-metrics`)

- **`IndexMetrics` (IndexKit):** JSON-Zeilen nach `~/Library/Logs/PDFSucher/index-metrics-<Datum>.jsonl` (lokales Datum; App ist nicht sandboxed). Aus = ein atomarer Ladevorgang je Aufruf, die Felder sind ein Autoclosure. An = Kodieren im Aufrufer, Puffern und Schreiben auf eigener serieller Queue (bei 32 KB oder nach 1 s; beim Beenden `flush`). Schreibfehler verwerfen den Puffer, nie blockieren. Schalter: `UserDefaults` `indexMetricsEnabled` (beim Start gelesen) und Toggle im Reiter „Speicher“.
- **Datenschutz:** Pfade nur als `hash` = erste 12 Hex-Zeichen von SHA-256 des standardisierten absoluten Pfads, plus Endung; Quellen als Hash plus `depth` (Anzahl Pfadkomponenten). Test `onWritesJSONLinesWithoutPlainPathsOrText` prüft, dass weder Datei-, Ordnername, Text noch `/Users/`/`/var/` im Protokoll stehen.
- **Lauf-ID:** jeder Schritt der AppModel-Warteschlange (Phase 1, Layout, OCR je Ordner) bekommt eine fortlaufende `run`, an den Indexer per `@TaskLocal IndexMetrics.run` durchgereicht (Task-Gruppen erben sie; OCR-Threads loggen nicht selbst). Der Auslöser (`trigger`) wird in `enqueueIndexing(_:trigger:)` gesammelt und beim nächsten Phase-1-Lauf des Ordners geschrieben (mehrere mit `+`). Layout/OCR-Läufe haben `trigger: queue`.
- **Nicht trennbar:** OCR-Render und -Erkennung (eine Methode in `OCRSource`), daher eine Dauer je Seite. `layout_file.wait_ms` = Zeit vom Start der Layoutphase bis zum Start der Datei.
- **Doppelarbeit:** `reindexed_file` nur innerhalb einer App-Sitzung (Menge im Logger); über Sitzungen hinweg erkennt das Skript dieselbe Dateiversion (Hash, Größe, Datum, Seite) mehrfach in den Logs.
- **Indexer/AppModel nehmen ein `IndexMetrics`** (Vorgabe `.shared`), damit Tests in ein Temp-Verzeichnis schreiben.

## 1.3.10 Speicher: Indexe und Caches gezielt löschen

- **Speicher-Reiter:** eine Zeile je Ding auf der Platte (Größe + Knopf, Rückfrage per `confirmationDialog`; „Index löschen“ fragt wie bisher per NSAlert der App). Kompakt statt eigener Abschnitte, damit der Reiter ohne Scrollen passt (UI-Test `testSettingsTabsFitAndSizeIsKept`, letztes Element jetzt `indexMetricsToggle`).
- **OCR „löschen“ = neu erkennen:** `resetOCR` markiert die Seiten neu; der alte Text bleibt bis zur neuen Erkennung durchsuchbar. Ein echtes Entfernen der OCR-Wörter (FTS-Tabellen) wurde bewusst nicht gebaut.
- **Verwaiste Indexe:** nur Dateien der Form `<64 hex>.sqlite[-wal|-shm|-journal]` im Index-Ordner; behalten werden geladene Quellen, gemerkte fehlende Quellen (`rememberedMissing`) und jede in diesem Prozess geöffnete `FolderIndex` (auch entfernte Quellen, deren Store noch offen ist). Nur in der echten App (`AppModel.indexDirectory`), nie in UI-Tests.
- **Mess-Protokolle löschen:** `IndexMetrics.deleteLogs()` schreibt den Puffer, schließt die offene Datei und löscht nur `index-metrics-*.jsonl`; danach beginnt (falls an) eine neue Datei.
- **Quellen-Menü:** Untermenü je Quelle statt Rechtsklick (NSMenu-Einträge haben kein eigenes Kontextmenü).

## 2026-11-16 — index-speed-1: Phase 1 schreibt entkoppelt, größte Dateien zuerst

- **Schreiber:** `BatchWriter` (Indexer.swift). Fertige Batches (`batchSize`, 50) gehen an je einen eigenen Task, der nach dem
  vorigen schreibt (Reihenfolge bleibt, ein Schreiber zur Zeit). Höchstens `writesInFlight` = 2 Batches warten oder werden
  geschrieben; ein weiterer wartet in `submit` (Gegendruck, gemessen als `writer_wait_ms` in `phase_end`). Speicher damit
  höchstens ≈ 3 Batches + laufende Extraktionen. Die Ergebnisschleife startet währenddessen neue Extraktionen.
- **Semantik erhalten:** Jeder Weg aus `run` wartet alle Schreib-Tasks ab (`drain`), damit kein Schreiben einen Lauf
  überlebt (sonst schriebe er nach einem Wipe/Neustart, `resetCount`). Abbruch: offene Datei-Ergebnisse gehen noch in den
  Schreiber, dann `drain`, Fehler nur geloggt, wie vorher. Ein fehlgeschlagener Batch lässt alle späteren ungeschrieben
  (verkettete Tasks); der Lauf wirft den ersten Fehler. Unterschied: ein Schreibfehler fällt erst beim nächsten
  `submit`/`drain` auf, nicht sofort; Fortschritt kommt weiter je Datei, ein Batch ist ggf. einen Batch später durchsuchbar.
- **Reihenfolge:** Arbeitsliste nach Dateigröße absteigend, Gleichstand nach Pfad (`sortForExtraction`). Kein Test erwartete
  die Scan-Reihenfolge. Folge: das erste Batch (frühe Treffer) besteht aus großen Dateien und kommt etwas später.
- **Tests:** `IndexerWriterTests` (Reihenfolge, Gegendruck, Fehler stoppt Spätere, Größe zuerst, Abbruch während des Schreibens
  speichert alles Gemeldete und danach schreibt nichts mehr — schlägt ohne `drain` fehl, geprüft).
- Zahlen in docs/performance.md „index-speed-1“.

## 2026-11-16 — 1.3.11 (Build 19): storage-cleanup + index-speed-1 zusammengeführt (Branch `release-1.3.11`)

- Ab `storage-cleanup` (26db6c2, 1.3.10/18, installiert gewesen), `index-speed-1` (c938766) mit --no-ff gemergt. Code ohne
  Konflikt (IndexStore.swift automatisch). Konflikte nur in decisions.md (beide Einträge behalten) und
  release-notes-1.3.10.md (Stand von storage-cleanup behalten, denn so wurde 1.3.10 installiert; die Geschwindigkeit steht in
  release-notes-1.3.11.md). Die Speed-Einträge oben, die „1.3.10“ nennen, meinen den nie installierten Stand des Branches.

## 2026-11-16 — 1.3.12: Wortteil-Index (Trigramm) im Hintergrund nach Phase 1 (Branch `index-speed-2`)

- **Schema 4** (`IndexStore`): Tabelle `trigram_pending(page_id)`. Invariante: jede Seite steht in genau einem von
  `pages_trigram` und `trigram_pending`. Trigger: Einfügen mit `source = 'text'` (Phase 1) → nur Wort-Index + wartend; andere
  Quellen (`layout`) → beide Indizes sofort. Löschen: Trigramm-'delete' nur, wenn die Seite nicht wartet (ein 'delete' mit
  nie indiziertem Text würde den externen-Inhalt-Index beschädigen), Wartezeile weg. Textänderung (OCR): eine indizierte
  Seite wird sofort nachgeführt, eine wartende bleibt wartend und wird später mit dem aktuellen Text übertragen.
- **Migration 3 → 4** in einer Transaktion (Tabelle anlegen, Trigger tauschen, Version setzen): alle Seiten eines 3er-Index sind
  schon im Trigramm-Index, nichts wird neu indiziert. Andere Versionen weiter: Neuaufbau wie bisher.
- **Aufbau:** `IndexStore.fillTrigramIndex(maxPages:)` überträgt ganze Dokumente in Id-Reihenfolge (≈ `Indexer.wordPartsBatch`
  = 1000 Seiten, ≈ 0,3 s je Transaktion), damit ein Dokument nie halb indiziert ist (die Suche braucht zusammenhängende Seiten
  je Dokument). `Indexer.buildWordParts` nimmt den Zug wie die anderen Phasen, prüft vor jeder Transaktion auf Abbruch.
- **Suche ohne Lücken:** `matchBatches`/`match` auf `.trigram` liefern zusätzlich alle wartenden Seiten als Kandidaten
  (Bewertung 0), in einer Lesetransaktion mit der FTS-Abfrage (eine in der Zwischenzeit übertragene Seite steht so in genau
  einem Teil). `PageMatcher` prüft wie immer jede Kandidatenseite; Wort- und Präfixsuche unverändert. Folge: `match(.trigram)`
  ist eine Obermenge, solange Seiten warten (Tests, die genaue Trigramm-Treffer erwarten, füllen den Index vorher). FTS5s
  `integrity-check` mit `rank = 1` meldet bei wartenden Seiten „malformed“ (Inhaltstabelle hat mehr Zeilen); kein
  Produktionscode ruft ihn auf, die Tests prüfen nach dem Füllen.
- **Warteschlange (AppModel):** `wordPartsPending` nach jedem erfolgreichen Phase-1-Lauf. Reihenfolge: Phase 1 aller Ordner →
  Einzeldateien (Layout/OCR, klein und gewünscht) → Wortteil-Index → Ordner-Layout → Ordner-OCR. Neues Phase-1-Material und neue
  Einzeldateien unterbrechen ihn (`preemptWordParts`, Mess-Protokoll `preempt`), er setzt fort. Während eines Folien-Cache-Jobs
  läuft er ebenfalls (nur Layout wartet). Ein Fehler (außer Schaden → Neuaufbau) wird nur geloggt: die Suche bleibt korrekt,
  der nächste Phase-1-Lauf stellt ihn wieder an.
- **Sichtbar:** `IndexStatus.preparingWordParts` → „Wortteil-Suche wird vorbereitet … (x %)“ (x = Anteil dieses Schritts);
  hinter der Trefferzahl einer Suche mit Trigramm-Plan „Wortteil-Suche kann gerade langsamer sein“, solange ein geladener Ordner
  wartet oder gerade aufgebaut wird.
- **Tests:** `WordPartsIndexTests` (IndexKit: Warten/Übertragen, Kandidaten, Änderungen an wartenden und indizierten Seiten inkl.
  OCR und Layout, ganze Dokumente, Migration 3 → 4, Abbruch/Fortsetzen), `WordPartsSearchTests` (SearchKit: gleiche Treffer bei
  leerem, halbem und vollem Trigramm-Index, auch mit frühen Treffern; schlägt ohne die Kandidaten fehl, geprüft),
  `WordPartsQueueTests` (AppCore: Reihenfolge, Unterbrechung, Status, Hinweis). Angepasst: `IndexStoreTests`
  (`trigramFindsInfix`, `upsertReplacesPages`, `expectFTSIntact` füllen zuerst), `IndexStoreOCRTests` (Schema 4,
  `rerunWithDifferentTextReplacesOldText` füllt zuerst).

## 2026-11-16 — 1.4.0 (Build 21): Pakete P1–P7 (Branch `release-1.4.0` ab `index-speed-2`)

- **P1 Kind-Indizes übernehmen** (`IndexStore+Import`): Beim ersten `update` einer `FolderIndex`-Instanz (im Indexer-Zug, vor Phase 1)
  werden Index-Dateien im selben Ordner gesucht, deren `meta.folder_path` unter der Wurzel liegt (Schema 3–5), flachste zuerst. Per
  ATTACH in einer Transaktion: Dokumente, die der Eltern-Index nicht hat (Pfad mit Präfix, NFC), mit Seiten (`source`, `needs_ocr`),
  OCR-Wortrahmen, Renderer/Version/`needs_layout`, Größe/Datum. Seiten kommen über die Trigger an (Text-Seiten warten auf den
  Trigramm-Index). Layout-Renderer je Art: hat der Eltern-Index keinen Eintrag, übernimmt er den des Kindes; weicht er ab, kommen
  dessen Word/PowerPoint-Dokumente ohne Seiten und warten auf Layout. `meta imported:<datei>` verhindert eine zweite Übernahme
  (sonst kämen gelöschte Dateien aus dem verwaisten Kind-Index jede Sitzung zurück). Der Kind-Index bleibt liegen und ist damit
  „verwaist“ (Speicher-Reiter). Fehler: nur Log, Phase 1 liest dann eben. Mess-Protokoll `source_import`.
- **P2 Orte sofort:** `requestAdd(_:fromPlace:)`: bei „Fragen“ fügt ein Klick auf einen Ort ohne Rückfrage hinzu; „Ersetzen“ und
  „Zusätzlich“ unverändert, Drops/⌘O fragen weiter. Begründung: Ein Ort-Klick heißt eindeutig „diesen dazu“, die Frage war für
  Drops gedacht (hinzufügen oder ersetzen); Chris' Wunsch „sofort loslegen“. Tests `placeOutsideLoadsAtOnceAndFilters` (vorher
  `placeOutsideAsksThenLoadsAndFilters`) und `cancelledDropChangesNothing` (vorher `cancelledPlaceChangesNothing`) bewusst angepasst.
  **Vorrang nach Filter:** `FolderIndexing.setPriority` mit den relativen Pfaden der gewählten Ordner je Quelle; Layout und OCR
  nehmen ihre nächste Aufgabe aus `PreferredOrder` (neu sortiert nur, wenn sich der Filter ändert), der Wortteil-Index füllt
  ganze Dokumente unter den Präfixen zuerst (`fillTrigramIndex(preferring:)`). Laufende Arbeit wird dafür nicht abgebrochen.
- **P3 Plattenänderungen:** `EventFilter.changedScopes` liefert je Quelle die Elternordner der geänderten Einträge (geschachtelte
  zusammengefasst); verlorene Ereignisse, Wurzeländerung oder ein Eintrag direkt in der Wurzel → voller Scan. AppModel sammelt die
  Ordner (`diskScopes`) bis zum Lauf; nur wenn der Lauf ausschließlich wegen Plattenänderungen kommt, ist er begrenzt
  (`needsFullScan` bei jedem anderen Auslöser, Schaden, Abbruch oder Fehler eines begrenzten Laufs). `Indexer.update(scopes:)`
  scannt nur diese Ordner mit derselben Tiefengrenze (`FolderScanner.scoped(depth:)`), vergleicht nur Dokumente darunter; ein
  verschwundener Ordner (Wurzel vorhanden) entfernt seine Dokumente; ein Neustart nach Wipe scannt voll. Layout bei Plattenänderung:
  `stopLayoutGently` (Zähler im `PriorityBox`): kein weiterer Start, laufende Dateien werden fertig und gespeichert, dann
  `CancellationError` (Ordner vorn in `layoutPending`). OCR verlor schon vorher nichts (laufende Seiten werden gespeichert).
- **P4 Verschoben/umbenannt** (Schema 5): `documents.file_id` = Volume-UUID/Datei-ID (`fileIdentifierKey`, Volume je Ordner,
  bei Links das des Ziels). Neue Datei mit gleicher Identität, Größe, Datum (±1 ms) und Art wie ein im selben Lauf verschwundenes
  Dokument → `IndexStore.move` (Pfad ändern, alles bleibt). Mehrfach vorkommende Identität (Hardlinks), fehlende Identität,
  andere Art, andere Größe/Datum → neu lesen. Migration 3/4 → 5 in place (Spalte nur anlegen, wenn sie fehlt); alte Dokumente
  bekommen ihre Identität beim nächsten Scan (`setFileIDs`, ohne Lesen). Rückweg: 1.3.x erkennt Schema 5 nicht und baut neu auf.
- **P5 Word vorläufig:** `WordPreviewText` (OfficeKit) liest `w:t`/`w:p`/`w:br`/`w:tab` des Hauptteils (ohne gelöschte
  Revisionen, Kopf/Fuß/Fußnoten), normalisiert. Phase 1 speichert ihn als eine Seite (Index 0), Status ok, `needs_layout = 1`,
  `page_count = 0` (Regel im Store: wartend = Seitenzahl unbekannt; das Raster zeigt dann nur Trefferseiten bzw. „wird
  vorbereitet“, `RowPages` deckt das ab), ohne Wortrahmen (`ocrPage` liefert nil → keine falschen Markierungen). Das Layout
  löscht und ersetzt die Seiten. .doc und PowerPoint wie bisher. **Nicht gemacht:** Word-Layout selbst beschleunigen
  (Wortrahmen nur für sichtbare Seiten): Index-Markierungen und Seitentreffer brauchen die Wortrahmen aller Seiten; nicht sicher.
- **P6 langsame PDFs** (`SlowPDFProfile`, opt-in): die 10 langsamsten aus Chris' Protokoll (lokal per Hash zugeordnet): 85–95 %
  der Zeit in `PDFPage.string` (PDFKit), Normalisierung 3–11 %, Öffnen < 1 %; Ursache viele Seiten/viel Text (mehrere tausend Seiten,
  Millionen Zeichen) bzw. teure Einzelseiten (bis 228 ms). Zwei der zehn sind Dubletten (gleiche Datei an zwei Orten). Keine
  sichere Verbesserung umgesetzt; die Normalisierung zu ändern lohnt die Gefahr für die Markierungs-Zuordnung nicht.
- **P7 OCR:** `Indexer.ocrParallelism` = Kerne/4, 2…4 (`OCRParallelismBenchmark`, opt-in). dpi, Genauigkeit unverändert, Text in
  allen Stufen identisch. Tests `atMostOCRParallelismAtOnce`, `wipeDuringOCRStopsAndStartsOver` (12 statt 6 Bilder, damit er bei 4
  parallel noch etwas prüft) angepasst.

## 2026-11-17 — PDF-Dubletten in Phase 1 (Branch `pdf-dubletten` ab `release-1.4.0` 51b0def)

- **Befund** (Mess-Protokoll 16.11., echter Ordner): rund 20 % der PDFs sind byte-gleiche Kopien (SHA-256), meist paarweise,
  einzelne mehrfach; sie kosten 88,7 s von 452 s PDF-Lesezeit (19,6 %). Phase 1 ist durch PDFKit begrenzt.
- **Umsetzung** (`DuplicateFinder.swift`, `Indexer.run`): nach dem Diff (und nach P4 „verschoben“) werden unter den zu lesenden
  PDFs (neu/geändert, nur `kind == .pdf`) die nach Größe gruppiert; nur Gruppen mit > 1 Datei werden per SHA-256 (CryptoKit,
  1-MiB-Blöcke) gehasht, so parallel wie die Extraktion, abbrechbar. Gleiche Größe + gleicher Hash → die erste in der
  Arbeitsreihenfolge (größte zuerst, dann Pfad) ist die Leit-Datei und wird normal über die `TextSource` gelesen; die Kopien
  verlassen die Arbeitsliste. Kommt das Leit-Ergebnis, bekommt jede Kopie dieselben Seiten und denselben Status (ok, noText,
  error, `needsOCR`-Seiten) mit ihrem eigenen `ScannedFile`. Eine Datei, die sich nicht hashen lässt, wird normal gelesen.
- **Begründung:** gleiche Bytes → gleiches PDFKit-Ergebnis, also gleiche Seiten und Markierungen. Keine Schemaänderung.
- **Semantik:** Leit-Datei und Kopien gehen gemeinsam in `pending`, danach erst die Abbruchprüfung: ein Abbruch speichert nie
  eine Kopie ohne ihre Leit-Datei; wird die Leit-Datei selbst abgebrochen, wird keine der beiden gespeichert und der nächste
  Lauf holt beide nach. Fortschritt: weiter ein Wert je fertiger Datei, auch für Kopien (`total` enthält sie), Kopien direkt
  nach ihrer Leit-Datei. Batches können um die Kopien einer Leit-Datei größer als `batchSize` werden. Wipe-Neustart hasht neu.
  Das Hashen läuft nach dem Fortschrittswert `(0, total)` und vor der ersten Extraktion (gemessen 0,5–1,0 s).
- **Mess-Protokoll:** Kopien als `file` mit `ms` 0 und `"dedup": true`; `phase_end` (text) mit `hash_ms`, `hashed`, `dedup`.
  `scripts/index-metrics-report.py` zeigt sie unter „Doppelarbeit“.
- **Tests:** `DuplicatePDFTests` (zählende Spy-Quelle: zwei Kopien in verschiedenen Ordnern → 1× gelesen, beide gespeichert und
  suchbar; gleiche Größe, anderer Inhalt → 2×; unlesbare Kopien → beide error, 1×; Abbruch während die Leit-Datei liest → nichts
  gespeichert, nächster Lauf holt beide nach; Fortschritt zählt alle; Mess-Protokoll). Alle sechs vor der Umsetzung rot.
  Angepasst: vier `IndexerTests` (`indexerCancels`, `concurrentUpdatesRunOneAfterAnother`, `cancelledWaitingUpdateStopsAtOnce`
  und der Wipe-Test) legten 5–40 byte-gleiche Dateien „x“ an, während ihre Fake-Quelle je Dateiname anderen Text liefert; sie
  bekommen jetzt je Datei eigenen Inhalt („x0“, „x1“ …), die geprüfte Absicht bleibt.
- **Nicht in v1 (nächste Schritte):** Dubletten gegen schon gespeicherte Dokumente früherer Läufe (bräuchte eine Hash-Spalte,
  Schemaänderung); OCR-Ergebnisse auf Kopien übertragen (Kopien warten jede für sich auf Phase 2); Word, PowerPoint und Bilder.
  Messwerte in docs/performance.md „PDF-Dubletten“.

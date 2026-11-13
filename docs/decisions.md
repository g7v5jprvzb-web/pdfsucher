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

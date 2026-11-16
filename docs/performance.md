# Performance (Task 1.4)

Measured 2026-11-12 on Chris' Mac (16 cores, macOS 26), **debug build** (`swift test`),
system SQLite 3.51.0. Test: `IndexKitTests/PerformanceTests.perfThousandDocs`.

```
PDFSUCHER_PERF=1 swift test --package-path Packages/PDFSucherKit --filter perfThousandDocs
```

Corpus: 1,000 PDFs × 20 pages in 20 subfolders plus one 2,000-page PDF (22,000 pages).
Each page has 120 words in 15 source lines, which wrap to about 21 rendered lines on average
(27 max in a 2,000-page sample; 30 in the generator's worst-case guard test), well under the
~49 lines a fixture page holds. Words are drawn
from a fixed list of 2,000 German-like words built from 40 syllables, seed 42.

| Measurement | Value | Target (spec §9) |
|---|---|---|
| Generate corpus | 33.1 s | – |
| First index | 17.3 s | as fast as possible, reported |
| Re-index, no changes | 0.04 s | < 5 s ✔ |
| Query median (20 queries; first run: upper middle of 20) | 10.0 ms | < 200 ms ✔ |
| Query max | 184.7 ms | – |
| Pages per query (min / upper middle / max) | 1,241 / 1,341 / 20,906 | – |
| Index file (main file, without `-wal`) | 107 MB | – |

Per query (`match` only: FTS5 lookup plus reading the page texts; SearchKit's regex check and
sorting come on top):

| Query | Index | Time | Pages |
|---|---|---|---|
| 10 whole words | words | 6–9 ms | ~1,250–1,340 |
| `"zahl"*`, `"ertr"*` | words (prefix) | 11–12 ms | 1,300–2,400 |
| `"tenb"*`, `"toha"*` | words (prefix) | 38–62 ms | 5,700–7,600 |
| `"nung"*` | words (prefix) | 185 ms | 20,906 (95 % of all pages) |
| 5 four-letter infixes | trigram | 73–123 ms | 8,400–16,800 |

Notes:
- Query time grows with the number of matching pages, because every match returns the page
  text. The syllable-built corpus is harsh for infix and prefix queries (common syllables hit
  most pages); real documents should match fewer pages per term.
- Spec §9 measures until the hit list is shown; this test times only the index lookup.
  SearchKit's PageMatcher and sorting come on top, so Phase 5 should measure end to end:
  broad prefix queries such as `nung*` (185 ms here for the lookup alone) will exceed 200 ms,
  while the median target is comfortably met.
- Only the two spec targets are asserted (re-index < 5 s, median < 200 ms). Release builds
  will be faster; numbers above are a conservative upper bound.

Second run after the Task 1.3 review fixes (separate reader connection, `cores - 1` extraction
tasks), same machine and corpus: first index 17.9 s, re-index 0.04 s, query median 5.5 ms,
max 116.8 ms. Run-to-run variation of the per-query times is large; both runs meet the targets.

## Phase 5: release build and end to end (Task 5.5)

Measured 2026-11-12 on Chris' Mac (Apple M3 Max, 16 cores, 64 GB, macOS 26), **release build**,
same corpus (1,000 PDFs × 20 pages + one 2,000-page PDF = 22,000 pages, seed 42).

```
PDFSUCHER_PERF=1 swift test -c release --no-parallel --package-path Packages/PDFSucherKit --filter perfThousandDocs
PDFSUCHER_BENCH=1 swift test -c release --no-parallel --package-path Packages/PDFSucherKit --filter SearchBenchmark
PDFSUCHER_E2E=1 swift test -c release --no-parallel --package-path Packages/PDFSucherKit --filter EndToEndPerformance
```

### Index (IndexKit, release)

| Measurement | Value | Target (spec §9) |
|---|---|---|
| First index (1,001 PDFs, 22,000 pages) | 9.6 s | as fast as possible, reported |
| Re-index, no changes | 0.03 s | < 5 s ✔ |
| Index lookup median (20 queries) | 4.1 ms | – |
| Index lookup max (`"nung"*`, 20,906 pages) | 94.8 ms | – |
| Index file | 107 MB | – |

### End to end: input → hit list (AppModel, release)

Measured from setting the search text (debounce 0) until `AppModel.hits` is published on the main
actor: index lookup, PageMatcher check and count of every candidate page, grouping, sorting.
Median and maximum of 5 runs. **Not included:** SwiftUI drawing of the grid and thumbnails. The last
two columns add the typing delay, i.e. the time from the last keystroke: **50 ms (default since
Chris' decision in Task 5.5)** or 150 ms (choosable in the settings, „Wartezeit nach dem Tippen“).
Second run, 2026-11-12 19:05 UTC, same machine and corpus.

| Input | Documents | Pages | Median | Max | + 50 ms (default) | + 150 ms |
|---|---|---|---|---|---|---|
| `nungtepreistrag` (word) | 698 | 1,279 | 10 ms | 13 ms | 60 ms | 160 ms |
| `satzpreis beginn` (two words) | 64 | 72 | 3 ms | 3 ms | 53 ms | 153 ms |
| `nung*` (broad prefix) | 1,001 | 20,906 | 124 ms | 126 ms | **174 ms** | 274 ms |
| `ver*` (broad prefix) | 1,001 | 20,315 | 122 ms | 128 ms | **172 ms** | 272 ms |
| `ferb*` | 991 | 4,759 | 29 ms | 30 ms | 79 ms | 179 ms |
| `*trag*` (broad infix) | 1,001 | 21,998 | 134 ms | 138 ms | **184 ms** | 284 ms |
| `*eber` (suffix) | 905 | 2,500 | 29 ms | 29 ms | 79 ms | 179 ms |
| `"leum umbanksteuum"` (phrase) | 2 | 2 | 1 ms | 2 ms | 51 ms | 151 ms |
| `*ab*` (short infix → full scan) | 0 | 0 | 51 ms | 52 ms | 101 ms | 201 ms |
| `gibtsnicht` (no hit) | 0 | 0 | 0 ms | 0 ms | 50 ms | 150 ms |

First index through `AppModel.open(folder:)`: 9.6 s. (First run, with 150 ms delay only: same values
within ±12 ms.)

SearchBenchmark (SearchKit only, every one of 20,000 pages a candidate, release): 57–70 ms for
words, prefixes and infixes; 152 ms for the phrase `"die Lieferung"`.

### Assessment against spec §9 („< 200 ms bis zur Trefferliste“)

- The search itself (input → hit list) stays below 200 ms for every measured input; the worst
  median is 134 ms (`*trag*`, every page of the corpus a hit).
- **With the default 50 ms typing delay, every measured input reaches the hit list within 200 ms
  of the last keystroke** (worst median 184 ms, `*trag*`; the full-scan `*ab*` 101 ms). Drawing the
  grid is not included.
- With 150 ms chosen in the settings, broad queries (`nung*`, `ver*`, `*trag*`) take 272–284 ms and
  `*ab*` 201 ms; narrow queries 150–180 ms.
- The broad queries are extreme in this syllable corpus (95–100 % of all pages match); real
  documents should match far fewer pages per term.

## Version 1.1: three folders à 1,000 PDFs (spec 1.1 §5)

`PDFSUCHER_E2E=1 scripts/test.sh -c release --filter searchEndToEndThreeFolders` (2026-11-12, 16 cores):
3 sources × 1,000 PDFs × 20 pages = 60,000 pages, one index per folder, indexed one after another
(32.7 s in total), searched in parallel and merged; measured from `queryText` set (delay 0) to the hit
list published; „+ 50 ms“ adds the default typing delay.

| Eingabe | Dokumente | Seiten | Median | Max (5 Läufe) | + 50 ms (Standard) |
|---|---|---|---|---|---|
| `verhausgeb` (word) | 2,088 | 3,448 | 21 ms | 22 ms | **71 ms** |
| `depreis botplanhaus` (two words) | 181 | 188 | 4 ms | 5 ms | **54 ms** |
| `nung*` (broad prefix) | 3,000 | 56,184 | 216 ms | 228 ms | **266 ms** |
| `ver*` (broad prefix) | 3,000 | 56,804 | 206 ms | 222 ms | **256 ms** |
| `arto*` (prefix) | 2,092 | 3,517 | 21 ms | 22 ms | **71 ms** |
| `*trag*` (broad infix) | 3,000 | 59,996 | 239 ms | 254 ms | **289 ms** |
| `*haus` (broad suffix) | 3,000 | 58,769 | 251 ms | 261 ms | **301 ms** |
| `"fristhaus anlungtebeit"` (phrase) | 2 | 2 | 2 ms | 3 ms | **52 ms** |
| `*ab*` (short part, full scan) | 0 | 0 | 95 ms | 115 ms | **145 ms** |
| `gibtsnicht` | 0 | 0 | 1 ms | 1 ms | **51 ms** |

**Assessment (honest):** with three times the 1.0 test corpus, every query that matches a normal share of the
pages stays far below 200 ms (51–145 ms incl. the 50 ms delay). Queries that hit **almost every page of all
3,000 documents** (`nung*`, `ver*`, `*trag*`, `*haus`: 56,000–60,000 hit pages) take 206–251 ms for the search
alone, **256–301 ms from the last keystroke**, so they miss the 200 ms target. The time grows linearly with the
number of hit pages (1.0: 1,000 documents, 172–184 ms): each candidate page is checked and counted by the
matcher. „Suche läuft…“ appears for these after 200 ms.

### 1.1 after „early results“ (coordinator: first rows < 200 ms also for very broad searches)

Same corpus and command, after streaming the FTS matches in batches, showing the documents of the first
3,000 candidate pages of each source after 100 ms, and sorting off the main actor
(2026-11-12, release, 16 cores). Times from the last keystroke incl. the 50 ms typing delay, median of 5:

| Eingabe | Dokumente | Seiten | erste Reihen | vollständige Liste | Max vollständig |
|---|---|---|---|---|---|
| `verhausgeb` | 2,088 | 3,448 | 72 ms | 72 ms | 73 ms |
| `depreis botplanhaus` | 181 | 188 | 55 ms | 55 ms | 55 ms |
| `nung*` | 3,000 | 56,184 | **160 ms** | 190 ms | 197 ms |
| `ver*` | 3,000 | 56,804 | **160 ms** | 188 ms | 192 ms |
| `arto*` | 2,092 | 3,517 | 74 ms | 74 ms | 74 ms |
| `*trag*` | 3,000 | 59,996 | **156 ms** | 220 ms | 224 ms |
| `*haus` | 3,000 | 58,769 | **158 ms** | 218 ms | 221 ms |
| `"fristhaus anlungtebeit"` | 2 | 2 | 52 ms | 52 ms | 53 ms |
| `*ab*` (full scan) | 0 | 0 | 146 ms | 146 ms | 160 ms |
| `gibtsnicht` | 0 | 0 | 52 ms | 52 ms | 53 ms |

**Assessment:** the first rows now appear within 200 ms of the last keystroke for every measured input
(worst 160 ms). The complete, finally sorted list of a search that hits almost all 60,000 pages takes
188–220 ms (before: 256–301 ms); the order changes once when it arrives, selection and focus stay.

Run after the review fixes (early results retried per batch; full scans stream too; `*er*` added),
2026-11-12, same setup:

| Eingabe | Dokumente | Seiten | erste Reihen | vollständige Liste | Max vollständig |
|---|---|---|---|---|---|
| `verhausgeb` | 2,088 | 3,448 | 73 ms | 73 ms | 74 ms |
| `depreis botplanhaus` | 181 | 188 | 55 ms | 55 ms | 55 ms |
| `nung*` | 3,000 | 56,184 | **159 ms** | 200 ms | 202 ms |
| `ver*` | 3,000 | 56,804 | **162 ms** | 199 ms | 204 ms |
| `arto*` | 2,092 | 3,517 | 74 ms | 74 ms | 74 ms |
| `*trag*` | 3,000 | 59,996 | **156 ms** | 227 ms | 237 ms |
| `*haus` | 3,000 | 58,769 | **156 ms** | 238 ms | 246 ms |
| `"fristhaus anlungtebeit"` | 2 | 2 | 53 ms | 53 ms | 53 ms |
| `*ab*` (full scan, no hit) | 0 | 0 | 135 ms | 135 ms | 186 ms |
| `*er*` (full scan) | 3,000 | 60,000 | **158 ms** | 164 ms | 179 ms |
| `gibtsnicht` | 0 | 0 | 52 ms | 52 ms | 52 ms |

First rows ≤ 162 ms for every input. The complete list of the broadest searches takes 199–238 ms (run-to-run
spread ±20 ms; checking each early batch now waits until it has a hit, which costs a little on the final list).


# Texterkennung (1.2, Paket O1, Task 6)

Gemessen 2026-11-12 auf Chris' Mac (Apple M3 Max, 16 Kerne, macOS 26), Debug-Build (`swift test`;
die Erkennung selbst läuft in Vision und hängt davon kaum ab). Test:
`OCRKitTests/OCRThroughputTests.perfOCRThroughput`, nur Phase 2 (`recognizePending`), höchstens 2
Erkennungen gleichzeitig, de-DE + en-US, genau, Sprachkorrektur an.

```
PDFSUCHER_PERF=1 scripts/test.sh --filter perfOCRThroughput
```

Korpus (erzeugt, Seed 42): 100 Scan-Seiten = 10 PDFs × 10 A4-Seiten, jede nur ein Bild mit
28 Zeilen × 7 deutschen Wörtern (46 px Schrift), gerendert mit 300 dpi (2480 × 3508 px);
100 Fotos = 3024 × 4032 JPEG (12 MP) mit 14 Zeilen × 5 Wörtern (90 px) und 400 grauen Flecken.
Auf jeder Seite steht ein „Markierungswort“; gezählt wird, wo die Suche es danach findet.

| Korpus | Seiten | Zeit | Seiten/Minute | Markierungswort gefunden |
|---|---|---|---|---|
| Scan-Seiten, QoS `.utility` (gewählt) | 100 | 37,3 s | 161 | 100 / 100 |
| Fotos, QoS `.utility` (gewählt) | 100 | 20,7 s | 290 | 100 / 100 |
| Scan-Seiten, QoS `.background` | 100 | 161,4 s | 37 | 100 / 100 |
| Fotos, QoS `.background` | 100 | 83,7 s | 72 | 100 / 100 |

Ehrliche Einordnung: Die Testbilder sind sauber gerenderte Schrift (die Flecken ändern daran
wenig). Echte Scans und Handyfotos (Schräglage, Unschärfe, kleine Schrift) werden langsamer und
weniger vollständig erkannt (Spec R2). Hochgerechnet: 3.400 Scan-Seiten ≈ 21 min. Das PDF wird
pro Seite neu geöffnet; das ist in den Zahlen oben enthalten.

# Suche und Hauptthread mit Texterkennung (1.2, Integration Task 7, §9)

Gemessen 2026-11-12 auf Chris' Mac (Apple M3 Max, 16 Kerne, macOS 26), Release-Build:

```
PDFSUCHER_E2E=1 scripts/test.sh -c release --filter searchAndResponsivenessWithOCR
```

Korpus (erzeugt): 1.000 Text-PDFs × 20 Seiten + 20 Scan-PDFs × 10 Seiten (nur Bild) + 100 Fotos
(2000 × 1500 px). Ein Ordner, echter `FolderIndex` mit `VisionOCRSource`, echtes `AppModel`
(Phase 1, dann Phase 2 im Hintergrund).

- Hinzufügen bis „aktuell“: 53,5 s, davon Texterkennung 44,3 s; erkannt 200 Seiten und 100 Bilder.
- Hauptthread während der Erkennung (Ticker alle 10 ms auf dem Main Actor, 3.792 Ticks):
  **längste Verzögerung 8 ms**. Grenze im Test: 100 ms; Ziel aus dem Plan: < 50 ms.
- Suche nach der Erkennung, Median aus 5 Läufen, + 50 ms Eingabepause:

| Eingabe | Dokumente | Seiten | erste Reihen (+50 ms) | vollständig (+50 ms) |
|---|---|---|---|---|
| `scanseite` (nur Scans) | 20 | 200 | 53 ms | 53 ms |
| `fotobeleg` (nur Fotos) | 100 | 100 | 53 ms | 53 ms |
| `prüfvermerk quittung` (kein Treffer) | 0 | 0 | 52 ms | 52 ms |
| Wort | 730 | 1.198 | 63 ms | 63 ms |
| `beit*` | 1.072 | 18.967 | 141 ms | 141 ms |
| `*satz` | 1.079 | 19.642 | 138 ms | 138 ms |
| `ver*` | 1.049 | 19.358 | 140 ms | 140 ms |

Alle Eingaben bleiben unter 200 ms. Die OCR-Seiten liegen in derselben FTS5-Tabelle wie
Textseiten, deshalb ändert sich die Suchzeit nur mit der Zahl der Treffer-Seiten. Der
OCR-Durchsatz selbst steht oben (Paket O1) und wurde nicht neu gemessen.

## Dauertest: anhalten, Neustart, fortsetzen (1.2)

`PDFSUCHER_E2E=1 scripts/test.sh -c release --filter ocrEnduranceStopRestart` (2026-11-13, M3 Max, Release):
50 Text-PDFs, 20 Scan-PDFs × 10 Seiten, 200 Fotos; echtes `AppModel`, echte `FolderIndex`-Instanzen,
Vision. Ein „Neustart“ ist ein neues `AppModel` mit einer neuen `FolderIndex`-Instanz auf derselben Indexdatei.

- Start 1: Nach 11,8 s ✕ gedrückt, bei 0 Seiten und 103 Bildern. Danach startet nichts neu; alle fertigen Seiten sind auffindbar.
- Start 2: Die Erkennung läuft von selbst weiter. Der Rest ist nach 25,8 s fertig, dann sind 200 Seiten und 200 Bilder erkannt; alle Suchen finden die richtige Anzahl.
- Start 3: Der Index ist nach 0,1 s aktuell, es wird nichts erneut erkannt.
- Speicher (phys_footprint des Testprozesses): 11 MB → 242 MB nach der vollen Erkennung → 242 MB am Ende. Der Wert wächst beim dritten Start nicht weiter.
- Speicherlecks: `PDFSUCHER_E2E=1 PDFSUCHER_LEAKS=1 MallocStackLogging=lite scripts/test.sh -c release --filter ocrEnduranceStopRestart`
  ruft am Ende `/usr/bin/leaks` auf den eigenen Prozess auf. Ergebnis 2026-11-13: **0 leaks for 0 total leaked
  bytes**. Drei `AppModel`-Generationen und Vision-Läufe hinterlassen keine unerreichbaren Objekte, also auch keine
  Retain-Zyklen. (`leaks --atExit` geht mit dem Test-Helper nicht: SIP entfernt `DYLD_FRAMEWORK_PATH`.)

## 1.2.3: Kacheln beim schnellen Scrollen

Gemessen 2026-11-13 auf Chris' Mac (M3 Max, 16 Kerne), Release. Kachel 200×283 pt, Retina, 6 Spalten × 3 Reihen sichtbar.
Dateien: ein Heft (Vektor), ein Prospekt, eine Unterrichtssammlung (Flate-Scan), ein Magazin-Scan (JPEG 2000).

```
PDFSUCHER_TILES=/a.pdf:/b.pdf swift test -c release --no-parallel --filter TileScrollBenchmark
```

| Messung | 1.2.1 | 1.2.3 |
|---|---|---|
| Magazin-Scan, eine Kachel | 235 ms | 49 ms (schneller Weg über ImageIO) |
| Schnelles Scrollen (1 Reihe / 16 ms): letzte sichtbare Kachel nach dem Anhalten | 3 975 ms | 156 ms |
| Scrollen 1 Reihe / 50 ms | 3 894 ms | 25 ms (mit Vorausladen) |
| Scrollen 1 Reihe / 150 ms | 3 950 ms | 0 ms (mit Vorausladen) |
| Dasselbe noch einmal aus dem Platten-Cache (z. B. nach Neustart) | – | 17–38 ms |

In der App (`-uiTestAutoScrollMS`, 33 PDFs, kleines Fenster mit 5 sichtbaren Kacheln, Platten-Cache leer):

| Schritt | 1.2.1 letzte Kachel nach Anhalten | 1.2.3 | 1.2.1 Wartezeit p90 | 1.2.3 |
|---|---|---|---|---|
| 20 ms | 689 ms | 178 ms | 698 ms | 39 ms |
| 60 ms | 569 ms | 159 ms | 44 ms | 38 ms |
| 300 ms | 323 ms | 0 ms | 244 ms | 43 ms |

## 1.2.4: Kacheln, Speicher und Platten-Rückstand beim schnellen Scrollen

```
PDFSUCHER_TILEMEM=1 scripts/test.sh -c release --filter TileMemoryBenchmark
```

Gemessen 2026-11-13 auf Chris' Mac (M3 Max), Release, synthetischer Korpus: 12 Scan-PDFs × 30 A4-Seiten (150 dpi, ein Bild pro Seite), 60 Reihen à 6 Kacheln (200×283 pt, Retina), 1 Reihe alle 16 ms. Die Aufrufe zum Vorausladen folgen dem Muster der 1.2.3-Ansicht. Dieselbe Testdatei lief vorher in einem temporären Worktree von v1.2.3.

| Messung | 1.2.3 | 1.2.4 |
|---|---|---|
| Speicherspitze (phys_footprint) | 301 MB | **96 MB** |
| Platten-Rückstand nach dem Anhalten (bis alle Kacheln geschrieben sind) | 7 782 ms | **957 ms** |
| Gerenderte Kacheln | 348 | 345 |
| Letzte sichtbare Kachel nach dem Anhalten | 0 ms | 0 ms |

Was den Unterschied macht:

- Höchstens 32 Kacheln warten aufs Schreiben, ältere fallen weg.
- Ein neuer Vorausladeauftrag ersetzt den alten.

In der App bündelt der `TilePrefetcher` die Aufträge zusätzlich auf einen pro Bildschirmbereich, nach 80 ms Ruhe. Der Benchmark ruft `prefetch` noch im alten Muster auf, sein Vorteil ist hier also nicht mitgemessen.

# Word/PowerPoint (1.3 Teil A, Task 10 und 10b)

Gemessen 2026-11-13 auf Chris' Mac (Mac15,9, Apple M3 Max, 16 Kerne, 64 GB, macOS 26.7.2 Build 25G332),
Debug-Build (`swift test`). Test: `OfficeKitTests/OfficeRealFilesMeasurement` (nur mit Umgebungsvariable,
sonst übersprungen; optional `PDFSUCHER_OFFICE_ONLY=<Teil des Dateinamens>` für ein Deck im frischen Prozess,
`PDFSUCHER_OFFICE_SHEETS=<Ordner außerhalb des Repos>`, `PDFSUCHER_OFFICE_SHEET_DECKS=<Namensteile, kommagetrennt>`):

```
PDFSUCHER_OFFICE_PERF=1 scripts/test.sh --filter OfficeRealFilesMeasurement/measureRealFiles
PDFSUCHER_OFFICE_PERF=1 scripts/test.sh --filter OfficeRealFilesMeasurement/measureWordSizes
```

Eingaben nur lesend, nicht kopiert: die 7 Decks in `<Testordner>/pptx/` sowie
`test.docx`, `test.doc`, `test.pptx` und `test äöü leer.pptx` aus `~/Developer/PDFSucher-spikes/office/in/`.
`<Testordner>/docx/` gibt es nicht; erzeugte Word-Dateien mit 10/100/500 Seiten (Spec §12)
misst Task 10b (Abschnitt „Word-Größen“ unten). Index, SlideCache und Quick-Look-Ausgabe liegen in temporären Ordnern.

Ablauf: (1) jede Datei einzeln nacheinander über `QuickLookSlideSource` bzw. `TextKitWordSource`, die Stufen
über den Snapshot-Hook und einen umhüllten HTML-Generator gestoppt; (2) Kacheln aus dem Cache über
`OfficePages.thumbnail` (400 px); (3) ein echter `Indexer`-Lauf (`OfficeLayoutSource`, `layoutConcurrency` 2)
über einen Ordner mit symbolischen Links auf die Originale, dann ein zweiter Lauf; (4) Suche über diesen
Index; (5) Quick-Look-HTML je Deck dreimal erzeugt. Werte aus dem letzten von drei Läufen (die anderen lagen
je Datei innerhalb von ±10 %).

### Je Datei (einzeln, nacheinander)

Die sieben echten Decks heißen hier nur „Deck A–G“ (Kundendateien); die Zuordnung liegt außerhalb des Repos.

QL = `qlmanage`-HTML; Laden = WebView lädt das HTML; Aufwärmen = jede Folie einmal in den Viewport
(50 ms je Folie) + 1 s Wartezeit; Folie = Text, Wortrahmen und Snapshot je Folie (Median/Max ohne die letzte);
Rest = letzte Folie + HEIC-Kodierung und Schreiben aller Folien in den Cache. Bilder-Warten (`complete`) war
überall 0,00 s. Die Tabelle ist der Stand **vor Task 10b**; seitdem wird jede Folie gleich nach ihrem Snapshot
kodiert und geschrieben, das steckt jetzt in „Folie“ (Vergleich unter „Speicher“).

| Datei | Größe | Gesamt | QL | Laden | Aufwärmen | Folie Median / Max | Rest (Cache) | Seiten / sichtbar / XML | Cache |
|---|---|---|---|---|---|---|---|---|---|
| Deck A | 25,0 MB | 11,5 s | 0,77 s | 0,26 s | 4,16 s | 40 / 105 ms | 3,5 s | 57 / 57 / 58 | 7,6 MB |
| Deck B | 7,6 MB | 3,9 s | 0,37 s | 0,15 s | 1,83 s | 33 / 90 ms | 1,1 s | 14 / 14 / 15 | 2,2 MB |
| Deck C | 47,0 MB | 11,3 s | 1,33 s | 0,27 s | 3,95 s | 44 / 108 ms | 3,2 s | 53 / 53 / 53 | 6,5 MB |
| Deck D | 4,3 MB | 3,4 s | 0,45 s | 0,17 s | 1,66 s | 38 / 68 ms | 0,7 s | 11 / 11 / 11 | 1,8 MB |
| Deck E | 78,9 MB | 13,0 s | 0,95 s | 0,22 s | 4,61 s | 50 / 127 ms | 4,0 s | 65 / 65 / 66 | 8,0 MB |
| Deck F | 11,6 MB | 2,8 s | 0,25 s | 0,12 s | 1,48 s | 40 / 69 ms | 0,6 s | 9 / 9 / 9 | 1,5 MB |
| Deck G | 4,9 MB | 5,5 s | 0,64 s | 0,17 s | 2,28 s | 35 / 103 ms | 1,4 s | 24 / 24 / 25 | 5,3 MB |
| test.pptx | 30 KB | 1,56 s | 0,09 s | 0,08 s | 1,18 s | 8 / 9 ms | 0,19 s | 3 / 3 / 3 | 0,1 MB |
| test äöü leer.pptx | 30 KB | 1,56 s | 0,10 s | 0,08 s | 1,17 s | 8 / 8 ms | 0,18 s | 3 / 3 / 3 | 0,1 MB |
| test.docx | 37 KB | 5 ms | – | – | – | – | – | 3 (Referenz-PDF: 3) | – |
| test.doc | 20 KB | 4 ms | – | – | – | – | – | 3 (Referenz-PDF: 3) | – |

- Keine Fehler, keine Ausreißer über 14 s. Je Folie insgesamt 0,20–0,31 s; bei großen Decks fast genau
  Aufwärmen (≈ 70 ms/Folie inkl. Scroll-Aufruf) + Folien (≈ 45 ms) + Cache (≈ 50 ms/Folie HEIC; ein zweites
  Kodieren aller Bilder aus dem Cache dauerte 2,9 s für 57 Folien). Quick Look selbst ist der kleinste Teil.
- Seiten = sichtbare Folien laut `presentation.xml` bei allen Decks; die 4 Decks mit einer ausgeblendeten Folie
  haben genau eine Seite weniger als Folien im XML.
- Cache auf der Platte: 33 MB für alle 11 Dateien (≈ 0,1–0,2 MB je Folie, HEIC 2.800 px).

### Speicher

**Vor Task 10b** (Task 10): `SlideSnapshotter` gab alle Folienbilder als Liste zurück, `QuickLookSlideSource`
schrieb sie erst am Ende mit `SlideCache.store`. Gemessen (Deck A, frischer Prozess, `ru_maxrss`): 82 MB vor den
Snapshots, 663 MB bei der letzten Folie (≈ 10 MB je gehaltenem Bild), 1.638 MB nach dem Schreiben in den Cache
(HEIC-Kodieren aller gehaltenen Bilder am Stück). Insgesamt also ≈ 28 MB je Folie, linear in der Folienzahl.

**Seit Task 10b** schreibt `SlideCacheWriter` jede Folie gleich nach ihrem Snapshot als HEIC in den `.tmp`-Ordner
des Eintrags; veröffentlicht wird am Ende wie bisher. Je Deck in einem frischen Prozess
(`PDFSUCHER_OFFICE_ONLY`, `ru_maxrss` = Höchststand des Prozesses; Fußabdruck = `phys_footprint` nach dem Layout):

| Deck | Folien | maxrss vorher | maxrss nachher | Fußabdruck nachher | Gesamt vorher → nachher | Folie Median vorher → nachher | Rest vorher → nachher |
|---|---|---|---|---|---|---|---|
| Deck A | 57 | 1.638 MB | **709 MB** | 49 MB | 11,6 → 11,5 s | 38 → 98 ms | 3,6 → 0,13 s |
| Deck B | 14 | 445 MB | **156 MB** | 49 MB | 4,2 → 4,2 s | 32 → 101 ms | 1,1 → 0,13 s |
| Deck C | 53 | 1.568 MB | **708 MB** | 48 MB | 11,3 → 11,4 s | 41 → 99 ms | 3,2 → 0,12 s |
| Deck D | 11 | 509 MB | **346 MB** | 44 MB | 3,8 → 3,7 s | 41 → 98 ms | 0,8 → 0,15 s |
| Deck E | 65 | 1.772 MB | **709 MB** | 48 MB | 13,2 → 13,0 s | 46 → 105 ms | 4,2 → 0,12 s |
| Deck F | 9 | 434 MB | **312 MB** | 43 MB | 3,1 → 3,1 s | 39 → 99 ms | 0,6 → 0,11 s |
| Deck G | 24 | 941 MB | **567 MB** | 46 MB | 5,8 → 5,8 s | 31 → 90 ms | 1,6 → 0,11 s |

„Vorher“ = Commit e15067a, gleiche Maschine, gleicher Tag, je Deck frischer Prozess (Median vorher über alle
Folien inklusive der letzten, wie der Test damals ausgab; der Test gibt Median/Max jetzt ohne die letzte aus). Die Gesamtzeit ist gleich
geblieben: die ≈ 50–60 ms HEIC je Folie sind vom Ende in jede Folie gewandert (Median ≈ 100 ms statt ≈ 40 ms,
„Rest“ = letzte Folie + Veröffentlichen ≈ 0,1 s statt 0,6–4,2 s). Das Kodieren läuft außerhalb des Main Actors.

Der Höchststand wächst nicht mehr mit der Folienzahl: `ru_maxrss` je zehn Folien bei Deck E
88 → 333 → 502 → 674 → 708 → 709 → 709 MB (Folie 0, 10, …, 60), bei Deck A genauso; ab etwa Folie 40 flach,
53, 57 und 65 Folien enden alle bei ≈ 709 MB. Der tatsächliche Fußabdruck bleibt während des ganzen Decks
bei ≈ 50 MB; der Anstieg von `ru_maxrss` bis zur Sättigung ist freigegebener, vom System noch nicht
zurückgeholter Speicher (Snapshot-/Dekodier-Puffer), keine gehaltenen Bilder. Ganzer Messlauf in einem Prozess
(7 Decks, 4 Testdateien, danach Indexer mit zwei Decks gleichzeitig): maxrss 38 → 708 MB nach dem ersten Deck →
750 MB nach allen Einzelmessungen → 822 MB nach dem Indexer-Lauf (vorher 1.638 → 1.779 → 1.861 MB);
Fußabdruck danach 142 MB. Ein Deck mit mehreren hundert Folien sollte also bei ≈ 0,7 GB Höchststand bleiben
statt ≈ 8 GB (nicht mit einem echten 300-Folien-Deck gemessen; keins vorhanden).

### Word-Größen (Spec §12, Task 10b)

Erzeugt mit `OfficeFixtures.docx` (A4, ohne Formatierung; vier deutsche Absätze à ≈ 600 Zeichen mit Umlauten im
Wechsel, 7,2 Absätze je Seite) in einem temporären Ordner, gesetzt mit `TextKitWordSource`. Erste Kachel
(400 px) über `OfficePages.thumbnail`: „warm“ = Dokument schon im LRU (nach dem Layout), „kalt“ = zweite,
inhaltsgleiche Datei, die erst geladen und gesetzt werden muss. Eigener Prozess, drei Läufe (Werte des letzten,
die anderen innerhalb von ±3 %):

| Ziel | Seiten | Datei | Layout gesamt | je Seite | 1. Kachel warm | 1. Kachel kalt | maxrss vor → nach Layout → nach Kacheln | Fußabdruck danach |
|---|---|---|---|---|---|---|---|---|
| 10 | 10 | 3 KB | 0,11 s | 11,1 ms | 4,1 ms | 10,6 ms | 38 → 50 → 53 MB | 17 MB |
| 100 | 99 | 8 KB | 0,64 s | 6,5 ms | 0,6 ms | 96,5 ms | 56 → 85 → 92 MB | 55 MB |
| 500 | 495 | 25 KB | 4,17 s | 8,4 ms | 0,5 ms | **868 ms** | 105 → 255 → 280 MB | 244 MB |

- Layout ≈ 6–11 ms je Seite, linear; 495 Seiten in 4,2 s, weit unter den 120 s je Datei.
- Speicher ≈ 0,3 MB je Seite für ein gesetztes Dokument (Fußabdruck danach enthält zwei 495-Seiten-Dokumente
  im LRU, `cacheCapacity` 4).
- **Erste Kachel kalt verfehlt bei 500 Seiten die 300 ms aus §12** (868 ms, Debug-Build): `TextKitWordDocument`
  setzt beim Öffnen das ganze Dokument, bevor Seite 0 gezeichnet werden kann. Bei 100 Seiten 97 ms. Warm (Dokument
  im LRU, z. B. direkt nach dem Indexieren derselben Datei) < 5 ms. Siehe decisions.md.

### Indexer-Lauf und Suche

| Lauf | Wandzeit | Ergebnis |
|---|---|---|
| Erster Lauf, 11 Dateien, `layoutConcurrency` 2 | 28,6 s | 11 gesetzt, 0 Fehler, 0 ohne Text, 0 verschoben; Summe der Einzelzeiten 56,4 s |
| Zweiter Lauf (unverändert) | 0,001 s | 11 unverändert, 0 Layout-Aufrufe |

Je Datei im Indexer (parallel zu zweit): Deck E 13,4 s, Deck C 12,0 s, Deck A 11,6 s, Deck G 5,9 s,
Deck B 3,9 s, Deck D 3,6 s, Deck F 3,0 s, test(-äöü).pptx je 1,6 s, Word je < 5 ms — praktisch wie einzeln.
Nach Task 10b: 28,7 s Wandzeit, Einzelzeiten innerhalb ±5 % davon.

Suche über diesen Index (11 Dateien, 245 Seiten, Median aus 5; neutrale Suchwörter seit Task 10b): `und` 5,2 ms,
`Daten*` 0,2 ms, `*ung` 7,6 ms, `gibtsnicht` 0,0 ms (Task 10 mit anderen Wörtern: 0,7–13 ms).

### Kacheln aus dem Cache (400 px)

| Datei | erste Kachel | nächste 5 zusammen |
|---|---|---|
| Deck B | 84 ms (frühere Läufe 99–131 ms; erster HEIC-Zugriff im Prozess) | 239 ms |
| Deck G | 35 ms | 169 ms |
| test.docx | 1,4 ms | 0,4 ms (nur 2 weitere Seiten) |

Nach Task 10b (Reihenfolge jetzt Deck G zuerst): Deck G 46 ms / 221 ms, Deck B 102 ms / 261 ms, test.docx
1,6 ms. Ausgewählt werden die zwei kleinsten Decks mit ausgeblendeter Folie (statt fester Dateinamen).

Der Cache war gerade geschrieben (Dateien vermutlich im Puffer des Systems); von einer kalten Platte kann es
länger dauern.

### Quick Look liefert nicht jedes Mal dasselbe HTML

Dreimal `qlmanage` je Deck, gezählt `<img>`-Elemente im HTML:

| Deck | Lauf 1 | Lauf 2 | Lauf 3 |
|---|---|---|---|
| Deck A | 539 | 534 | 503 |
| Deck B | 243 | 246 | 246 |
| Deck C | 836 | 824 | 840 |
| Deck D | 309 | 307 | 313 |
| Deck E | 581 | 567 | 567 |
| Deck F | 111 | 114 | 111 |
| Deck G | 314 | 314 | 314 |
| test.pptx / test äöü leer.pptx | 1 | 1 | 1 |

Zweimal hintereinander gesetzt und die Folienbilder verglichen (160 × 120 px, > 20 deutlich andere Pixel):
Deck A 29 von 57 Folien verschieden, Deck B 12 von 14, Deck C 25–33 von 53, Deck E 29 von 65; Deck D, Deck F
und Deck G 0. Beispiele: in einem Deck fehlt oder erscheint ein Textkasten je nach Lauf; in einem anderen
erscheinen auf einer Folie je nach Lauf sechs kleine Bilder oder nicht. Die Unterschiede stehen schon im HTML (andere Zahl von `<img>`
je Folie, andere Anhänge), nicht erst im WebView: zusätzliches Warten, `img.decode()` vor dem Snapshot und
`decoding = 'sync'` änderten nichts. Text und Wortrahmen stammen aus dem DOM und können sich ebenso ändern,
wenn ein Textfeld fehlt.

### Bewertung gegen die Spec

- **Zeitlimit 60 s je Deck (Quick Look) / 120 s je Datei: eingehalten**, mit großem Abstand: Quick Look höchstens
  1,4 s, ganze Datei höchstens 13,4 s (Deck E, 79 MB, 65 Folien), auch mit zwei Decks gleichzeitig.
- **„Erste Kachel einer Reihe < 300 ms“ (§12): eingehalten** für gesetzte Dateien (35–131 ms PowerPoint aus dem
  Cache, 1,4 ms Word). Gemessen ohne Grid und Hauptthread-Weg; ein noch nicht gesetztes Deck zeigt bis zum Ende
  seines Layouts (3–13 s) einen Platzhalter.
- **Suche < 200 ms: unberührt** (höchstens 13 ms auf diesem kleinen Index; Office-Seiten sind normale FTS-Zeilen).
- **Word-Seitenzahlen:** test.docx und test.doc je 3 Seiten wie das Word-Referenz-PDF, 4–5 ms (im Test geprüft).
- **Word 10/100/500 Seiten (§12):** Layout eingehalten (≤ 4,2 s); erste Kachel kalt bei 495 Seiten 868 ms, also
  **über** 300 ms; warm < 5 ms.
- **Speicher:** vor Task 10b ≈ 28 MB je Folie (bis 1,8 GB); seit Task 10b Höchststand ≈ 0,7 GB unabhängig von der
  Folienzahl, Fußabdruck ≈ 50 MB, Gesamtzeit unverändert.
- **Nicht in der Spec, aber auffällig:** nicht reproduzierbare Quick-Look-Ausgabe bei 4 von 7 Decks.

## SlideKit: PowerPoint decks (Task 14)

Measured 2026-11-13 on Chris' Mac (Apple M3 Max, 16 cores, macOS 26), **release build**, Chris' 7 real decks
(D1–D7, 9–65 visible slides, 4.5–83 MB). Single thread, one slide after another.

```
PDFSUCHER_BENCH=1 PDFSUCHER_PPTX_CORPUS=<Testordner>/pptx \
  scripts/test.sh -c release --no-parallel --filter SlideKitTests.SlideKitBenchmark
```

- Open: `SlideDeck(url:)` (zip directory, presentation.xml, each slide's `show` attribute); first / median of 5.
- Thumb 256 cold: `thumbnail(i, maxPixel: 256)` for every slide of a freshly opened deck (parsing, layout, image
  decoding on first use); warm: the same again on the same deck (all caches filled).
- Render 1600: `thumbnail(i, maxPixel: 1600)` (a full-screen slide), cold on a fresh deck, then warm.
- Text: `slideText(i)` + `wordBoxes(i)` on a fresh deck.
- Times per slide in ms as median / max.

After Task 14 (size-aware image decoding, commit "OOXMLKit: size-aware image decoding…"):

| Deck | Slides | Open (1st / median) | Thumb 256 cold | Thumb 256 warm | Render 1600 cold | Render 1600 warm | slideText + wordBoxes |
|---|---|---|---|---|---|---|---|
| D1 | 57 | 123.4 / 123.0 | 8.9 / 58.0 | 0.5 / 9.2 | 19.6 / 81.5 | 6.2 / 25.8 | 1.8 / 29.3 |
| D2 | 14 | 43.0 / 42.3 | 9.9 / 55.9 | 0.7 / 5.4 | 17.9 / 155.5 | 7.5 / 96.1 | 4.1 / 14.4 |
| D3 | 53 | 102.6 / 102.7 | 7.6 / 65.8 | 0.5 / 1.6 | 12.5 / 91.3 | 6.2 / 45.3 | 2.5 / 13.2 |
| D4 | 11 | 33.6 / 33.3 | 9.3 / 30.1 | 0.4 / 1.2 | 9.7 / 36.8 | 1.6 / 20.4 | 4.7 / 9.0 |
| D5 | 65 | 133.2 / 133.2 | 7.1 / 111.7 | 1.0 / 3.9 | 15.8 / 135.7 | 6.2 / 33.1 | 3.1 / 16.4 |
| D6 | 9 | 22.4 / 22.1 | 6.2 / 39.8 | 0.4 / 0.8 | 11.6 / 41.2 | 3.1 / 14.5 | 5.1 / 6.5 |
| D7 | 24 | 54.9 / 54.9 | 6.6 / 21.1 | 0.3 / 1.9 | 11.2 / 29.0 | 1.9 / 10.6 | 3.8 / 13.1 |

Before (full-resolution decoding, cache emptied at 512 MB; same machine, same day):

| Deck | Slides | Open (1st / median) | Thumb 256 cold | Thumb 256 warm | Render 1600 cold | Render 1600 warm | slideText + wordBoxes |
|---|---|---|---|---|---|---|---|
| D1 | 57 | 124.8 / 123.1 | 8.7 / 73.0 | 1.3 / 12.1 | 17.7 / 69.4 | 7.1 / 25.4 | 1.8 / 29.2 |
| D2 | 14 | 43.0 / 42.8 | 10.3 / 56.1 | 1.5 / 9.3 | 14.6 / 144.4 | 7.5 / 97.6 | 4.1 / 14.5 |
| D3 | 53 | 104.5 / 103.5 | 7.4 / 62.8 | 1.5 / 18.8 | 12.5 / 91.7 | 6.9 / 63.5 | 2.6 / 13.4 |
| D4 | 11 | 34.2 / 33.9 | 9.3 / 28.4 | 0.8 / 6.3 | 10.1 / 32.5 | 1.7 / 21.5 | 4.8 / 9.5 |
| D5 | 65 | 134.0 / 133.9 | 7.8 / 109.1 | 1.4 / 61.1 | 14.7 / 123.5 | 7.9 / 79.2 | 3.1 / 16.6 |
| D6 | 9 | 23.1 / 22.8 | 6.5 / 34.7 | 0.6 / 4.0 | 11.0 / 36.8 | 3.2 / 14.5 | 5.2 / 7.0 |
| D7 | 24 | 55.7 / 55.6 | 6.0 / 19.0 | 0.7 / 2.1 | 9.4 / 25.0 | 1.9 / 11.3 | 3.9 / 13.6 |

Against spec §7 (measure, not promise):
- **Open a 60-slide deck < 1 s:** ✔ 23–133 ms (D5, 65 slides: 133 ms; D1, 57 slides: 123 ms).
- **Tile < 100 ms after loading:** ✔ median 6–10 ms cold, ≤ 1 ms warm. Max cold: 112 ms on one D5 slide (image-heavy,
  rotated clippings); all other decks ≤ 66 ms. Warm max ≤ 9 ms after the decoding change (was up to 61 ms).
- The debug-build hotspot (one deck ~220–260 ms/slide) is mostly debug overhead: in release the same deck renders at
  1600 px in 16 ms median. What remained was drawing multi-megapixel photos into small bitmaps every time; size-aware
  decoding removed that for warm thumbnails (D5 max 61 → 4 ms, D3 19 → 2 ms). Cold times are dominated by parsing,
  text layout and the first decode and barely changed; full-resolution decoding of all media is cheap
  (≤ 145 ms per deck: ImageIO decodes lazily at first draw).
- Cold max on the first slide of D1/D2 (~55–70 ms) is the one-time master/layout/theme parse.
- Opening reads every slide part's root to check `show="0"`; that is the 23–133 ms (≈ 2 ms per slide).

## 1.3.2: Speicher beim ersten Indexieren (Office)

Anlass: Chris' installierte 1.3.0 erreichte beim ersten Start mit echten Quellen 4,2 GB (nach 3 min 899 MB).
Gemessen 2026-11-13 auf Chris' Mac (Apple M3 Max, 16 Kerne, macOS 26), **Debug-Build**, synthetische Decks (keine
Kundendateien): 8 Decks × 30 Folien, jede Folie ein eigenes 3000 × 2250-PNG über die ganze Folie plus Text.
`phys_footprint` alle 2 ms abgetastet, Spitze über der Grundlinie (nach der Schriftregistrierung); ein Prozess je
Konfiguration.

```
PDFSUCHER_MEMBENCH=1 PDFSUCHER_MEMBENCH_LAYOUT=2 PDFSUCHER_MEMBENCH_DECKS=4 PDFSUCHER_MEMBENCH_PIXEL=1600 \
  scripts/test.sh --no-parallel --filter OfficeMemoryBenchmark
```

Layoutphase (Indexer, `layoutConcurrency` = Layouts gleichzeitig), ohne Kacheln:

| Layout | gleichzeitig | Zeit | Spitze (im Prozess) |
|---|---|---|---|
| SlideKit (Vorgabe) | 2 | 0,2 s | +5 MB |
| SlideKit | 1 | 0,4 s | +4 MB |
| Quick Look | 2 | 24–28 s | +115–136 MB |
| Quick Look | 1 (nur PowerPoint) | 42–60 s | +66–145 MB |

Kacheln über `SlideKitPages` (`SlideDeckCache`-Kapazität = Decks gleichzeitig offen), jede Folie jedes Decks einmal:

| Kachelgröße | Kapazität 4 (1.3.0) | Kapazität 2 (1.3.2) | Kapazität 1 |
|---|---|---|---|
| 512 px | +111 MB | +65 MB | +44 MB |
| 1600 px | **+1494 MB** | **+772 MB** | – |
| 1600 px, gleichzeitig Layoutlauf (SlideKit, 2) | +1495 MB | +773 MB | – |

Befund:
- Das SlideKit-Layout (nur Text und Wortrahmen) braucht fast keinen Speicher; Bilder werden dabei nicht dekodiert.
  Ein Deck je Layout zu drosseln bringt hier nichts. Unter Quick Look ist die Spitze im Prozess mit 1 oder 2 Decks
  gleich (Streuung größer als der Unterschied; das Rendern läuft größtenteils außerhalb des Prozesses), die Zeit
  steigt um 50–150 %. → **keine Drosselung** der Layoutphase (`layoutConcurrency` bleibt 2).
- Den Speicher halten die **offenen Decks der Anzeige**: ein Deck, groß gezeichnet (Vorschau, große Kacheln), behält
  bis zu ~375 MB dekodierte Bilder (SlideKits Bildcache erlaubt 512 MB je Deck). `SlideDeckCache.shared` mit 4
  Decks erreichte 1,5 GB, mit 2 Decks die Hälfte. → **Kapazität 2** (immer; ein Deck neu öffnen kostet 20–130 ms).
- Weiter senken ließe sich das nur über SlideKits Bildcache je Deck (`ImageDecoder.maxCacheBytes`, eine Konstante
  in OOXMLKit, kein Parameter) – nicht in diesem Fix geändert, gemeldet.
- Die 4,2 GB bei Chris erklärt das nicht allein: Phase 2 (Vision-OCR) und PDF-Kacheln laufen beim ersten Indexieren
  mit; die hier gemessene Office-Seite trägt mit 4 Decks bis ~1,5 GB bei.

## 1.3.4: Vorschau-Puffer

Gemessen 2026-11-15 auf Chris' Mac, **Release-Builds**, UI-Test-Modus (eigene Temp-Indizes) mit Chris' Layout:
Fenster 2560×1320, Vorschau links, Zoom Seitenbreite, Raster 8×8, alle Seiten. Ordner wie in der Spike-Messung
(`interne Messnotiz`): `<Testordner>/pptx` und ein Scan-Ordner (53 PDFs,
davon 6 mit 1-Bit-Großscans). Vorher = release-1.3.4 (a11573c) + nur der Messhaken (352759c); nachher = Zweig
`preview-buffer`. Messskripte: `PDFSucher-spikes/preview-buffer-measure/` (`build.sh`, `run.sh`, `analyze.py`).

```
open -n -W -g PDFSucher.app --args -uiTestFolders "<pptx>|<Scansnap>" -uiTestKeepDefaults YES \
     -uiTestAutoNextDocMS 1500 -uiTestSteps 40 -uiTestWaitS 5
log stream --level debug --predicate 'subsystem == "local.pdfsucher" && category == "PreviewTiming"'
```

`-uiTestAutoNextDocMS` blättert wie ↓ von Datei zu Datei; ausgewertet sind die 33 PDF-Wechsel. Zeiten in ms ab dem
Setzen von `focusedPage`. „Sichtbar“ = erstes Bild: Platzhalter (vorgezeichnet, Kachel, Seitenfläche) oder erstes
Zeichnen der PDFView. „Scharf“ = vorgezeichnetes Bild oder das erste Zeichnen der PDFView mit ≥ 90 % der
Retina-Auflösung (früher als „scharf“ in MESSUNG.md, dort die letzte Kachel). „Hänger“ = Lücken im Main-Thread > 50 ms
(Wächter, nur im Messmodus).

### Normales Blättern (alle 1,5 s)

Die Grundlast des Rechners schwankte (ein Simulator-Prozess); ruhige Läufe sind die, in denen nur die 6 Scans hängen.

| | sichtbar Median / Max | scharf Median / Max | PDFView scharf Median / Max | Hänger > 50 ms |
|---|---|---|---|---|
| vorher (2 ruhige Läufe) | 76 / 483 · 74 / 459 | 98 / 629 · 93 / 607 | wie scharf | 6 × ~260 ms (die 1-Bit-Scans in `go(to:)`) |
| nachher (3 ruhige Läufe) | 42 / 68 · 32 / 62 · 37 / 64 | 42 / 105 · 32 / 121 · 37 / 112 | 222–239 / 628–643 | 6 × ~260 ms, erst nach 150 ms Ruhe |
| vorher, Rechner belastet (2 Läufe) | 222 / 1 235 · 246 / 1 251 | 289 / 1 066 · 262 / 1 252 | | 70–80, bis 629 ms |
| nachher, Rechner belastet (2 Läufe) | 77 / 123 · 81 / 110 | 77 / 252 · 83 / 110 | | 58–61, bis 429 ms |

- 32 von 33 Wechseln zeigen sofort das vorgezeichnete, scharfe Bild mit Markierungen; einer die Kachel.
- Die PDFView übernimmt bei schweren Seiten (Bilder ≥ 4 MP) absichtlich erst nach 150 ms Ruhe; bis dahin liegt das
  scharfe Bild darüber. Darum ist „PDFView scharf“ später als vorher, das sichtbare Bild aber früher.
- Bei 1-Bit-Scans blockiert `go(to:)` nach der Ruhe weiterhin ~260 ms (PDFKit), aber nur, wenn man stehen bleibt.

### Schnelles Blättern durch die Scans (alle 120 ms, 52 Schritte, nur `2023 Scansnap`)

| | sichtbar | nie sichtbar (Spinner) | scharf Median / Max | Hänger > 50 ms |
|---|---|---|---|---|
| vorher (3 Läufe) | Median 42–44, Max 155–621 | 31–33 von 52 | 64–74 / 155–621 | 14–18, bis 328 ms |
| nachher (3 Läufe) | Median 6, Max 44 | 0 | 6–7 / 418–433 | 0 · 0 · 1 × 58 ms |

- Nachher zeigt jeder Wechsel sofort ein Bild: 30–33 × vorgezeichnet, 11–14 × Kachel, 7–9 × Seitenfläche.
- Der Max-Wert „scharf“ 420–430 ms ist die letzte Seite nach dem Ende des Laufs (1-Bit-Scan, Vorzeichnen ~400 ms).

### Zielwerte (Spec)

- Median ≤ 50 ms bis sichtbar: **erfüllt** (32–42 ms; schnelles Blättern 6 ms).
- Beim normalen Weiterblättern scharfes Bild: **erfüllt** (32 von 33 vorgezeichnet).
- Kein Main-Thread-Block > 100 ms beim schnellen Blättern durch Scans: **erfüllt** (0 bzw. 1 × 58 ms; vorher bis 328 ms).

## office-speed: Word- und PowerPoint-Kacheln (Paket 1–4)

Gemessen 2026-11-16 auf Chris' Mac (M3 Max, 16 Kerne), **Release**, je Zeile ein frischer Prozess, 3 Durchgänge,
Median / Max über die Prozesse. Vorher = main 92ffcb6 + Messcode, nachher = Zweig `claude/project-thread-it2vzj` +
derselbe Messcode, beide direkt nacheinander gemessen (heute las kein Prozess Office' Cloud-Schriftcache rechtzeitig,
`complete=false`; darum ist „vorher“ neu gemessen statt aus MESSUNG.md übernommen). Volle Tabelle, Methode und Rohdaten:
interne Messnotiz. Entscheidungen: decisions.md „Office-Vorschau schneller“.

| Szenario | vorher ms | nachher ms | Faktor |
|---|---|---|---|
| Deck öffnen (7 Decks) | 24–138 | 1,6–7,2 | 10–24× |
| A2 ein Deck, alle Folien gleichzeitig kalt (Wand) | 194–612 | 155–436 | 1,1–1,5× |
| A2 Deck-Öffnungen dabei | 6 je Deck | 1 je Deck | 6× |
| A3 Raster 7 Decks × 6 Folien, kalt, 6 Worker | 857 / 930 | 346 / 352 | 2,5× |
| A3 … zweiter Durchlauf | 756 / 762 | 25 / 26 | 31× |
| B1 erste Word-Kachel kalt (15 Dateien) | 93–2373 | 93–2492 | 1,0× |
| B2 Word 100 S. gleichzeitig, kalt, 6 Worker | 811 / 813 | 220 / 230 | 3,7× |
| B2 … Dokument importiert, 6 Worker | 188 / 188 | 33 / 33 | 5,7× |
| B3 Raster 8 Word-Dateien × 3 S., kalt | 2538 / 4569 | 2593 / 2625 | 1,0× (17 → 8 Importe) |
| B3 … zweiter Durchlauf | 4468 / 4502 | 14 / 14 | > 300× |
| B4 erste Word-Kachel, Registrierung läuft | 2146 / 2152 | 53 / 56 | 41× |
| B4 erste Folien-Kachel vor der Registrierung | 2212 / 2230 | 103 / 110 | 21× |
| B5 30 Word-Kacheln ohne Layout | 71 / 71 | 24 / 25 | 3,0× |
| B5 30 Word-Kacheln während 2 Word-Layouts | 955 / 957 | 40 / 41 | 24× |

Speicher: A3 Prozess-Höchststand 152–183 → 202–224 MB. „1.3.2“-Bild-Deck (8 × 30 Folien à 3000 × 2250, 1600 px,
Layoutlauf, Debug, wie oben): 2 Decks +773 MB, neu 10 Decks / 400 MB **+457 MB**.

Befund: Faktor 5 und mehr überall, wo dasselbe Dokument wieder gebraucht wird (offen halten, einmal öffnen/importieren),
beim Öffnen eines Decks, bei Kacheln neben Index-Layouts und während der Schriftregistrierung. **Nicht** bei der
allerersten Kachel einer Datei: bei Folien bleiben Text setzen und Bilder dekodieren (A1 kalt 1,0–1,1×), bei Word
Import und Umbruch des ganzen Dokuments (B1 1,0×). Das wäre der nächste Hebel (Word seitenweise umbrechen, SlideKit-
Einmalkosten je Prozess).

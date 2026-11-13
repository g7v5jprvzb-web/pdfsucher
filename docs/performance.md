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

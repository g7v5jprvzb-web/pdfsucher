# SlideKit vs. Quick Look (Task 14)

Measured 2026-11-13 on Chris' Mac, branch `slidekit`. Decks are Chris' 7 real customer decks, named here only
D1–D7 (mapping kept outside the repo). Contact sheets (Quick Look left, SlideKit right, 1600 px) are written by
`SlideKitTests/CorpusTests` to `~/Developer/PDFSucher-spikes/slidekit-vergleich/` (never into the repo):

```
PDFSUCHER_PPTX_CORPUS=<Testordner>/pptx scripts/test.sh --filter SlideKitTests.CorpusTests
```

**Complete in content: 227 of 233 visible slides = 97.4 %** (target ≥ 90 %, spec §7).
Before the Task 14 fixes: 226 of 233 = 97.0 %.

"Complete in content" = all texts, images and shapes present and in the right place. Font substitution and
slightly different line breaks count as yes (spec risks R1/R2). Quick Look is **not** ground truth: it is
non-deterministic (12–33 slide images differ between two runs in 4 of 7 decks) and shows many errors of its own;
where the two disagreed, the slide XML (read with `unzip -p`) decided. "SK better" marks slides where SlideKit
follows the XML and Quick Look does not (154 of 233 slides).

| Deck | Visible slides | Complete |
|---|---|---|
| D1 | 57 | 57 |
| D2 | 14 | 14 |
| D3 | 53 | 53 |
| D4 | 11 | 11 |
| D5 | 65 | 59 |
| D6 | 9 | 9 |
| D7 | 24 | 24 |
| all | 233 | 227 (97.4 %) |

## Error groups

| Group | Slides | Status |
|---|---|---|
| EMF+-only pictures (icons) draw nothing: no EMF+ player | 6 (D5) | open, out of scope (needs an EMF+ player; Quick Look misses them too) |
| Group scaling stretched line widths (old decks with tiny child units) | 1 (D3), plus thinner/correct outlines on ~20 slides | fixed (`OOXMLKit: group scaling sizes child boxes…`) |
| Wingdings code without a Unicode mapping (missing-glyph box) | 1 (D1, counted complete) | fixed (`OOXMLKit: Wingdings white arrows`) |
| Font substitution (corporate fonts missing): wider text, text over box edges, a few words broken inside | ~10 (D1, D3, D5, D7), counted complete | not fixable here: fonts are not installed (R1) |
| Table style ID missing from the deck → deck default style (header colour differs) | 2 (D7), counted complete | known approximation (decisions: corpus table styles) |

## Where SlideKit beats Quick Look

Quick Look errors seen on the sheets, none of which SlideKit shows: wrong images swapped in from elsewhere in the
deck (image mix-up, the most common, D1/D2/D3/D5/D7); shapes or circles from other slides drawn on top ("ghost"
boxes); grey slide background instead of a transparent-over-white picture background; missing icons, frames,
clouds, arrows, connectors and whole boxes; multi-column text ignored (text overlapping); tables overflowing the
slide; rotation of shapes ignored; dotted instead of dashed lines; serif fallback fonts; slide numbers shown as a
placeholder glyph; layout frame shapes missing (D5). SlideKit additionally shows the real slide number and the
final state of animated slides.

## Open points (need Chris or are out of scope)

- EMF+ player: 6 D5 slides lose icons drawn only as EMF+ (also in two layouts). Building one is a separate task.
- Corporate fonts (D1, D3, D5, D7) are not installed; substitutes are wider, so some text overflows its box.
  Installing the fonts would fix it; nothing to do in code.
- 3D and WordArt effects: not rendered (spec §6); none caused an incomplete slide in this corpus.
- Two D7 tables use table style IDs that are not in the deck. At the time of the Quick Look comparison they fell
  back to the deck's default style; since `slidekit-ref` an unknown ID gets no style unless it is built in (ECMA:
  `def` is the style for new tables, not a fallback; see decisions.md, table styles).
- Settled by the PowerPoint section below: the D3 white box covers the footer picture in PowerPoint too (both
  slides near-identical, coarse 1.2–1.3 %), D2's panel gradient matches (1.1 %), and title anchoring follows the XML
  (the D1 title blocks now match within 0.6 pt).

## SlideKit vs. PowerPoint (slidekit-ref)

Measured 2026-11-13, branch `slidekit-ref` (numbers re-measured after the review fixes). Reference = PDF exports of the same 7 decks made by PowerPoint (Mac)
itself, the ground truth (Quick Look above was only a rough one). The comparison runs in the env-gated corpus test
and writes PowerPoint | SlideKit | diff sheets, per-slide scores and baseline measurements to
`~/Developer/PDFSucher-spikes/slidekit-vergleich/ppt/` (never into the repo):

```
PDFSUCHER_TEST_OFFICE_FONTS=1 PDFSUCHER_PPTX_CORPUS=<Testordner>/pptx scripts/test.sh -c release --filter SlideKitTests.PowerPointReferenceTests
PDFSUCHER_PPT_TEXT=all PDFSUCHER_PPTX_CORPUS=… scripts/test.sh --filter SlideKitTests.TextLineMeasurements
```

**Page mapping.** PowerPoint exports visible slides only: D1, D2, D5 and D7 each contain one hidden slide and their
PDFs have exactly as many pages as visible slides (D3, D4, D6 have none hidden). PDF page i = visible slide i; the
test also accepts an export with hidden slides (page count = all slides) and skips those pages.

**Scores.** Both sides at 1600 px on the long side on white. MAD = mean absolute channel difference (0–255);
coarse = share of 8×8 pixel blocks whose mean colour differs by more than 24, which ignores anti-aliasing and
sub-pixel glyph shifts. **Near-identical = coarse < 2 %.** Text-heavy slides cross 2 % with 0.5 pt offsets or a
different substitute font, so "differing" is not "wrong": see the causes.

"Complete in content" as above (all texts, images and shapes present and in place; font substitution counts as
yes), now judged against PowerPoint: the sheets of all 104 differing slides and of the 25 worst before the fixes
were reviewed.

| Deck | Visible | Complete before → after | Near-identical before → after | Differing after | Coarse mean before → after | Main remaining causes |
|---|---|---|---|---|---|---|
| D1 | 57 | 56 → 56 | 37 → 43 | 14 | 2.90 → 2.12 % | font substitution (tables, text boxes); one EMF diagram whose EMF+ part differs |
| D2 | 14 | 13 → 14 | 5 → 9 | 5 | 3.98 → 1.82 % | font/anti-aliasing offsets; one arrow shape |
| D3 | 53 | 53 → 53 | 46 → 47 | 6 | 1.49 → 1.44 % | 3D-rotated picture drawn flat; font weight; one icon only SlideKit shows |
| D4 | 11 | 11 → 11 | 8 → 9 | 2 | 2.05 → 1.56 % | glow effect not drawn; small text offsets |
| D5 | 65 | 59 → 59 | 12 → 16 | 49 | 4.70 → 4.55 % | substitute for the titles' font (43 slides); EMF+-only icons (6) |
| D6 | 9 | 9 → 9 | 3 → 3 | 6 | 2.62 → 2.51 % | sub-point text offsets and anti-aliasing |
| D7 | 24 | 24 → 24 | 2 → 2 | 22 | 8.19 → 6.61 % | substitute for the body font (widths, wrapping); one table style not known here |
| all | 233 | 225 → 226 (97.0 %) | 113 → 129 | 104 | 3.64 → 3.07 % | |

Against PowerPoint, D1's EMF diagram (one slide) is incomplete although Quick Look and SlideKit agreed: PowerPoint
plays its EMF+ records, which show a newer diagram than the EMF fallback SlideKit plays. Before the fixes D2 lost
a duotoned EMF icon (white on white).

Text positions: 2691 SlideKit text lines matched to PowerPoint baselines read from the PDF content stream; after
the fixes the median |difference| is 0.19–0.39 pt per deck and 1–10 % of lines are off by more than 1 pt
(D1 8 %, D5 10 %: wrapping with substitute fonts). PowerPoint's PDF positions are quantized to 0.96 pt.

### Difference groups (PowerPoint)

| Group | Slides | Status |
|---|---|---|
| Font substitution: SlideKit's look-alikes for missing corporate fonts are wider/heavier than PowerPoint's Calibri (widths, wrapping, weight); Lato/Open Sans/Aptos are Office cloud fonts not installed system-wide on the Mac | ~85 of the 104 differing | `.powerPoint` (default since slidekit-arial) draws missing fonts like PowerPoint: 104 → 87 differing; the cloud fonts stay open (see below) |
| Line height: a line break's size grew its line; tall font metrics grew lines; first line above 100 % or exact spacing sat 1.5–4.7 pt low | 20+ slides, e.g. D1 title blocks, D7 body text | fixed (3 commits) |
| Superscript drawn at full size | D7 table title, D1 footnote marks | fixed |
| Picture recolouring (duotone, grayscale, colour change, bi-level, brightness/contrast) ignored | D2, D3, D6, D7 icons and photos | fixed (bitmaps and metafiles) |
| Picture outlines centred instead of outside | 8 slides (D1, D2, D3, D5), framed screenshots | fixed |
| Table style IDs not in the deck took the deck's default | D2 (body text colour), D7 (two tables) | fixed for two styles; D7's "Themed Style 1 – Accent 1" stays an approximation (definition unknown) |
| EMF+ (icons that exist only as EMF+, one diagram whose EMF+ part differs) | 7 (D5 6, D1 1) | open, out of scope (no EMF+ player) |
| 3D picture rotation, glow | 2 (D3, D4) | open (effects not rendered, spec §6) |
| Remaining small geometry (one arrow, sub-point text offsets in tables) | ~5 | open, minor |
| Other: an icon SlideKit draws that PowerPoint's export does not show (cause not found) | 1 (D3) | open |

### Font substitution modes (slidekit-arial)

Measured 2026-11-13 with `PDFSUCHER_FONT_SUBST=powerPoint|similar` (same test, same 1600 px, scores-powerPoint.tsv /
scores-similar.tsv). `.similar` is the look-alike table as before and reproduces the numbers above exactly;
`.powerPoint` is the default (missing Latin fonts → Calibri, see docs/decisions.md "FontSubstitution").

| Deck | Visible | Near-identical `.similar` → `.powerPoint` | Coarse mean `.similar` → `.powerPoint` |
|---|---|---|---|
| D1 | 57 | 43 → 47 | 2.12 → 1.63 % |
| D2 | 14 | 9 → 9 | 1.82 → 1.82 % |
| D3 | 53 | 47 → 47 | 1.44 → 1.44 % |
| D4 | 11 | 9 → 9 | 1.56 → 1.56 % |
| D5 | 65 | 16 → 17 | 4.55 → 4.51 % |
| D6 | 9 | 3 → 3 | 2.51 → 2.50 % |
| D7 | 24 | 2 → 14 | 6.61 → 5.44 % |
| all | 233 | 129 → 146 | 3.07 → 2.82 % |

D1 (corporate TeleGrotesk/TeleNeo) and D7 (HP Simplified) gain; D2–D4 and D6 use installed or Office fonts and
do not change. The mean stays above 2 % because of D5 and D7: their bodies are set in Lato, Open Sans and Aptos,
which PowerPoint takes from Office's own font cache and which are not installed system-wide on this Mac, so SlideKit
draws Helvetica Neue in both modes (plus D5's EMF+-only icons). Using Office's fonts when Office is installed is an
open question (docs/decisions.md).

### Office's own fonts (slidekit-officefonts)

Measured 2026-11-13 on top of the ligature fix: SlideKit registers the fonts Office for Mac brings along (DFonts,
cloud font cache) for the process, so Lato, Open Sans, Aptos and Office's other faces are drawn in their real
face, as PowerPoint does (docs/decisions.md "Office's own fonts"). Off = `PDFSUCHER_NO_OFFICE_FONTS=1`.

| Deck | Visible | `.powerPoint` near-identical off → on | Coarse mean off → on | `.similar` near-identical off → on |
|---|---|---|---|---|
| D1 | 57 | 47 → 47 | 1.62 → 1.62 % | 43 → 43 |
| D2 | 14 | 9 → 9 | 1.82 → 1.82 % | 9 → 9 |
| D3 | 53 | 47 → 47 | 1.44 → 1.42 % | 47 → 47 |
| D4 | 11 | 9 → 9 | 1.56 → 1.56 % | 9 → 9 |
| D5 | 65 | 17 → 39 | 4.51 → 1.91 % | 16 → 39 |
| D6 | 9 | 3 → 3 | 2.50 → 2.50 % | 3 → 3 |
| D7 | 24 | 15 → 15 | 5.40 → 5.40 % | 2 → 2 |
| all | 233 | 147 → 169 | 2.82 → 2.09 % | 129 → 152 (3.07 → 2.35 %) |

(Since slidekit-fontpaths a test run uses Office's fonts only with `PDFSUCHER_TEST_OFFICE_FONTS=1`.) D5's Lato/Open Sans bodies and titles now match. D7 is unchanged: its body font (HP Simplified) is not an Office
font and is drawn in Calibri as by PowerPoint; the rest of its gap is layout. D2's Aptos text was already close.

### Estimates settled against PowerPoint

Details and numbers in `docs/decisions.md` (OOXMLKit / SlideKit section). Confirmed: line height 1.2 × size × factor,
first paragraph's spaceBefore ignored, arrowhead floor 2 pt, tint/shade in linear RGB, no tableStyleId → no style,
bullet gap fallback. Wrong and fixed: line-break size, font metrics growing lines, the first line above single
spacing, superscript size, unknown table style → deck default, picture outlines, recolour effects. Not isolable in
the corpus: table part precedence and shared-edge borders (consistent with every styled table that matches).

## Per slide

Slide number = n-th visible slide (hidden slides skipped, as in Quick Look's numbering).

| Deck | Slide | Complete | Reason / note |
|---|---|---|---|
| D1 | 1 | yes | – |
| D1 | 2 | yes | – |
| D1 | 3 | yes | – |
| D1 | 4 | yes | QL shows slide-number placeholder glyph, SK shows number |
| D1 | 5 | yes | – |
| D1 | 6 | yes | – |
| D1 | 7 | yes | title block sits higher (trailing empty title line), font substitution |
| D1 | 8 | yes | SK better: QL misses the icon images in the table |
| D1 | 9 | yes | SK better: QL shows a wrong picture instead of the right one; second slide number is a master text box (correct) |
| D1 | 10 | yes | font substitution (corporate font): text box text overflows its frame slightly |
| D1 | 11 | yes | font substitution (corporate font): text box text overflows its frame slightly |
| D1 | 12 | yes | SK better: QL shows wrong image (image mix-up) and misses icon |
| D1 | 13 | yes | – |
| D1 | 14 | yes | QL draws the transparent part of the background picture grey, SK white |
| D1 | 15 | yes | SK better: QL shows a wrong image (image mix-up) |
| D1 | 16 | yes | SK better: QL lets the bottom text overflow the box (autofit) |
| D1 | 17 | yes | SK better: QL shows wrong images over the slide |
| D1 | 18 | yes | SK better: QL shows wrong image, misses icons |
| D1 | 19 | yes | – |
| D1 | 20 | yes | – |
| D1 | 21 | yes | SK better: QL shows wrong/blank images in place of icons |
| D1 | 22 | yes | – |
| D1 | 23 | yes | SK better: QL draws grey background and white boxes over the diagram |
| D1 | 24 | yes | SK better: QL draws grey background, white boxes and a stray arrow image |
| D1 | 25 | yes | SK better: QL grey background, white boxes over the diagram |
| D1 | 26 | yes | SK better: QL grey background, white boxes over the diagram |
| D1 | 27 | yes | SK better: QL adds stray shapes/images that are not in the slide XML |
| D1 | 28 | yes | SK better: QL adds a stray shape not in the slide XML |
| D1 | 29 | yes | SK better: QL grey background, white boxes, list numbers misplaced |
| D1 | 30 | yes | – |
| D1 | 31 | yes | SK better: QL grey background, wrong image, stray line |
| D1 | 32 | yes | SK better: QL grey background, stray box and arrow |
| D1 | 33 | yes | – |
| D1 | 34 | yes | SK better: QL stray arrow |
| D1 | 35 | yes | SK better: QL stray lines |
| D1 | 36 | yes | SK better: QL grey background, stray line |
| D1 | 37 | yes | SK better: QL shows a wrong image (image mix-up) |
| D1 | 38 | yes | – |
| D1 | 39 | yes | SK better: QL wrong image, grey background |
| D1 | 40 | yes | SK better: QL wrong image, grey background |
| D1 | 41 | yes | SK better: QL wrong image, grey background |
| D1 | 42 | yes | SK better: QL wrong image, grey background |
| D1 | 43 | yes | SK better: QL wrong image (image mix-up), grey background |
| D1 | 44 | yes | SK better: QL wrong image (image mix-up), grey background |
| D1 | 45 | yes | SK better: QL wrong image (image mix-up), grey background |
| D1 | 46 | yes | SK better: QL wrong image (image mix-up), grey background |
| D1 | 47 | yes | SK better: QL wrong image (image mix-up), grey background |
| D1 | 48 | yes | SK better: QL wrong image (image mix-up), grey background |
| D1 | 49 | yes | font substitution: one button label breaks into two lines; SK better: QL grey background, stray box and arrow |
| D1 | 50 | yes | – |
| D1 | 51 | yes | fixed (was: one Wingdings arrow drawn as a missing-glyph box) |
| D1 | 52 | yes | SK better: QL grey background |
| D1 | 53 | yes | SK better: QL grey background |
| D1 | 54 | yes | SK better: QL misses a shape |
| D1 | 55 | yes | – |
| D1 | 56 | yes | – |
| D1 | 57 | yes | SK better: QL table overflows the slide, grey background |
| D2 | 1 | yes | SK better: QL misses a shape group in the left box |
| D2 | 2 | yes | – |
| D2 | 3 | yes | – |
| D2 | 4 | yes | – |
| D2 | 5 | yes | SK better: QL table text nearly invisible (wrong colour) |
| D2 | 6 | yes | SK better: QL misses the dark box with check-mark bullets; the label's first letter is covered by a picture above it in z-order (as in the XML) |
| D2 | 7 | yes | SK better: QL shows stray images and a wrong overlay |
| D2 | 8 | yes | SK better: QL wrong icons in the table |
| D2 | 9 | yes | SK better: QL wrong icon (image mix-up) |
| D2 | 10 | yes | SK better: QL wrong image |
| D2 | 11 | yes | SK better: QL misses a whole box with its title |
| D2 | 12 | yes | – |
| D2 | 13 | yes | SK better: QL misses icons, adds a stray ellipse |
| D2 | 14 | yes | SK better: QL stray circle; background gradient of the panel differs |
| D3 | 1 | yes | font substitution: title wraps differently, sits lower |
| D3 | 2 | yes | – |
| D3 | 3 | yes | SK better: QL wrong icon (image mix-up) |
| D3 | 4 | yes | SK better: QL misses the bullets |
| D3 | 5 | yes | SK better: QL covers the slide with ghost boxes |
| D3 | 6 | yes | SK better: QL misses cloud shapes in the middle |
| D3 | 7 | yes | SK better: QL wrong icons, misses the arrow |
| D3 | 8 | yes | SK better: QL text squeezed into narrow columns, ghost box, missing arrow |
| D3 | 9 | yes | – |
| D3 | 10 | yes | – |
| D3 | 11 | yes | SK better: QL misses one button, adds stray lines |
| D3 | 12 | yes | SK better: QL stray box |
| D3 | 13 | yes | SK better: QL ghost boxes cover the slide |
| D3 | 14 | yes | SK better: QL ghost shapes, wrong image |
| D3 | 15 | yes | – |
| D3 | 16 | yes | SK better: QL covers the slide with a wrong, oversized image |
| D3 | 17 | yes | SK better: QL overlays a wrong image and ghost shapes |
| D3 | 18 | yes | – |
| D3 | 19 | yes | SK better: QL ghost boxes, wrong icons |
| D3 | 20 | yes | SK better: QL wrong image (image mix-up) |
| D3 | 21 | yes | SK better: QL ghost boxes, misses clouds |
| D3 | 22 | yes | SK better: QL misses three boxes, wrong images |
| D3 | 23 | yes | SK better: QL misses brackets and numbers |
| D3 | 24 | yes | – |
| D3 | 25 | yes | – |
| D3 | 26 | yes | SK better: QL ghost boxes, wrong image, dashed boxes at the bottom that are not in the slide XML (only the two top boxes are dashed) |
| D3 | 27 | yes | SK better: QL wrong images, misses frames |
| D3 | 28 | yes | SK better: QL ghost boxes |
| D3 | 29 | yes | fixed (was: group scaling stretched 3 pt lines into huge bands covering the slide) |
| D3 | 30 | yes | – |
| D3 | 31 | yes | – |
| D3 | 32 | yes | SK better: QL wrong images, misses cloud shapes and paths |
| D3 | 33 | yes | SK better: QL stray line |
| D3 | 34 | yes | SK better: QL shows round bullets instead of check marks, stray line |
| D3 | 35 | yes | SK better: QL wrong images, title overlapped |
| D3 | 36 | yes | SK better: QL misses the middle panel |
| D3 | 37 | yes | SK better: QL wrong images (image mix-up) |
| D3 | 38 | yes | SK better: QL wrong images (image mix-up) |
| D3 | 39 | yes | SK better: QL misses cloud shapes, stray box |
| D3 | 40 | yes | SK better: QL shows a wrong, oversized image |
| D3 | 41 | yes | – |
| D3 | 42 | yes | – |
| D3 | 43 | yes | white box in the slide XML covers the footer picture (SK follows the XML, QL ignores the box) |
| D3 | 44 | yes | white box in the slide XML covers the footer picture (SK follows the XML, QL ignores the box) |
| D3 | 45 | yes | SK better: QL stray line |
| D3 | 46 | yes | – |
| D3 | 47 | yes | – |
| D3 | 48 | yes | – |
| D3 | 49 | yes | – |
| D3 | 50 | yes | SK better: QL misses two circles, stray lines |
| D3 | 51 | yes | SK better: QL stray line |
| D3 | 52 | yes | SK better: QL stray lines |
| D3 | 53 | yes | – |
| D4 | 1 | yes | – |
| D4 | 2 | yes | SK better: QL covers the slide with a grey ghost box |
| D4 | 3 | yes | – |
| D4 | 4 | yes | – |
| D4 | 5 | yes | SK better: QL overlays a wrong picture |
| D4 | 6 | yes | – |
| D4 | 7 | yes | – |
| D4 | 8 | yes | SK better: QL stray line |
| D4 | 9 | yes | SK better: QL misses a freeform shape, shows round bullets instead of box bullets |
| D4 | 10 | yes | SK better: QL misses the footer picture, adds stray shapes |
| D4 | 11 | yes | – |
| D5 | 1 | yes | font substitution (QL uses a serif fallback) |
| D5 | 2 | yes | SK better: QL misses the layout's green frame shape; serif fallback in QL |
| D5 | 3 | yes | SK better: QL ignores the rotation of the pictures and mixes up texts |
| D5 | 4 | yes | SK better: QL misses the frame shape |
| D5 | 5 | yes | SK better: QL misses the frame shape |
| D5 | 6 | yes | SK better: QL shows shapes from another slide, misses one circle |
| D5 | 7 | yes | SK better: QL draws dotted instead of dashed lines (XML says dash), misses the frame |
| D5 | 8 | yes | SK better: QL overlays shapes from another slide, misses icons |
| D5 | 9 | yes | – |
| D5 | 10 | yes | – |
| D5 | 11 | yes | SK better: QL misses one circle and a label |
| D5 | 12 | yes | SK better: QL misses circles and a label |
| D5 | 13 | yes | SK better: QL misses circles and the divider line |
| D5 | 14 | yes | SK better: QL misses circles and the divider line |
| D5 | 15 | yes | SK better: QL misses circles and the divider line |
| D5 | 16 | yes | SK better: QL misses circles and the divider line |
| D5 | 17 | yes | SK better: QL misses circles and the divider line |
| D5 | 18 | yes | SK better: QL shows a stray circle from another slide |
| D5 | 19 | yes | SK better: QL table rows overflow onto the text below, stray circle |
| D5 | 20 | yes | SK better: QL stray circle covers labels |
| D5 | 21 | yes | SK better: QL stray circles, chart shows one series only |
| D5 | 22 | yes | – |
| D5 | 23 | yes | – |
| D5 | 24 | yes | SK better: QL misses the picture |
| D5 | 25 | no | EMF+-only picture not drawn (out of scope; QL misses it too) |
| D5 | 26 | yes | SK better: QL misses an icon, arrows and connectors |
| D5 | 27 | no | EMF+-only icons not drawn (out of scope); SK better: QL misses one column and breaks the vertical label |
| D5 | 28 | yes | – |
| D5 | 29 | yes | SK better: QL shows a wrong, oversized image |
| D5 | 30 | no | EMF+-only icons not drawn (out of scope); SK better: QL misses the vertical label |
| D5 | 31 | yes | – |
| D5 | 32 | yes | – |
| D5 | 33 | yes | – |
| D5 | 34 | no | EMF+-only icons not drawn (out of scope); SK better: QL breaks the vertical label |
| D5 | 35 | yes | font substitution: two words in small circles break inside the word; SK better: QL misses the centre icon |
| D5 | 36 | yes | – |
| D5 | 37 | yes | SK better: QL stray arrow marks |
| D5 | 38 | yes | font substitution: one label breaks inside the word; SK better: QL shows wrong images (image mix-up) |
| D5 | 39 | yes | SK better: QL stray box over the text |
| D5 | 40 | yes | SK better: QL misses the dark background and the title |
| D5 | 41 | yes | SK better: QL stray boxes |
| D5 | 42 | no | EMF+-only icons not drawn (out of scope); SK better: QL wrong images, misses a column text |
| D5 | 43 | yes | SK better: QL stray circles, misses dashed outlines |
| D5 | 44 | yes | SK better: QL misses the dark background and the title |
| D5 | 45 | yes | – |
| D5 | 46 | no | EMF+-only icons not drawn (out of scope); SK better: QL breaks the vertical label |
| D5 | 47 | yes | SK better: QL adds a circle that is not in the slide XML |
| D5 | 48 | yes | SK better: QL misses the dark background and the title |
| D5 | 49 | yes | SK better: QL misses the curves and the axis label |
| D5 | 50 | yes | SK better: QL stray arcs |
| D5 | 51 | yes | SK better: QL stray circle, misses the centre icon |
| D5 | 52 | yes | SK better: QL misses a box and labels |
| D5 | 53 | yes | black box is the video poster frame (all black in the file) |
| D5 | 54 | yes | SK better: QL stray box covers the text |
| D5 | 55 | yes | – |
| D5 | 56 | yes | SK better: QL misses a shape and icons |
| D5 | 57 | yes | SK better: QL wraps the headings, stray box |
| D5 | 58 | yes | SK better: QL misses shape groups, stray box |
| D5 | 59 | yes | SK better: QL misses the curve, stray shapes |
| D5 | 60 | yes | – |
| D5 | 61 | yes | SK better: QL misses the cycle arrows and the left panel, stray shapes |
| D5 | 62 | yes | SK better: QL stray circles cover text |
| D5 | 63 | yes | SK better: QL stray circle covers pictures |
| D5 | 64 | yes | SK better: QL misses the green arcs, stray circle |
| D5 | 65 | yes | – |
| D6 | 1 | yes | – |
| D6 | 2 | yes | SK better: QL misses the right panel colour and a shape |
| D6 | 3 | yes | SK better: QL text runs out of its cell |
| D6 | 4 | yes | SK better: QL misses the four-box diagram |
| D6 | 5 | yes | SK better: QL misses the step arrows |
| D6 | 6 | yes | SK better: QL ignores the columns, text overflows |
| D6 | 7 | yes | SK better: QL ignores the columns, text overlaps |
| D6 | 8 | yes | SK better: QL ignores the columns, text overlaps |
| D6 | 9 | yes | link colour differs (SK uses the theme's link colour) |
| D7 | 1 | yes | – |
| D7 | 2 | yes | font substitution: body text wraps differently |
| D7 | 3 | yes | font substitution: text in the grey box wraps one line more and runs below the box |
| D7 | 4 | yes | – |
| D7 | 5 | yes | – |
| D7 | 6 | yes | – |
| D7 | 7 | yes | – |
| D7 | 8 | yes | – |
| D7 | 9 | yes | – |
| D7 | 10 | yes | SK better: QL misses the brackets |
| D7 | 11 | yes | SK better: QL stray lines |
| D7 | 12 | yes | SK better: QL stray lines; two pictures are black in both renderers |
| D7 | 13 | yes | SK better: QL shows a wrong image (image mix-up) |
| D7 | 14 | yes | SK better: QL misses brackets, stray line |
| D7 | 15 | yes | first-column cells styled differently from QL (firstCol flag of the deck default style) |
| D7 | 16 | yes | SK better: QL table overflows the slide; header colour differs (table style ID missing from the deck, known fallback to the deck default) |
| D7 | 17 | yes | – |
| D7 | 18 | yes | SK better: QL shows wrong images behind the columns |
| D7 | 19 | yes | SK better: QL overlays a wrong image |
| D7 | 20 | yes | SK better: QL stray line |
| D7 | 21 | yes | SK better: QL stray line |
| D7 | 22 | yes | SK better: QL table overflows onto the footer |
| D7 | 23 | yes | SK better: QL table overflows onto the footer |
| D7 | 24 | yes | SK better: QL misses icons and the dotted frame |

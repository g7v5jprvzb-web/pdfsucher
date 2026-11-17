# PDF Search (iPad)

Eigenständige iPad-App (iPadOS 26, nur Querformat) zum Durchsuchen von PDFs und JPEGs.
Sie teilt weder Code-Abhängigkeiten noch Dateien oder Einstellungen mit der Mac-App PDFSucher:

- eigenes XcodeGen-Projekt `iPad/project.yml` (Ziel „PDFSearch“, Bundle-ID `local.pdfsearch.ipad`, Anzeigename „PDF Search“)
- eigenes Swift-Paket `iPad/Packages/PDFSearchKit` mit einer Kopie von IndexKit, SearchKit, OCRKit und MediaKit
  (Stand PDFSucher 1.4.2) samt deren Tests, für iOS angepasst: Logs unter `Library/Logs/PDFSearch`, Index unter
  `Application Support/PDFSearch`, der FolderScanner listet auf dem iPad nur PDF und JPEG (`imageExtensions`),
  Texterkennung mit höchstens 4000 px Kantenlänge, kein Office
- `Packages/PDFSucherKit` und `project.yml` der Mac-App bleiben unverändert

## Bauen

Voraussetzungen: Xcode 26 mit iOS-26-SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd iPad && xcodegen generate
```

```bash
xcodebuild -project iPad/PDFSearch.xcodeproj -scheme PDFSearch -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

Das Projekt ist ohne Signierung eingestellt (`CODE_SIGNING_ALLOWED: NO`), es baut also nur für den Simulator.

## Auf dem eigenen iPad installieren

1. `cd iPad && xcodegen generate`, dann `iPad/PDFSearch.xcodeproj` in Xcode öffnen.
2. Ziel **PDFSearch** › *Signing & Capabilities*: „Automatically manage signing“ einschalten und als Team dein
   persönliches Team (Apple-ID) wählen. Falls Xcode meldet, die Bundle-ID sei vergeben, eine eigene wählen
   (z. B. `de.<name>.pdfsearch`).
3. In den *Build Settings* des Ziels `Code Signing Allowed` auf **Yes** stellen (im Projekt steht es für den
   Simulator auf No).
4. iPad per Kabel verbinden, auf dem iPad *Einstellungen › Datenschutz & Sicherheit › Entwicklermodus* einschalten,
   oben in Xcode das iPad als Ziel wählen und ▶︎ drücken.
5. Beim ersten Start auf dem iPad: *Einstellungen › Allgemein › VPN & Geräteverwaltung* › dem Entwicklerzertifikat
   vertrauen.

Mit einem kostenlosen persönlichen Team läuft die App 7 Tage, danach erneut aus Xcode installieren.

Damit die Änderungen in Xcode beim nächsten `xcodegen generate` nicht verloren gehen, kann man Team und Signierung
auch in `iPad/project.yml` beim Ziel PDFSearch eintragen (`DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE: Automatic`,
`CODE_SIGNING_ALLOWED: YES`); das ist bewusst nicht eingecheckt.

## Tests

```bash
cd iPad/Packages/PDFSearchKit && xcodebuild -scheme PDFSearchKit-Package -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test
```

```bash
xcodebuild -project iPad/PDFSearch.xcodeproj -scheme PDFSearch -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test
```

- **PDFSearchKit**: die Kern-Tests aus dem Mac-Paket plus iPad-Tests (nur PDF/JPEG, JPEG-Texterkennung mit Rahmen).
- **PDFSearchTests**: Suchbereich („Ganzes iPad“, Ordnerauswahl, Typ), Sortierung, Bookmarks, Einstellungen,
  Kachelzeilen, Sprachsuche mit Rückrufen von Hintergrund-Queues.
- **PDFSearchUITests**: Kachel antippen, vorheriger/nächster Treffer, Vollbild, Baum, Vorschau links/rechts (gemerkt),
  Kachelgröße (gemerkt), Filter, „Ganzes iPad“, Sortierung, Mikrofon ohne/mit Berechtigung, Ordner-Bildschirm,
  keine Treffer, Indizieren nach Hintergrund fortgesetzt. Die Testdateien legt die App per Startargument selbst an
  (erfunden).

Startargumente für Tests und Vorführungen: `-uiTestDemoFiles YES` (Demo-Dateien in den eigenen Ordner),
`-uiTestExtraImages <n>`, `-uiTestResetSettings YES`, `-uiTestBackgroundExpiresAtOnce YES`, `-demoQuery <Text>`,
`-showFolderTree YES|NO`, `-previewOnLeft YES|NO`, `-tileSize <pt>`, `-demoShowFolders YES`.

## Oberfläche

- Kopfzeile: Ordnerbaum ein/aus, Titel, Suchfeld mit Mikrofon (Speech, Deutsch), „Ganzes iPad“,
  Filter Alle/PDF/JPEG, Sortierung (Trefferanzahl, Name, Datum), Vorschau links/rechts tauschen, „Ordner und Index“
- links der Ordnerbaum der freigegebenen Orte (Auswahl filtert die Suche), unten der Indexstatus
- Mitte Trefferkacheln nach Datei, nur Seiten mit Treffern (höchstens 48 je Datei), Größenregler 40–120 pt
- große Vorschau (PDFView mit hervorgehobenen Fundstellen, vorheriger/nächster Treffer; JPEG mit OCR-Rahmen), Vollbild
- „Ordner und Index“: Ordner per Dokumentauswahl (Ordnermodus) freigeben, Security-Scoped Bookmarks,
  Indizieren im Vordergrund mit Fortschritt, Texterkennung für JPEGs (Vision), Liste nicht lesbarer Dateien,
  iCloud-Platzhalter werden vor dem Lesen geladen

„Ganzes iPad“ bedeutet: alle Orte, die der App freigegeben wurden. iPadOS erlaubt keinen Zugriff ohne Freigabe;
„Auf meinem iPad“ und „iCloud Drive“ lassen sich aber als Ganzes freigeben. Der eigene Ordner der App
(Dateien › Auf meinem iPad › PDF Search) ist immer dabei.

## Messwerte (Simulator, iPad Pro 11-inch M5, Debug-Build)

100 erfundene Dateien (60 PDFs mit je 40 Seiten, 40 JPEGs mit 12 MP), Suche mit 1209 Treffern:
indiziert in etwa 40 s, Speicher-Footprint höchstens etwa 375 MB, danach etwa 135 MB.
Ein echtes iPad kann davon abweichen.

## Bekannte Grenzen

- Indizieren läuft nur im Vordergrund. Wechselt die App in den Hintergrund, stoppt der Lauf nach der Schonfrist von
  iPadOS; Erledigtes bleibt, der Rest folgt bei der Rückkehr.
- „Auf meinem iPad“ und iCloud Drive lassen sich nur über die Dokumentauswahl freigeben; die App kann das nicht selbst.
- Die Sprachsuche braucht die Berechtigungen für Spracherkennung und Mikrofon. Im Simulator ist sie nur auf
  „stürzt nicht ab, zeigt Hinweis oder hört zu“ getestet, nicht auf echte Spracheingabe.
- Freigabe per Dokumentauswahl und das Nachladen von iCloud-Dateien sind nicht automatisch getestet (die Systemauswahl
  lässt sich im UI-Test nicht bedienen) und sollten auf einem echten iPad geprüft werden.
- Fehlermeldungen des Systems (z. B. bei nicht lesbaren Dateien) erscheinen in der Sprache des Geräts.
- Der Kern ist eine Kopie des Mac-Kerns (Stand 1.4.2); Fixes dort müssen von Hand übernommen werden.
- Keine Signierung, kein App-Store-Upload.

## Screenshots

Im Simulator mit erfundenen Testdateien, siehe `docs/ipad/`.

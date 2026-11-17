# PDF Search (iPad)

Eigenständige iPad-App (iPadOS 26, nur Querformat) zum Durchsuchen von PDFs und JPEGs.
Sie teilt weder Code-Abhängigkeiten noch Dateien oder Einstellungen mit der Mac-App PDFSucher:

- eigenes XcodeGen-Projekt `iPad/project.yml` (Ziel „PDFSearch“, Bundle-ID `local.pdfsearch.ipad`, Anzeigename „PDF Search“)
- eigenes Swift-Paket `iPad/Packages/PDFSearchKit` mit einer Kopie von IndexKit, SearchKit, OCRKit und MediaKit
  (Stand PDFSucher 1.4.2), für iOS angepasst: Logs unter `Library/Logs/PDFSearch`, Index unter
  `Application Support/PDFSearch`, Bilder nur JPEG, kein Office
- `Packages/PDFSucherKit` und `project.yml` der Mac-App bleiben unverändert

## Bauen

```bash
cd iPad && xcodegen generate
```

```bash
xcodebuild -project iPad/PDFSearch.xcodeproj -scheme PDFSearch -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

Keine Signierung (nur Simulator).

## Oberfläche

- Kopfzeile: Ordnerbaum ein/aus, Titel, Suchfeld mit Mikrofon (Speech, Deutsch), „Ganzes iPad“,
  Filter Alle/PDF/JPEG, Sortierung (Trefferanzahl, Name, Datum), Vorschau links/rechts tauschen, „Ordner und Index“
- links der Ordnerbaum der freigegebenen Orte (Auswahl filtert die Suche), unten der Indexstatus
- Mitte Trefferkacheln nach Datei, nur Seiten mit Treffern, Größenregler 40–120 pt
- große Vorschau (PDFView mit hervorgehobenen Fundstellen, vorheriger/nächster Treffer; JPEG mit OCR-Rahmen), Vollbild
- „Ordner und Index“: Ordner per Dokumentauswahl (Ordnermodus) freigeben, Security-Scoped Bookmarks,
  Indizieren im Vordergrund mit Fortschritt, Texterkennung für JPEGs (Vision), Liste nicht lesbarer Dateien,
  iCloud-Platzhalter werden vor dem Lesen geladen

„Ganzes iPad“ bedeutet: alle Orte, die der App freigegeben wurden. iPadOS erlaubt keinen Zugriff ohne Freigabe;
„Auf meinem iPad“ und „iCloud Drive“ lassen sich aber als Ganzes freigeben. Der eigene Ordner der App
(Dateien › Auf meinem iPad › PDF Search) ist immer dabei.

## Screenshots

Erzeugt mit erfundenen Testdateien (`iPad/scripts/make-demo-files.swift`) im Simulator, siehe `docs/ipad/`.
Startargumente für Vorführungen: `-demoQuery <Text>`, `-showFolderTree YES|NO`, `-previewOnLeft YES|NO`,
`-tileSize <pt>`, `-demoShowFolders YES`.

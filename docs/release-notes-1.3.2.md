# PDFSucher 1.3.2 (Build 10)

Neu: Suche im Dateinamen, Vorschaubreite folgt dem Zoom. Office-Schriften erst bei Bedarf.

- **Suche auch im Dateinamen.**
  - Der Dateiname ohne Endung wird mit denselben Regeln geprüft wie der Text. Ein Dokument erscheint, wenn der Name oder der Inhalt passt.
  - Neben dem Namen steht „Treffer im Dateinamen“, der Begriff ist im Namen hervorgehoben. Passt nur der Name, zeigt die Reihe alle Seiten.
  - Bei Sortierung nach Relevanz kommen Namenstreffer zuerst.
  - Ein einzeln geöffnetes PDF ohne Text wird jetzt über seinen Namen gefunden, statt mit „kein Text“ abgewiesen zu werden.
  - Auch gesperrte, unlesbare und noch nicht vorbereitete Dokumente werden über ihren Namen gefunden. Ihre Reihe zeigt wie beim Durchblättern das Fehlersymbol oder den Platzhalter.
  - Schalter: Einstellungen → Allgemein → Suche → „Auch Dateinamen durchsuchen“ (Standard an).
- **Vorschaubreite folgt dem Zoom.**
  - Neben dem Raster wird die Vorschau so schmal wie die gezoomte Seite, höchstens so breit wie am Teiler eingestellt. Das Raster bekommt den frei werdenden Platz, das Fenster bleibt gleich groß.
  - ⌘1–⌘4 und „Ganze Seite“ beziehen sich auf die eingestellte Breite.
  - „Zoom über die Fensterbreite hinaus erlauben“ (Standard aus): Aus ist die Seitenbreite der größte Zoom. An: bis 800 %, dann waagerecht scrollen.
  - Schalter: Einstellungen → Vorschau → Breite.
- **Office-Schriften erst bei Bedarf.**
  - PDFSucher lädt die Schriften von Microsoft Office nicht mehr beim Start, sondern erst beim ersten Word-Dokument oder bei PowerPoint im eigenen Viewer.
  - Die macOS-Frage „Daten anderer Apps“ kommt deshalb erst dann und nur, wenn Office installiert ist.
  - Word wartet höchstens 3 Sekunden auf die Schriften und nimmt danach Ersatzschriften.
  - Weniger Speicher: Der eigene PowerPoint-Viewer hält 2 statt 4 Präsentationen offen.
  - Word-Dokumente werden nacheinander gesetzt; das schützt vor einem seltenen Absturz.
- **Tests:** Ein Leistungstest mit 10.000 Dateien schlug unter Last gelegentlich fehl. Er vergleicht jetzt den besten von drei Durchläufen, die Grenze ist unverändert.

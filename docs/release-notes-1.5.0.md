# PDFSucher 1.5.0 (Build 25)

Schnellere Texterkennung, keine Hänger mehr bei schwierigen PDFs in der großen Vorschau und ein noch ausführlicheres
Mess-Protokoll.

- **Neuer Index (einmaliger Neuaufbau):** 1.5.0 legt ihren Index in einem eigenen Ordner an
  (`~/Library/Application Support/PDFSucher/Indexes-v6`). Beim ersten Start werden alle Quellen neu indiziert. Der Index
  einer älteren Version bleibt unverändert liegen, eine installierte 1.4.x funktioniert weiter wie bisher.
- **Doppelte Bilder und Scans nur einmal erkennen:** Vor der Texterkennung bildet die App für jede Datei einen
  Prüfwert (SHA-256) und speichert ihn im Index. Ein Bild oder gescanntes PDF, das es schon einmal gibt, übernimmt den
  erkannten Text samt Markierungen, statt neu erkannt zu werden – im selben Lauf und bei späteren Läufen.
- **Mehr Erkennungen gleichzeitig:** eine je Leistungskern, 2 bis 8 (bisher ein Viertel aller Kerne, 2 bis 4). Ein
  M2 Pro erkennt so 6 bzw. 8 Seiten gleichzeitig statt 2 bzw. 3.
- **Große Vorschau ohne Hänger:** Manche PDFs brauchen Sekunden, um eine Seite zu finden. Die Vorschau öffnet PDFs jetzt
  im Hintergrund und zeigt bei solchen Dateien nur die gewählte Seite; vorher konnte die App bis zu 20 Sekunden stehen.
- **Mess-Protokoll:** zusätzlich Treffer und Kandidatenseiten je Dateityp, die Suche in einzelnen Word/PowerPoint-Dateien,
  Öffnen und Sichtbarwerden der großen Vorschau, Wartezeiten an der Word-Satzsperre, Kachelzeiten je Dateityp (aus
  Speicher, Platte oder neu gezeichnet), alle 30 s CPU, Speicher und Temperaturzustand, beim Start die wichtigsten
  Einstellungen. Höchstens 100 MB Protokoll pro Tag, danach nur noch Hänger und Start. Wie bisher ohne Suchbegriffe,
  Dateinamen, Pfade oder Inhalte.

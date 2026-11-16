# PDFSucher 1.3.11 (Build 19)

Fasst zwei Änderungen zusammen: gezieltes Löschen von Indexen und Caches (1.3.10) und schnelleres erstes Indexieren. Enthält auch das Mess-Protokoll aus 1.3.9.

- **Indexe und Caches gezielt löschen** (wie 1.3.10): Einstellungen → Speicher zeigt je Quelle Textindex und Texterkennung sowie verwaiste Indexe, Folien-Cache, Kachel-Cache und Mess-Protokolle mit Größe und eigenem Lösch-Knopf. Im Menü „Quellen (n)“ hat jede Quelle ein Untermenü („Als Quelle entfernen“, „Index löschen und neu aufbauen …“, „Im Finder zeigen“).
- **Schnelleres erstes Indexieren:** Während der Index geschrieben wird, liest PDFSucher schon die nächsten PDFs, und große Dateien kommen zuerst dran. Gemessen an einem echten Ordner mit einigen tausend PDFs: 79 s → 58 s.
- **Mess-Protokoll** (aus 1.3.9, Einstellungen → Speicher): zeigt jetzt auch, wofür beim Schreiben des Index Zeit vergeht und wie lange das Lesen auf das Schreiben wartet.
- Sonst unverändert gegenüber 1.3.10.

# PDFSucher 1.4.1 (Build 22)

Doppelte PDFs werden beim Indexieren nur noch einmal gelesen.

- **Doppelte PDFs nur einmal lesen:** Liegt dieselbe PDF-Datei (Byte für Byte gleich) an mehreren Orten, liest PDFSucher sie beim
  Indexieren nur einmal und übernimmt das Ergebnis für alle Kopien. Jede Kopie bleibt einzeln auffindbar und zeigt dieselben
  Treffer wie vorher. Gemessen an einem echten Ordner mit vielen Kopien: Einlesen der PDFs ≈ 39 s → ≈ 34 s (≈ 13 % schneller).
- Der Index bleibt, wie er ist: keine Umstellung beim ersten Start, kein Neuaufbau.

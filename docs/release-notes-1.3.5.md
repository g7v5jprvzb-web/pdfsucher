# PDFSucher 1.3.5 (Build 13)

Fehlerbehebung und Absicherung nach dem Audit von 1.3.4.

- **Tab springt wieder zurück in die Ordnerleiste.** In 1.3.4 ging Tab von der Ordnerleiste in die Kacheln, aber nicht zurück. Jetzt wechseln Tab und ⇧Tab in beide Richtungen.
- **Weniger Speicher bei großen Dateien und Suchen.**
  - Bilder aus EMF/WMF-Grafiken zählen im Bild-Cache mit ihrer echten Größe.
  - Sehr große Trefferlisten belegen nicht mehr unbegrenzt Speicher.
  - Der Folien-Cache hat eine Obergrenze nach Größe; Bilder ohne lesbare Größe werden begrenzt dekodiert.
- **Robustere Office-Dateien.** Word und PowerPoint nutzen einen gemeinsamen ZIP-Leser, der zu lange Datenströme ablehnt; XML mit Entity-Deklarationen wird nicht mehr ausgewertet.

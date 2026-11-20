# PDFSucher 1.5.1 (Build 26)

Korrekturen nach dem Mess-Protokoll von 1.5.0.

- **Texterkennung wieder schneller:** 1.5.0 ließ bis zu 8 Erkennungen gleichzeitig laufen; auf einem M2 Pro wurde jede
  dadurch etwa dreimal langsamer, insgesamt fast doppelt so lang. Jetzt nach Prozessor: Max/Ultra 4, alle anderen wie vor
  1.5.0 (ein Viertel der Kerne, 2 bis 4; M2 Pro: 3). Doppelte Bilder und Scans werden weiterhin nur einmal erkannt.
- **Schwierige PDFs in der großen Vorschau:** Die gewählte Seite erscheint jetzt nach einmal wenigen Sekunden statt nach
  bis zu 50 Sekunden; weitere Seiten derselben Datei kommen schnell.
- **Word-Kacheln warten nicht mehr auf das Laden eines anderen Dokuments:** Muss für die Vorschau oder eine Kachel ein
  Word-Dokument erst gesetzt werden, lässt das bereits gesetzte Seiten zwischendurch zeichnen.
- **Mess-Protokoll:** Prozessorname und Zahl der gleichzeitigen Erkennungen beim Start.

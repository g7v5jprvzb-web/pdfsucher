# PDFSucher 1.3.4 (Build 12)

Neu: Kacheln in der Form der Seite, Ordnerzahlen nach Dateityp, Tab nach Wahl, schnellere große Vorschau.

- **Kacheln in der Form der Seite.**
  - Jede Reihe richtet ihre Kacheln nach dem Format der ersten Seite aus. Querformat behält die Breite und wird niedriger, so passen mehr Reihen auf den Bildschirm.
  - PowerPoint startet im Format 16:9.
- **Ordnerzahlen folgen dem Dateityp-Filter.**
  - Die Ordnerleiste zählt nur Dateien der gewählten Dateitypen.
  - Ordner ohne passende Datei bleiben stehen, werden aber grau angezeigt.
- **Tab nach Wahl.**
  - Tab springt standardmäßig zwischen Ordnerleiste und Kacheln.
  - Einstellungen → Tastatur: „Tab erreicht auch das Suchfeld“ und „Tab erreicht auch die Vorschau“ (beide Standard aus). Darunter steht die aktuelle Reihenfolge.
  - Die Reihenfolge ist immer Suchfeld → Ordner → Kacheln → Vorschau. Ohne Ordnerleiste springt Tab zwischen Kacheln und Vorschau, wenn die Vorschau zugeschaltet ist.
  - Wer früher „Tab überspringt das Suchfeld“ ausgeschaltet hatte, startet mit „Tab erreicht auch das Suchfeld“ an.
- **Schnellere große Vorschau beim Blättern.**
  - Beim Wechsel mit Pfeiltasten, ‹ › oder Klick gibt es keinen Ladekreisel und keine leere Fläche mehr. Sofort erscheint ein vorbereitetes Bild der Seite, sonst die vergrößerte Kachel oder eine leere Seite im richtigen Format. Die scharfe Seite folgt gleich danach.
  - Die nächste und die vorige Trefferseite werden im Hintergrund vorbereitet.
  - Gemessen beim normalen Blättern: Die Seite ist im Mittel nach 32–42 ms zu sehen statt nach rund 75 ms, fast immer gleich scharf mit Markierungen.
  - Beim schnellen Blättern durch Scans erscheint jede Seite sofort (im Mittel 6 ms); vorher blieb bei gut der Hälfte der Ladekreisel stehen, und die Oberfläche hing bis 0,3 s.
  - Bleibt man auf einem großen Schwarz-Weiß-Scan stehen, hält macOS die Oberfläche danach weiterhin kurz (~0,26 s) an, wenn die scharfe Seite übernimmt.

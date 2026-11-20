# PDFSucher 1.4.3 (Build 24)

Ein ausführlicheres Mess-Protokoll, damit sich langsame Indizierung, langsame Suche und Hänger beim Start untersuchen lassen.

- **Mess-Protokoll standardmäßig an:** Das Protokoll der Indizierung ist jetzt ohne Zutun eingeschaltet (ausschaltbar unter
  Einstellungen → Speicher → Messung). Es misst zusätzlich jede Suche (Dauer, Zeit bis zu den ersten Zeilen, je Quelle),
  die Startphasen und wo eine Quelle liegt (interne/externe Platte, Netzlaufwerk, iCloud Drive). Wie bisher ohne
  Suchbegriffe, Dateinamen, Pfade oder Inhalte.
- **Hänger-Wächter:** Reagiert die App länger als 0,25 s nicht, steht das im Protokoll; dauert es länger als 1 s, nimmt die
  App eine Momentaufnahme mit `sample` auf (höchstens drei je Sitzung).
- **„Mess-Protokolle exportieren …“:** neuer Knopf unter Einstellungen → Speicher → Messung, packt alle Protokolle in eine
  ZIP-Datei (Vorschlag: Schreibtisch), z. B. zum Weitergeben.
- **7 Tage Aufbewahrung:** Protokolle, die älter als 7 Tage sind, löscht die App beim Start.

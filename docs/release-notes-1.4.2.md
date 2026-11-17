# PDFSucher 1.4.2 (Build 23)

Behebt leere Ergebniszeilen und bringt ein Diagnose-Protokoll für die Ergebnisliste.

- **Leere Ergebniszeilen behoben:** Manchmal blieb unter einem Dateinamen der Platz für die Seiten leer (keine Kacheln,
  kein Hinweis), meist bei Zeilen weiter unten, die schon vorbereitet waren, bevor sie ins Bild kamen. Die Zeile zeigt ihre
  Seiten jetzt immer, sobald sie sichtbar wird. Der Index war nie betroffen.
- **Diagnose-Protokoll für Ergebniszeilen:** Neuer Schalter unter Einstellungen → Speicher → Messung („Diagnose-Protokoll für
  Ergebniszeilen schreiben“, aus bei Standard). Er schreibt den Aufbau der Ergebniszeilen nach
  `~/Library/Logs/PDFSucher/ui-rows-<Datum>.jsonl` und meldet Zeilen, die länger als 2 Sekunden leer bleiben. Wie beim
  Mess-Protokoll ohne Dateinamen, Pfade oder Inhalte. „Mess-Protokolle löschen“ löscht beide Protokolle.

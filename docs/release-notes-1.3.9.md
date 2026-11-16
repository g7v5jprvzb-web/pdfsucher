# PDFSucher 1.3.9 (Build 17)

Mess-Protokoll für die Indizierung, damit sich echte Wartezeiten nachmessen lassen.

- **Neue Einstellung** unter Einstellungen → Speicher → Messung: „Mess-Protokoll für Indizierung schreiben“ (Standard: aus). Alternativ im Terminal: `defaults write local.pdfsucher indexMetricsEnabled -bool YES` (wirkt beim nächsten Start).
- **Protokoll:** `~/Library/Logs/PDFSucher/index-metrics-<JJJJ-MM-TT>.jsonl`, eine JSON-Zeile je Ereignis (Ordnerscan, Abgleich, jede Datei, jedes DB-Schreiben, jedes Word-/PowerPoint-Layout, jede OCR-Seite, Läufe mit Auslöser, Unterbrechungen, ersetzte Quellen, doppelt verarbeitete Dateien).
- **Datenschutz:** keine Dateiinhalte, kein Text, keine Datei- oder Ordnernamen. Dateien und Ordner erscheinen nur als kurzer Prüfwert (die ersten 12 Zeichen von SHA-256 des Pfads) plus Dateiendung.
- **Auswertung:** `scripts/index-metrics-report.py` (Python 3, ohne Zusatzpakete) fasst alle Protokolle zusammen: Zeit je Phase, Durchsatz, langsamste Dateien, Läufe nach Auslöser, Unterbrechungen, Doppelarbeit. `--json` für maschinenlesbare Ausgabe.
- Ausgeschaltet kostet das Protokoll praktisch nichts. Sonst unverändert gegenüber 1.3.8.

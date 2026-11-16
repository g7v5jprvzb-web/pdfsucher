# PDFSucher 1.3.10 (Build 18)

Mehr Möglichkeiten, Indexe und Caches gezielt zu löschen. Baut auf 1.3.9 (Mess-Protokoll) auf.

- **Einstellungen → Speicher** zeigt jetzt je Eintrag die belegte Größe und einen eigenen Lösch-Knopf mit Rückfrage:
  - *Je Quelle* (Auswahl „Quelle“: ein Ordner oder alle): **Textindex** (Größe, „Löschen …“ – wird danach sofort neu aufgebaut) und **Texterkennung (OCR)** (Anzahl erkannter Seiten/Bilder, „Neu erkennen …“).
  - *Caches und Protokolle*: **Verwaiste Indexe** (Indexdateien von Ordnern, die nicht mehr als Quelle geladen sind), **Folien-Cache (Word/PowerPoint)**, **Kachel-Cache (Seitenbilder)**, **Mess-Protokolle**. Darunter: belegt insgesamt.
  - Quellen und Einstellungen bleiben beim Löschen immer erhalten. Index, OCR-Zahlen und Protokolle werden alle 3 Sekunden aktualisiert, solange der Reiter offen ist.
- **Quellen (n)** in der Symbolleiste: jeder Eintrag ist jetzt ein Untermenü mit „Als Quelle entfernen“, „Index löschen und neu aufbauen …“ (nur Ordner) und „Im Finder zeigen“. Ein echter Rechtsklick auf einen Menüeintrag ist unter macOS nicht möglich (Menüs behandeln ihn wie einen Klick), deshalb das Untermenü.
- Ordnerleiste: der Kontextmenüeintrag heißt jetzt ebenfalls „Index löschen und neu aufbauen …“.

# PDFSucher 1.3.1 (Build 9)

Korrekturen zu 1.3.0.

- **Kein Dialog mehr zum Ordner „Downloads“ beim Start.**
  - Der Kachel-Cache fragte beim Start die Original-PDFs aller gespeicherten Kacheln ab, auch in Ordnern, die keine Quelle sind.
  - Jetzt löscht er Kacheln außerhalb der Quellen, ohne diese Dateien anzufassen.
  - Kacheln innerhalb einer Quelle prüft wie bisher deren Indexlauf.
  - Ein abgezogenes Laufwerk behält seine Kacheln, solange es als Quelle gemerkt ist.
- **Weiterhin einmalig:** die Frage „Daten anderer Apps“. Sie kommt, wenn Microsoft Office installiert ist, weil PDFSucher dessen Schriften für PowerPoint-Folien liest.
- **Logo:** Das App-Symbol (Lupe mit „ABC“) war schon in 1.3.0 enthalten. Zeigt macOS noch das alte Symbol, hilft ein Neustart des Docks; der Symbol-Cache des Systems war veraltet.
- **Tests:** Die Oberflächen-Tests nutzen einen eigenen, leeren Kachel-Cache und laden keine Office-Schriften vor. So stört kein macOS-Dialog den Testlauf.

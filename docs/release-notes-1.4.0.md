# PDFSucher 1.4.0 (Build 21)

Weniger doppelte Arbeit beim Indexieren, Word früher durchsuchbar.

- **Elternordner übernimmt Unterordner:** Lädt man einen Ordner, dessen Unterordner schon einmal Quelle war, wird deren fertiger Index übernommen statt alles neu zu lesen. Gemessen: Dokumente-Ordner nach seinem größten Unterordner 36 s → 21 s.
- **Verschobene und umbenannte Dateien** werden wiedererkannt und nicht neu gelesen; Texterkennung und Word-/PowerPoint-Seiten bleiben erhalten (100 verschobene PDFs: 0,4 s → 0,01 s).
- **Word sofort durchsuchbar:** Der Text von Word-Dateien (.docx) ist schon nach dem Einlesen durchsuchbar; die genaue Seite und die Markierung kommen, sobald das Dokument gesetzt ist. Gemessen: Word-Inhalte nach 36 s statt nach 82 s auffindbar.
- **Klick auf einen Ort unter „Orte“** lädt den Ordner sofort, ohne Rückfrage (bei „Beim Hinzufügen von Quellen: Fragen“; „Ersetzen“ ersetzt weiterhin). Ziehen und ⌘O fragen wie bisher.
- **Gewählter Ordner zuerst:** Ist ein Unterordner in der Ordnerleiste gewählt, kommen Wortteil-Suche, Word/PowerPoint und Texterkennung dort zuerst dran.
- **Änderungen auf der Platte** werden nur in den betroffenen Ordnern neu abgeglichen; ein laufendes Setzen von Word/PowerPoint wird dafür nicht mehr abgebrochen.
- **Texterkennung** arbeitet auf Macs mit vielen Kernen mit bis zu 4 Seiten gleichzeitig (gemessen +29 % Seiten/s, gleiche Erkennung).
- Bestehende Indexe werden beim ersten Start umgestellt, nicht neu aufgebaut. **Hinweis:** Eine ältere Version (1.3.x) baut einen so umgestellten Index beim Öffnen komplett neu auf.

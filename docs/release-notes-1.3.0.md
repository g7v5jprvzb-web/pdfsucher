# PDFSucher 1.3.0 (Build 8)

Zusammengefasst seit 1.2.3. 1.2.4 erscheint nicht als eigene Version und ist hier enthalten.

## Wichtig beim ersten Start

- **Index wird neu aufgebaut:** Das Index-Schema ist jetzt Version 3, bei 1.2.x war es Version 2. Beim ersten Start löscht die App den Index jeder Ordnerquelle und baut ihn neu auf.
- **Texterkennung läuft erneut:** Der Text gescannter Seiten und Bilder steckte im alten Index. Er wird deshalb noch einmal im Hintergrund erkannt. Das kann bei großen Ordnern eine Weile dauern; die Suche funktioniert dabei schon.
- **Zugriffsdialoge:** macOS kann beim ersten Start fragen, ob PDFSucher auf Daten anderer Apps oder auf den Ordner „Downloads“ zugreifen darf. Auslöser ist, dass die App beim Start die Schriften für Office-Dateien vorbereitet (Office-Schriften, Liste der installierten Schriften). Ohne die Erlaubnis funktioniert die Suche weiter, Folien zeichnen dann eventuell mit Ersatzschriften.

## Neu: Word und PowerPoint

- Word- und PowerPoint-Dateien (docx, docm, dotx, pptx, pptm) werden gefunden, durchblättert, in der großen Vorschau gezeigt und mit ausgegeben. Das gilt auch für einzelne Dateien als Quelle.
- **PowerPoint:** Die Folien zeichnet standardmäßig die eigene Darstellung (SlideKit), wahlweise Quick Look. Fehlende Schriften werden wie in PowerPoint ersetzt, wahlweise durch eine ähnliche Schrift. Ist Office installiert, nutzt die App dessen Schriften.
- **Word:** Eine vereinfachte Darstellung, als „vereinfacht“ gekennzeichnet. Der Text ist vollständig durchsuchbar.
- **Filter „Dateitypen“:** Er wirkt auf Suche und Blättern. Ausgeblendete Dateien stehen in der Zusammenfassung („· N ausgeblendet“).
- **Reiter „Word/PowerPoint“** in den Einstellungen: Office an oder aus, Darstellung, Schriften, Zählungen, „Folien-Cache leeren“.
- Das Original lässt sich mit der Standard-App öffnen.

## Neu: Ordnerleiste (⌃⌘S)

- **Aufbau:** Der Baum aller Ordnerquellen mit Dateizahlen, dazu „Orte“ (Home, Schreibtisch, Dokumente, Downloads und angeschlossene Volumes).
- **Filter:** Ein Klick filtert auf einen Ordner, ⌘-Klick auf mehrere. Die Kopfzeile über dem Raster zeigt den Filter, bei einer Suche als „x von y Dateien“.
- **Änderungen im Finder:** Der Baum folgt Umbenennungen und Löschungen nach etwa 1–2 s, ohne Neustart.
- **Volumes:** Ein ausgeworfenes Volume zeigt „nicht erreichbar“ und wird nach dem Einhängen wieder aktuell.
- **Aufklappen:** Der Aufklapp-Zustand bleibt gespeichert. Ein von außen gewählter Ordner, etwa über „Orte“, wird aufgeklappt und in den sichtbaren Bereich gescrollt.
- **Tastatur:** Tab wechselt zwischen Baum, Vorschau und Raster.

## Einstellungen

- **Neuer Reiter „Speicher“:** Er enthält „Index löschen …“ und „Kachel-Cache leeren“. Damit passt „Allgemein“ wieder ohne Scrollen ins Fenster.
- **Fenstergröße:** Das Einstellungsfenster lässt sich jetzt wirklich vergrößern, und ein Reiterwechsel behält die Größe.

## Aus 1.2.4

- Korrekturen am Kachel-Cache.
- Größeres Einstellungsfenster.
- Anklickbare Symbole im Suchfeld.

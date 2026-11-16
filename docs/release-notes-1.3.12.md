# PDFSucher 1.3.12 (Build 20)

Nach dem Hinzufügen eines großen Ordners kann man deutlich früher suchen.

- **Suche schneller bereit:** Der Index für Wortteil-Suchen (`*ab*`, `*ab`) wird jetzt erst nach dem Einlesen im Hintergrund aufgebaut. Gemessen an einem echten Ordner mit einigen tausend PDFs: normale Suche nach 36 s statt nach 56 s nutzbar; der Hintergrundaufbau dauert danach noch etwa 24 s.
- **Keine Lücken:** Wortteil-Suchen finden auch während des Aufbaus alles. Sie können in dieser Zeit langsamer sein (gemessen 0,4–1,3 s statt 0,1 s); hinter der Trefferzahl steht dann „Wortteil-Suche kann gerade langsamer sein“.
- **Statuszeile:** „Wortteil-Suche wird vorbereitet … (x %)“, solange der Aufbau läuft. Neues Einlesen hat Vorrang; der Aufbau setzt danach (auch nach einem Neustart) dort fort, wo er war.
- **Bestehende Indexe bleiben** und werden nicht neu aufgebaut.
- Mess-Protokoll und Auswertung zeigen den Hintergrundaufbau als eigene Phase „Wortteil-Index“.
- Sonst unverändert gegenüber 1.3.11.

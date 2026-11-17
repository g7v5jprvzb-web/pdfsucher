#!/usr/bin/env python3
"""Auswertung des Diagnose-Protokolls der Ergebniszeilen (ui-rows-*.jsonl, ab 1.4.2).

    scripts/ui-rows-report.py                 # alle Dateien in ~/Library/Logs/PDFSucher/
    scripts/ui-rows-report.py a.jsonl b.jsonl
    scripts/ui-rows-report.py --json

Nur Python-Standardbibliothek. Dateien erscheinen im Protokoll nur als Hash (file) und Endung (ext).
Zeigt: Zeilen, Platzhalter, hängende Zeilen (row_stuck) mit Zustand, Zeit bis zur Seitenform und bis zum Neuzeichnen.
"""
import argparse
import glob
import json
import os
import statistics
import sys
from collections import Counter
from datetime import datetime

DEFAULT_DIR = os.path.expanduser("~/Library/Logs/PDFSucher")


def parse_ts(ts):
    """App-Zeitstempel wie 2026-11-17T19:20:23.849+0100 (auch ohne Sekundenbruchteil) in Unix-Sekunden."""
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(ts, fmt).timestamp()
        except ValueError:
            pass
    return 0.0


def load(paths):
    events = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    print(f"{path}:{n}: keine gültige JSON-Zeile, übersprungen", file=sys.stderr)
                    continue
                event["_t"] = parse_ts(event["ts"]) if "ts" in event else 0.0
                events.append(event)
    events.sort(key=lambda e: e["_t"])
    return events


def stats(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "median_ms": round(statistics.median(values), 1), "max_ms": round(max(values), 1)}


def analyse(events):
    by = Counter(e.get("event") for e in events)
    starts = [{k: e.get(k) for k in ("ts", "version", "build")} for e in events if e.get("event") in ("app_start", "logging_on")]
    files = {e["file"] for e in events if e.get("event") == "row_built" and "file" in e}
    placeholder_builds = [e for e in events if e.get("event") == "row_built" and e.get("placeholder")]
    shape_ms = [e["ms"] for e in events if e.get("event") == "shape_loaded" and "ms" in e]
    shape_sources = Counter(e.get("source") for e in events if e.get("event") == "shape_loaded")
    redraw_reasons = Counter(e.get("reason") for e in events if e.get("event") == "row_redraw")

    # Platzhalter bis Neuzeichnen: erster row_built mit Platzhalter je Datei, bis zum nächsten row_redraw dieser Datei.
    waiting = {}
    to_redraw = []
    never_redrawn = []
    for e in events:
        file = e.get("file")
        if e.get("event") == "row_built" and e.get("placeholder") and file not in waiting:
            waiting[file] = e
        elif e.get("event") == "row_redraw" and file in waiting:
            to_redraw.append((e["_t"] - waiting.pop(file)["_t"]) * 1000)
        elif e.get("event") == "row_built" and not e.get("placeholder") and file in waiting:
            to_redraw.append((e["_t"] - waiting.pop(file)["_t"]) * 1000)
    never_redrawn = [{"file": f, "ext": e.get("ext"), "row": e.get("row"), "gen": e.get("gen"), "seit": e.get("ts")}
                     for f, e in waiting.items()]

    stuck = [{k: v for k, v in e.items() if not k.startswith("_") and k != "event"}
             for e in events if e.get("event") == "row_stuck"]
    return {
        "sitzungen": starts,
        "ereignisse": dict(by),
        "zeilen": len(files),
        "suchergebnisse": by.get("hits", 0),
        "platzhalter_gebaut": len(placeholder_builds),
        "form_laden": {**stats(shape_ms), "quelle": dict(shape_sources)},
        "platzhalter_bis_neuzeichnen": stats(to_redraw),
        "neuzeichnen_gruende": dict(redraw_reasons),
        "nie_neugezeichnet": never_redrawn,
        "haengend": stuck,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*")
    parser.add_argument("--json", action="store_true", help="Ergebnis als JSON")
    args = parser.parse_args()
    paths = args.files or sorted(glob.glob(os.path.join(DEFAULT_DIR, "ui-rows-*.jsonl")))
    if not paths:
        print(f"Keine Protokolle (ui-rows-*.jsonl) in {DEFAULT_DIR}. Diagnose-Protokoll eingeschaltet?", file=sys.stderr)
        return 1
    result = analyse(load(paths))
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    print(f"Dateien: {', '.join(os.path.basename(p) for p in paths)}")
    for s in result["sitzungen"]:
        print(f"  Start {s['ts']}  Version {s['version']} ({s['build']})")
    print(f"Ergebnislisten: {result['suchergebnisse']}   Zeilen (verschiedene Dateien): {result['zeilen']}")
    print(f"Zeilen mit Platzhalter gebaut: {result['platzhalter_gebaut']}")
    f = result["form_laden"]
    if f["n"]:
        print(f"Seitenform geladen: {f['n']}×, Median {f['median_ms']} ms, Max {f['max_ms']} ms, Quelle {f['quelle']}")
    r = result["platzhalter_bis_neuzeichnen"]
    if r["n"]:
        print(f"Platzhalter bis Neuzeichnen: {r['n']}×, Median {r['median_ms']} ms, Max {r['max_ms']} ms")
    if result["neuzeichnen_gruende"]:
        print(f"Neuzeichnen, Gründe: {result['neuzeichnen_gruende']}")
    print(f"Hängende Zeilen (row_stuck): {len(result['haengend'])}")
    for s in result["haengend"]:
        print(f"  {s.get('ts')}  Zeile {s.get('row')} (Ergebnisliste {s.get('gen')})  Datei {s.get('file')}.{s.get('ext')}  "
              f"sichtbar {s.get('visible_ms')} ms, Form gespeichert={s.get('shape_stored')}, "
              f"Abfrage offen={s.get('lookup_pending')}, Aufbauten={s.get('builds')}, "
              f"letztes Neuzeichnen={s.get('last_redraw', '–')} vor {s.get('last_redraw_ms', '–')} ms")
    if result["nie_neugezeichnet"]:
        print(f"Platzhalter ohne späteres Neuzeichnen (nicht unbedingt sichtbar gewesen): {len(result['nie_neugezeichnet'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

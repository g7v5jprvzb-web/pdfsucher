#!/usr/bin/env python3
"""Auswertung des PDFSucher-Mess-Protokolls (index-metrics-*.jsonl, ab 1.3.9).

    scripts/index-metrics-report.py                 # alle Dateien in ~/Library/Logs/PDFSucher/
    scripts/index-metrics-report.py a.jsonl b.jsonl
    scripts/index-metrics-report.py --json

Nur Python-Standardbibliothek. Zeiten in Sekunden; „Summe“ addiert die Dauer je Datei/Seite (parallel laufende
Arbeit zählt mehrfach), „Wandzeit“ ist die echte Laufzeit der Phase.
"""
import argparse
import glob
import json
import os
import sys
from collections import Counter, defaultdict

DEFAULT_DIR = os.path.expanduser("~/Library/Logs/PDFSucher")
DB_PARTS = ["lock_wait_ms", "lookup_ms", "delete_old_ms", "document_ms", "pages_fts_ms", "commit_ms"]
DB_LABELS = {"lock_wait_ms": "Warten auf Schreibverbindung", "lookup_ms": "Dokument suchen",
             "delete_old_ms": "alte Seiten löschen (+FTS)", "document_ms": "documents-Zeile",
             "pages_fts_ms": "Seiten + FTS5 (ab 1.3.12 nur Wort)", "commit_ms": "Commit (+WAL-Checkpoint)"}
PHASES = ["Scan", "Diff", "PDF-Text", "Word-Text (vorläufig)", "DB-Schreiben", "Wortteil-Index", "Layout Word", "Layout PowerPoint", "OCR"]


def load(paths):
    events = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    print(f"{path}:{n}: kaputte Zeile übersprungen", file=sys.stderr)
    events.sort(key=lambda e: e.get("ts", ""))
    return events


def phase_of(e):
    """Phase name of one per-item event, or None."""
    ev = e.get("event")
    if ev == "scan":
        return "Scan"
    if ev == "diff":
        return "Diff"
    if ev == "db_batch":
        return "DB-Schreiben"
    if ev == "wordparts_batch":
        return "Wortteil-Index"
    if ev == "file" and e.get("kind") == "pdf":
        return "PDF-Text"
    if ev == "file" and e.get("kind") == "word":
        return "Word-Text (vorläufig)"
    if ev == "layout_file":
        return "Layout Word" if e.get("kind") == "word" else "Layout PowerPoint"
    if ev == "ocr_page":
        return "OCR"
    return None


def analyse(events):
    stats = {p: {"sum_ms": 0.0, "count": 0, "pages": 0, "items": []} for p in PHASES}
    wall = Counter()            # phase_end wall per text/layout/ocr
    triggers = Counter()
    run_end = Counter()
    preempts = Counter()
    preempt_ms = 0.0
    discarded = Counter()       # layout results thrown away: cancelled / timeout / fileChanged
    discarded_ms = 0.0
    reindexed = Counter()
    reindexed_ms = 0.0
    replaced = []
    db_split = Counter()
    seen = {}
    log_repeats = Counter()
    log_repeat_ms = 0.0
    dedup = Counter()           # pdf-dubletten: copies taken over (files, pages) and hashing in phase_end
    starts = [e for e in events if e.get("event") in ("app_start", "logging_on")]

    for e in events:
        ev = e.get("event")
        ms = float(e.get("ms", 0) or 0)
        phase = phase_of(e)
        if phase:
            s = stats[phase]
            s["sum_ms"] += ms
            s["count"] += 1
            if ev in ("db_batch", "wordparts_batch"):
                s["pages"] += e.get("pages", 0)
            elif ev == "ocr_page":
                s["pages"] += 1
            else:
                s["pages"] += e.get("pages", 0) or 0
            if ev in ("file", "layout_file", "ocr_page"):
                label = f'{e.get("file", "?")}.{e.get("ext", "")}' + (f' S.{e["page"] + 1}' if "page" in e else "")
                s["items"].append((ms, label, e.get("result") or e.get("status", "")))
                # The same file version done twice across all loaded logs (other sessions too).
                if (e.get("result") or "ok") == "ok" and (ev != "file" or e.get("kind") == "pdf"):
                    key = (ev, e.get("file"), e.get("bytes"), e.get("mtime"), e.get("page"))
                    if key in seen:
                        log_repeats[phase] += 1
                        log_repeat_ms += ms
                    seen[key] = True
        if ev == "db_batch":
            for k in DB_PARTS:
                db_split[k] += float(e.get(k, 0) or 0)
            db_split["chars"] += e.get("chars", 0) or 0
        if ev == "file" and e.get("dedup"):
            dedup["copy_pages"] += e.get("pages", 0) or 0
        if ev == "phase_end":
            wall[e.get("phase")] += float(e.get("wall_ms", 0))
            if e.get("phase") == "text":
                dedup["copies"] += e.get("dedup", 0) or 0
                dedup["hashed"] += e.get("hashed", 0) or 0
                dedup["hash_ms"] += float(e.get("hash_ms", 0) or 0)
        elif ev == "run_start" and e.get("phase") == "text":
            for t in str(e.get("trigger", "unknown")).split("+"):
                triggers[t] += 1
        elif ev == "run_end":
            run_end[f'{e.get("phase")}:{e.get("outcome")}'] += 1
        elif ev == "preempt":
            preempts[f'{e.get("phase")} wegen {e.get("reason")}'] += 1
            preempt_ms += float(e.get("elapsed_ms", 0))
        elif ev == "layout_file" and e.get("result") in ("cancelled", "timeout", "fileChanged"):
            discarded[e["result"]] += 1
            discarded_ms += ms
        elif ev == "reindexed_file":
            reindexed[e.get("phase")] += 1
            reindexed_ms += ms
        elif ev == "source_replaced":
            replaced.append(e)

    wall_by_phase = {"Scan": None, "Diff": None, "DB-Schreiben": None}
    for p in ("Scan", "Diff", "DB-Schreiben"):
        wall_by_phase[p] = stats[p]["sum_ms"]       # serial: sum = wall
    wall_by_phase["PDF-Text"] = wall["text"] or None   # phase 1 as a whole (scan, diff and db included)
    wall_by_phase["OCR"] = wall["ocr"] or None
    wall_by_phase["Wortteil-Index"] = wall["wordparts"] or None
    total = sum(s["sum_ms"] for s in stats.values()) or 1.0
    phases = []
    for p in PHASES:
        s = stats[p]
        secs = s["sum_ms"] / 1000
        phases.append({
            "phase": p, "sum_s": round(secs, 3),
            "wall_s": None if wall_by_phase.get(p) is None else round(wall_by_phase[p] / 1000, 3),
            "count": s["count"], "pages": s["pages"],
            "pages_per_s": round(s["pages"] / secs, 2) if secs > 0 and s["pages"] else None,
            "share_pct": round(100 * s["sum_ms"] / total, 1),
            "slowest": [{"ms": ms, "file": label, "result": r} for ms, label, r in sorted(s["items"], reverse=True)[:10]],
        })
    return {
        "files": None,
        "events": len(events),
        "app_starts": [{k: e.get(k) for k in ("ts", "event", "version", "build", "cores", "macos")} for e in starts],
        "phases": phases,
        "layout_wall_s": round(wall["layout"] / 1000, 3),
        "runs_by_trigger": dict(triggers.most_common()),
        "runs_by_outcome": dict(run_end.most_common()),
        "preempts": dict(preempts.most_common()),
        "preempted_runtime_s": round(preempt_ms / 1000, 3),
        "discarded_layouts": dict(discarded),
        "discarded_layout_s": round(discarded_ms / 1000, 3),
        "reindexed_in_session": dict(reindexed),
        "reindexed_in_session_s": round(reindexed_ms / 1000, 3),
        "repeated_across_logs": dict(log_repeats),
        "repeated_across_logs_s": round(log_repeat_ms / 1000, 3),
        "db_split_s": {k: round(db_split[k] / 1000, 3) for k in DB_PARTS},
        "db_chars": int(db_split["chars"]),
        "dedup_copies": int(dedup["copies"]),
        "dedup_copy_pages": int(dedup["copy_pages"]),
        "dedup_hashed": int(dedup["hashed"]),
        "dedup_hash_s": round(dedup["hash_ms"] / 1000, 3),
        "sources_replaced": len(replaced),
        "replaced_documents": sum(e.get("old_documents", 0) for e in replaced),
    }


def fmt(v, digits=2):
    if v is None:
        return "—"
    return f"{v:.{digits}f}" if isinstance(v, float) else str(v)


def print_report(r):
    print(f'Dateien: {len(r["files"])}  Ereignisse: {r["events"]}')
    for s in r["app_starts"]:
        print(f'  {s["event"]} {s["ts"]}  Version {s["version"]} ({s["build"]}), {s["cores"]} Kerne, {s["macos"]}')
    print()
    head = f'{"Phase":<18} {"Summe s":>9} {"Wand s":>9} {"Anzahl":>7} {"Seiten":>7} {"Seiten/s":>9} {"Anteil":>7}'
    print(head)
    print("-" * len(head))
    for p in r["phases"]:
        print(f'{p["phase"]:<18} {fmt(p["sum_s"]):>9} {fmt(p["wall_s"]):>9} {p["count"]:>7} {p["pages"]:>7} '
              f'{fmt(p["pages_per_s"]):>9} {fmt(p["share_pct"], 1) + " %":>7}')
    print(f'(Wandzeit PDF-Text = ganze Phase 1; Layout gesamt Wandzeit {fmt(r["layout_wall_s"])} s; '
          f'Anteil = an der Summe aller Phasen)')
    for p in r["phases"]:
        if p["slowest"]:
            print(f'\nLangsamste – {p["phase"]}:')
            for item in p["slowest"]:
                print(f'  {item["ms"]:>10.1f} ms  {item["file"]:<28} {item["result"]}')

    def block(title, data):
        print(f"\n{title}:")
        if not data:
            print("  keine")
        for k, v in data.items():
            print(f"  {k:<40} {v}")

    db_total = sum(r["db_split_s"].values())
    if db_total > 0:
        print("\nDB-Schreiben aufgeteilt:")
        for k, v in r["db_split_s"].items():
            print(f'  {DB_LABELS[k]:<34} {v:>9.2f} s {100 * v / db_total:>6.1f} %')
        print(f'  geschriebener Text: {r["db_chars"] / 1e6:.1f} MB')

    block("Läufe (Phase 1) nach Auslöser", r["runs_by_trigger"])
    block("Läufe nach Ergebnis", r["runs_by_outcome"])
    block("Unterbrechungen (preempt)", r["preempts"])
    print(f'  bisherige Laufzeit der unterbrochenen Schritte: {fmt(r["preempted_runtime_s"])} s')
    block("Verworfene Layouts", r["discarded_layouts"])
    print(f'  verlorene Zeit: {fmt(r["discarded_layout_s"])} s')
    print("\nDoppelarbeit:")
    print(f'  erneut verarbeitet (in einer App-Sitzung): {sum(r["reindexed_in_session"].values())} '
          f'{r["reindexed_in_session"] or ""}  verlorene Zeit {fmt(r["reindexed_in_session_s"])} s')
    print(f'  gleiche Dateiversion mehrfach in den Logs:  {sum(r["repeated_across_logs"].values())} '
          f'{r["repeated_across_logs"] or ""}  verlorene Zeit {fmt(r["repeated_across_logs_s"])} s')
    print(f'  PDF-Dubletten übernommen (nicht gelesen): {r["dedup_copies"]} Dateien, {r["dedup_copy_pages"]} Seiten; '
          f'gehasht {r["dedup_hashed"]} Dateien in {fmt(r["dedup_hash_s"])} s (Wand)')
    print(f'  Quellen durch Elternordner ersetzt: {r["sources_replaced"]} '
          f'(Dokumente im alten Index, die neu indexiert werden: {r["replaced_documents"]})')


def main():
    ap = argparse.ArgumentParser(description="Auswertung des PDFSucher-Mess-Protokolls")
    ap.add_argument("files", nargs="*", help=f"jsonl-Dateien (Standard: {DEFAULT_DIR}/index-metrics-*.jsonl)")
    ap.add_argument("--json", action="store_true", help="Ergebnis als JSON")
    args = ap.parse_args()
    files = args.files or sorted(glob.glob(os.path.join(DEFAULT_DIR, "index-metrics-*.jsonl")))
    if not files:
        sys.exit(f"Keine Protokolldateien gefunden in {DEFAULT_DIR}")
    report = analyse(load(files))
    report["files"] = files
    if args.json:
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        print_report(report)


if __name__ == "__main__":
    main()

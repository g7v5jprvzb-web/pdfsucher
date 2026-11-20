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


def median(values):
    v = sorted(values)
    return None if not v else (v[len(v) // 2] if len(v) % 2 else (v[len(v) // 2 - 1] + v[len(v) // 2]) / 2)


def analyse_ui(events):
    """1.4.3: searches, main-thread hangs, launch phases, storage of the sources."""
    searches = [e for e in events if e.get("event") == "search" and not e.get("cancelled")]
    during = [e for e in searches if e.get("indexing", "none") != "none"]
    hangs = [e for e in events if e.get("event") == "main_hang"]
    hang_phase = Counter(e.get("phase", "?") for e in hangs)
    return {
        "search": {
            "count": len(searches), "cancelled": sum(1 for e in events if e.get("event") == "search" and e.get("cancelled")),
            "total_ms_median": median([e.get("total_ms", 0) for e in searches]),
            "total_ms_max": max((e.get("total_ms", 0) for e in searches), default=None),
            "first_rows_ms_median": median([e.get("first_rows_ms", 0) for e in searches]),
            "first_rows_ms_max": max((e.get("first_rows_ms", 0) for e in searches), default=None),
            "during_indexing_pct": round(100 * len(during) / len(searches), 1) if searches else None,
            "during_indexing_total_ms_median": median([e.get("total_ms", 0) for e in during]),
            "slowest_sources": sorted(({k: e.get(k) for k in ("ts", "source", "candidates", "db_ms", "check_ms", "names_ms",
                                                               "hits", "total_ms")}
                                       for e in events if e.get("event") == "search_source"),
                                      key=lambda e: e.get("total_ms") or 0, reverse=True)[:5],
        },
        "main_hang": {
            "count": len(hangs), "sum_ms": round(sum(e.get("ms", 0) for e in hangs), 1),
            "max_ms": max((e.get("ms", 0) for e in hangs), default=None), "by_phase": dict(hang_phase.most_common()),
            "longest": sorted(({k: e.get(k) for k in ("ts", "ms", "since_launch_ms", "phase", "last_launch_phase", "sample")}
                               for e in hangs), key=lambda e: e["ms"] or 0, reverse=True)[:5],
        },
        "preview_open": sorted(({k: e.get(k) for k in ("ts", "file", "pages", "way", "probe_ms", "ms")}
                                for e in events if e.get("event") == "preview_open"), key=lambda e: e["ms"] or 0, reverse=True)[:10],
        "launch_phases": [{k: e.get(k) for k in ("ts", "name", "ms", "source", "open_ms")}
                          for e in events if e.get("event") == "launch_phase"],
        "source_storage": {e.get("source"): {k: e.get(k) for k in ("volume_local", "volume_internal", "volume_type", "ubiquitous")}
                           for e in events if e.get("event") == "source_storage"},
        "not_local": {e.get("source"): e.get("not_local") for e in events if e.get("event") == "scan" and "not_local" in e},
    }


def print_ui(u):
    s = u["search"]
    print(f'\nSuche: {s["count"]} fertig, {s["cancelled"]} abgebrochen')
    if s["count"]:
        print(f'  gesamt ms Median {fmt(s["total_ms_median"], 1)}, Max {fmt(s["total_ms_max"], 1)}; '
              f'erste Zeilen ms Median {fmt(s["first_rows_ms_median"], 1)}, Max {fmt(s["first_rows_ms_max"], 1)}')
        print(f'  während Indizierung: {fmt(s["during_indexing_pct"], 1)} % (Median gesamt {fmt(s["during_indexing_total_ms_median"], 1)} ms)')
        for e in s["slowest_sources"]:
            print(f'  Quelle {e["source"]}: {fmt(e["total_ms"], 1)} ms (DB {fmt(e["db_ms"], 1)}, Prüfen {fmt(e["check_ms"], 1)}, '
                  f'Namen {fmt(e["names_ms"], 1)}), {e["candidates"]} Kandidatenseiten, {e["hits"]} Treffer')
    h = u["main_hang"]
    print(f'\nHänger Hauptthread: {h["count"]}, zusammen {fmt(h["sum_ms"] / 1000)} s, längster {fmt(h["max_ms"], 1)} ms')
    for k, v in h["by_phase"].items():
        print(f"  Phase {k:<12} {v}")
    for e in h["longest"]:
        print(f'  {e["ts"]}  {fmt(e["ms"], 1):>9} ms  ab Start {fmt(e["since_launch_ms"], 1)} ms  Phase {e["phase"]}  '
              f'nach {e["last_launch_phase"] or "—"}' + (f'  Sample {e["sample"]}' if e.get("sample") else ""))
    print("\nVorschau geöffnet (langsamste):")
    if not u["preview_open"]:
        print("  keine")
    for e in u["preview_open"]:
        print(f'  {e["ts"]}  {e["file"]}  {e["pages"]} Seiten  {e["way"]:<11}  Suche {fmt(e["probe_ms"], 1)} ms, gesamt {fmt(e["ms"], 1)} ms')
    print("\nStartphasen (ms seit Prozessstart):")
    if not u["launch_phases"]:
        print("  keine")
    for e in u["launch_phases"]:
        extra = f'  Quelle {e["source"]} geöffnet in {fmt(e["open_ms"], 1)} ms' if e.get("source") else ""
        print(f'  {e["ts"]}  {e["name"]:<18} {fmt(e["ms"], 1):>10}{extra}')
    print("\nSpeicherort der Quellen:")
    if not u["source_storage"]:
        print("  keine")
    for src, v in u["source_storage"].items():
        nl = u["not_local"].get(src)
        print(f'  {src}: {v["volume_type"]}, lokal {v["volume_local"]}, intern {v["volume_internal"]}, iCloud {v["ubiquitous"]}'
              + (f', nicht geladen {nl}' if nl is not None else ""))


def analyse_150(events):
    """1.5.0: per file type, single files, preview, TextKit lock, tiles, resources, settings, OCR copies."""
    by = lambda name: [e for e in events if e.get("event") == name]
    kinds_hits, kinds_cand = Counter(), Counter()
    pending = []
    for e in by("search_source"):
        kinds_hits.update(e.get("hits_by_kind") or {})
        kinds_cand.update(e.get("candidates_by_kind") or {})
        pending.append(e.get("office_pending", 0))
    files = defaultdict(list)
    outcomes = Counter()
    for e in by("search_file"):
        files[e.get("ext", "?")].append(e.get("ms", 0))
        outcomes[f'{e.get("ext")}:{e.get("outcome")}'] += 1
    previews = defaultdict(list)
    for e in by("preview_open"):
        previews[f'{e.get("ext", "pdf")}/{e.get("way")}'].append(e.get("ms", 0))
    visible = defaultdict(list)
    for e in by("preview_visible"):
        visible[e.get("ext", "?")].append(e.get("ms", 0))

    def sums(name, keyname, values):
        out = {}
        for e in by(name):
            k = e.get(keyname, "?")
            o = out.setdefault(k, {"count": 0, "tags": Counter(), **{f"{v}_sum_ms": 0.0 for v in values}, **{f"{v}_max_ms": 0.0 for v in values}})
            o["count"] += e.get("count", 0)
            o["tags"].update(e.get("tags") or {})
            for v in values:
                o[f"{v}_sum_ms"] += e.get(f"{v}_sum_ms", 0) or 0
                o[f"{v}_max_ms"] = max(o[f"{v}_max_ms"], e.get(f"{v}_max_ms", 0) or 0)
        for o in out.values():
            o["tags"] = dict(o["tags"])
        return out
    res = by("resource")
    ocr_end = [e for e in by("phase_end") if e.get("phase") == "ocr"]
    return {"v150": {
        "hits_by_kind": dict(kinds_hits), "candidates_by_kind": dict(kinds_cand), "office_pending_max": max(pending, default=None),
        "search_file": {k: {"count": len(v), "median_ms": median(v), "max_ms": max(v)} for k, v in files.items()},
        "search_file_outcomes": dict(outcomes),
        "preview_open": {k: {"count": len(v), "median_ms": median(v), "max_ms": max(v)} for k, v in previews.items()},
        "preview_visible": {k: {"count": len(v), "median_ms": median(v), "max_ms": max(v)} for k, v in visible.items()},
        "textkit_lock": sums("textkit_lock", "turn", ["wait", "hold"]),
        "tile_stats": sums("tile_stats", "ext", ["tile"]),
        "resource": {"count": len(res), "cpu_pct_max": max((e.get("cpu_pct", 0) for e in res), default=None),
                     "memory_mb_max": max((e.get("memory_mb", 0) for e in res), default=None),
                     "thermal": dict(Counter(e.get("thermal") for e in res))},
        "settings": [{k: v for k, v in e.items() if k not in ("event", "run")} for e in by("settings")],
        "ocr_copied": sum(e.get("copied", 0) or 0 for e in ocr_end), "ocr_hash_ms": sum(e.get("hash_ms", 0) or 0 for e in ocr_end),
        "log_full": len(by("log_full")),
    }}


def print_150(r):
    v = r["v150"]
    print("\nSuche nach Dateityp (Summe über alle Suchen):")
    print(f'  Treffer: {v["hits_by_kind"] or "keine"}')
    print(f'  Kandidatenseiten: {v["candidates_by_kind"] or "keine"}')
    print(f'  Office-Dokumente noch ohne Layout (max): {fmt(v["office_pending_max"])}')
    print("\nEinzeldateien (Suche):")
    for k, x in v["search_file"].items():
        print(f'  {k:<6} {x["count"]:>5}×  Median {fmt(x["median_ms"], 1)} ms, Max {fmt(x["max_ms"], 1)} ms')
    if v["search_file_outcomes"]:
        print(f'  Ergebnisse: {v["search_file_outcomes"]}')
    print("\nVorschau öffnen / sichtbar:")
    for k, x in v["preview_open"].items():
        print(f'  öffnen {k:<22} {x["count"]:>5}×  Median {fmt(x["median_ms"], 1)} ms, Max {fmt(x["max_ms"], 1)} ms')
    for k, x in v["preview_visible"].items():
        print(f'  sichtbar {k:<20} {x["count"]:>5}×  Median {fmt(x["median_ms"], 1)} ms, Max {fmt(x["max_ms"], 1)} ms')
    print("\nTextKit-Sperre (Word):")
    for k, x in v["textkit_lock"].items():
        print(f'  {k:<8} {x["count"]:>6}×  Warten {fmt(x["wait_sum_ms"] / 1000)} s (max {fmt(x["wait_max_ms"], 1)} ms), '
              f'Halten {fmt(x["hold_sum_ms"] / 1000)} s (max {fmt(x["hold_max_ms"], 1)} ms)')
    print("\nKacheln nach Endung:")
    for k, x in v["tile_stats"].items():
        avg = x["tile_sum_ms"] / x["count"] if x["count"] else 0
        print(f'  {k:<6} {x["count"]:>6}×  Schnitt {avg:.1f} ms, Max {fmt(x["tile_max_ms"], 1)} ms  Herkunft {x["tags"]}')
    rr = v["resource"]
    print(f'\nRessourcen: {rr["count"]} Messungen, CPU max {fmt(rr["cpu_pct_max"])} %, Speicher max {fmt(rr["memory_mb_max"])} MB, '
          f'Temperatur {rr["thermal"]}')
    for e in v["settings"]:
        print(f'Einstellungen {e.get("ts")}: {e}')
    print(f'OCR-Kopien übernommen: {v["ocr_copied"]} (Hash-Zeit {fmt(v["ocr_hash_ms"] / 1000)} s)')
    if v["log_full"]:
        print("Achtung: Tagesgrenze des Protokolls erreicht (danach nur Hänger/Start).")


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
    events = load(files)
    report = analyse(events)
    report["files"] = files
    report.update(analyse_ui(events))
    report.update(analyse_150(events))
    if args.json:
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        print_report(report)
        print_ui(report)
        print_150(report)


if __name__ == "__main__":
    main()

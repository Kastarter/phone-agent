#!/usr/bin/env python3
"""Summarize device runs: outcome, total seconds and per-phase milliseconds for each run.

Usage: trace-report.py device-runs.jsonl fast-agent-trace.log [run-id ...]

device-runs.jsonl holds one JSON object per finished run (id, goal, outcome, seconds, steps, summary, started,
ended). fast-agent-trace.log holds "--- <ISO> run: <goal>" headers followed by "<phase> <ms> ms [note]" lines ("done" is the run total).
A run's trace section is the last header whose time falls in [started - 2 s, ended] (falling back to a goal match).
"""
import json
import re
import sys
from datetime import datetime, timedelta

KNOWN = ["brief", "leave", "home", "move", "aim", "settle", "actor", "model", "plan", "type", "kbd detect", "kbd switch", "type verify", "type keys", "key", "done"]
HEADER = re.compile(r"^--- (\S+) run: ?(.*)$")
PHASE = re.compile(r"^([a-z][a-z ]*?) (-?\d+) ms\b")


def when(text):
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def load_runs(path):
    runs = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                runs.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return runs


def load_sections(path):
    sections = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return sections
    for line in lines:
        m = HEADER.match(line)
        if m:
            sections.append({"at": when(m.group(1)), "goal": m.group(2), "phases": {}})
            continue
        m = PHASE.match(line)
        if m and sections:
            phases = sections[-1]["phases"]
            phases[m.group(1)] = phases.get(m.group(1), 0) + int(m.group(2))
    return sections


def section_for(run, sections):
    start, end = when(run.get("started")), when(run.get("ended"))
    if start and end:
        hits = [s for s in sections if s["at"] and start - timedelta(seconds=2) <= s["at"] <= end + timedelta(seconds=1)]
        if hits:
            return hits[-1]
    goal = (run.get("goal") or "")[:120]
    hits = [s for s in sections if goal and s["goal"] == goal]
    return hits[-1] if hits else None


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    runs, sections = load_runs(argv[1]), load_sections(argv[2])
    wanted = argv[3:]
    if wanted:
        runs = [r for r in runs if r.get("id") in wanted]
    if not runs:
        print("No matching runs.")
        return 1
    matched = [(r, section_for(r, sections)) for r in runs]
    seen = []
    for _, s in matched:
        for name in (s or {}).get("phases", {}):
            if name not in seen:
                seen.append(name)
    columns = [p for p in KNOWN if p in seen] + [p for p in seen if p not in KNOWN]
    head = ["id", "outcome", "total s", "steps"] + [c + " ms" for c in columns]
    rows = []
    for r, s in matched:
        phases = (s or {}).get("phases", {})
        rows.append([str(r.get("id", "")), str(r.get("outcome", "")), f"{float(r.get('seconds', 0)):.1f}",
                     str(r.get("steps", 0))] + [str(phases[c]) if c in phases else "-" for c in columns])
    widths = [max(len(head[i]), *(len(row[i]) for row in rows)) for i in range(len(head))]
    print("  ".join(h.ljust(w) for h, w in zip(head, widths)))
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths)))
    for r, s in matched:
        note = "" if s else "  (no trace section found)"
        print(f"{r.get('id', '')}: {r.get('summary', '')}{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

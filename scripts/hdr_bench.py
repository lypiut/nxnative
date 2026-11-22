#!/usr/bin/env python3
"""Compare SDR and HDR runs from their [hdr-bench] log lines.

Run the game twice with the same save, scene, resolution and warm caches, once with
DM_HDR=0 and once with DM_HDR=auto, both with DM_HDR_BENCH=1. The launcher writes its
log to ~/Library/Logs/nxnative/<title ID>.log on macOS. Then:

    python3 scripts/hdr_bench.py sdr.log hdr.log

IMPORTANT: the host logs one summary per 600 presents, already reduced to p50/p95/p99.
This script therefore reports the MEDIAN OF THE PER-WINDOW PERCENTILES, not the percentile
of all frames in the run. It is a good comparison of steady-state behaviour, but it can
conceal an isolated stutter. The per-window maximum and the counts of frames over 16.67
and 20 ms are printed alongside it to expose those spikes. For a whole-run percentile,
the host would need to log the raw samples; it deliberately does not, to keep the
benchmark off the production path's per-frame cost.
"""
import re
import statistics
import sys
from pathlib import Path

FIELDS = [
    ('frame p50', r'frame ms p50 ([\d.]+)'),
    ('frame p95', r'frame ms p50 [\d.]+ p95 ([\d.]+)'),
    ('frame p99', r'p95 [\d.]+ p99 ([\d.]+)'),
    ('GPU p50', r'GPU ms p50 ([\d.]+)'),
    ('GPU p95', r'GPU ms p50 [\d.]+ p95 ([\d.]+)'),
    ('GPU p99', r'GPU ms p50 [\d.]+ p95 [\d.]+ p99 ([\d.]+)'),
    ('latency p50', r'latency ms p50 ([\d.]+)'),
    ('latency p90', r'latency ms p50 [\d.]+ p90 ([\d.]+)'),
    ('footprint MB', r'footprint ([\d.]+) MB'),
]
EXTRAS = [
    ('frame max (worst window)', r'p99 [\d.]+ \(max ([\d.]+)\)'),
]
COUNTS = [
    ('over 16.67', r'(\d+) over 16\.67'),
    ('over 20', r'(\d+) over 20'),
    ('new PSOs', r'new present pipelines (\d+)'),
]


def windows(path):
    rows = []
    for line in Path(path).read_text(errors='replace').splitlines():
        if '[hdr-bench]' not in line:
            continue
        row = {}
        for name, pattern in FIELDS + EXTRAS + COUNTS:
            m = re.search(pattern, line)
            if m:
                row[name] = float(m.group(1))
        if row:   # a malformed [hdr-bench] line contributes no window
            rows.append(row)
    return rows


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    print('Figures below are medians of per-window percentiles (600 presents each),')
    print('NOT percentiles of the whole run; the worst-window max and over-budget counts show spikes.\n')
    sets = [windows(p) for p in sys.argv[1:3]]
    for label, rows in zip(('SDR', 'HDR'), sets):
        if not rows:
            print(f'{label}: no [hdr-bench] lines (run with DM_HDR_BENCH=1)')
            continue
        print(f'{label}: {len(rows)} windows of 600 presents')
        for name, _ in FIELDS + EXTRAS:
            vals = [r[name] for r in rows if name in r]
            if vals:
                print(f'  {name:26s} {statistics.median(vals):8.2f}')
        for name, _ in COUNTS:
            vals = [r[name] for r in rows if name in r]
            if vals:
                print(f'  {name:26s} {sum(vals):8.0f} total')
    sdr, hdr = sets
    if sdr and hdr and all('frame p50' in r for r in sdr + hdr):
        a = statistics.median(r['frame p50'] for r in sdr)
        b = statistics.median(r['frame p50'] for r in hdr)
        print(f'\nframe p50 delta (median of windows): HDR - SDR = {b - a:+.2f} ms')


if __name__ == '__main__':
    main()

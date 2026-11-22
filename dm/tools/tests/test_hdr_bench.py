"""The SDR/HDR log analysis in scripts/hdr_bench.py: parse the [hdr-bench] line the host writes."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('hdr_bench', REPO / 'scripts/hdr_bench.py')
assert spec is not None and spec.loader is not None
hdr_bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hdr_bench)

LINE = ('[dm] [hdr-bench] presents 600: frame ms p50 16.60 p95 18.20 p99 22.40 (max 35.10), '
        '3 over 16.67 and 1 over 20 of 600; GPU ms p50 9.80 p95 10.40 p99 11.10 of 600; '
        'on-screen latency ms p50 37.4 p90 44.1 max 61.2 of 600; footprint 4231 MB, '
        'new present pipelines 0, HDR on')


class HdrBench(unittest.TestCase):
    def test_parses_one_window(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'run.log'
            p.write_text('unrelated log line\n' + LINE + '\n')
            rows = hdr_bench.windows(p)
        self.assertEqual(len(rows), 1, 'only the [hdr-bench] line is a window')
        row = rows[0]
        self.assertEqual(row['frame p50'], 16.60)
        self.assertEqual(row['frame p95'], 18.20)
        self.assertEqual(row['frame p99'], 22.40)
        self.assertEqual(row['frame max (worst window)'], 35.10)   # the corrected maximum
        self.assertEqual(row['GPU p50'], 9.80)
        self.assertEqual(row['GPU p99'], 11.10)
        self.assertEqual(row['latency p50'], 37.4)
        self.assertEqual(row['latency p90'], 44.1)
        self.assertEqual(row['over 16.67'], 3)
        self.assertEqual(row['over 20'], 1)
        self.assertEqual(row['new PSOs'], 0)

    def test_empty_log_has_no_windows(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'run.log'
            p.write_text('a run with DM_HDR_BENCH unset\n')
            self.assertEqual(hdr_bench.windows(p), [])

    def test_multiple_windows_and_malformed_lines(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'run.log'
            p.write_text(LINE + '\n' + LINE.replace('presents 600', 'presents 1200') + '\n'
                         + '[hdr-bench] this is not a summary line\n')
            rows = hdr_bench.windows(p)
        self.assertEqual(len(rows), 2, 'only well-formed windows are parsed')
        self.assertEqual([r['frame p50'] for r in rows], [16.60, 16.60])

    def test_missing_optional_metrics(self):
        partial = '[hdr-bench] presents 600: frame ms p50 17.10 p95 19.20 p99 24.30 (max 40.00), 4 over 16.67 and 2 over 20 of 600\n'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'run.log'
            p.write_text(partial)
            row, = hdr_bench.windows(p)
        self.assertEqual(row['frame p99'], 24.30)
        self.assertEqual(row['frame max (worst window)'], 40.00)
        self.assertNotIn('GPU p50', row)
        self.assertNotIn('latency p50', row)

    def test_zero_samples_and_empty_inputs(self):
        empty = ('[dm] [hdr-bench] presents 600: frame ms p50 0.00 p95 0.00 p99 0.00 (max 0.00), '
                 '0 over 16.67 and 0 over 20 of 0; GPU ms p50 0.00 p95 0.00 p99 0.00 of 0; '
                 'on-screen latency ms p50 0.0 p90 0.0 max 0.0 of 0; footprint 0 MB, '
                 'new present pipelines 0, HDR off\n')
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'run.log'
            p.write_text(empty)
            row, = hdr_bench.windows(p)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                with mock.patch.object(sys, 'argv', ['hdr_bench.py', str(p), str(p)]):
                    hdr_bench.main()
        self.assertEqual(row['over 20'], 0)
        self.assertIn('medians of per-window percentiles', out.getvalue())
        self.assertIn('NOT percentiles of the whole run', out.getvalue())
        self.assertIn('frame p50 delta', out.getvalue())

    def test_sdr_versus_hdr_comparison_labels(self):
        hdr = LINE
        sdr = LINE.replace('p50 16.60', 'p50 16.66').replace('HDR on', 'HDR off')
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d) / 'sdr.log', Path(d) / 'hdr.log'
            a.write_text(sdr); b.write_text(hdr)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                with mock.patch.object(sys, 'argv', ['hdr_bench.py', str(a), str(b)]):
                    hdr_bench.main()
        text = out.getvalue()
        self.assertIn('SDR: 1 windows', text)
        self.assertIn('HDR: 1 windows', text)
        self.assertIn('frame p50 delta (median of windows): HDR - SDR = -0.06 ms', text)


if __name__ == '__main__':
    unittest.main()

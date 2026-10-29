"""Regression for v0.1.1 cross-process *same slice* TrackEvent guidance.

Static document/fixture checks are not a substitute for real SDK + TP + X5 runs.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def content(path):
    return (ROOT / path).read_text(encoding="utf-8")


class CrossProcessTrackSelectionTests(unittest.TestCase):
    def test_router_mentions_cross_process_same_slice(self):
        src = content("SKILL.md")
        self.assertIn("Track::Global", src)
        self.assertIn("references/02-sdk.md", src)

    def test_contract_distinguishes_global_track_from_global_flow(self):
        src = content("references/01-contract.md")
        for needle in ("Track::Global", "Flow::Global", "TerminatingFlow::Global", "跨进程", "Request ID"):
            with self.subTest(needle=needle):
                self.assertIn(needle, src)
        self.assertIn("未知", src)

    def test_sdk_reference_requires_real_trace_validation(self):
        src = content("references/02-sdk.md")
        for needle in ("Track::Global", "System", "Trace Processor", "TrackDescriptor", "真实"):
            with self.subTest(needle=needle):
                self.assertIn(needle, src)

    def test_minimal_two_process_sample_uses_global_not_process_scoped_track(self):
        src = content("examples/cpp/cross_process_slice_demo.cc")
        self.assertIn("perfetto::Track::Global", src)
        self.assertIn("TRACE_EVENT_BEGIN", src)
        self.assertIn("TRACE_EVENT_END", src)
        self.assertNotIn("perfetto::Track::ProcessScoped", src)
        self.assertIn("PERFETTO_TRACK_EVENT_STATIC_STORAGE", src)
        self.assertIn("TRACE_EVENT_CATEGORY_ENABLED", src)
        self.assertIn("TrackEvent::Flush", src)
        self.assertIn("add_executable(latency_xproc_demo", content("examples/cpp/CMakeLists.txt"))

    def test_acceptance_includes_missing_end_and_collision(self):
        doc = content("tests/SCENARIOS.md")
        for needle in ("Global Track", "丢失 END", "ID 冲突", "不同进程"):
            with self.subTest(needle=needle):
                self.assertIn(needle, doc)

    def test_current_config_and_latency_contract_unchanged(self):
        self.assertIn('enabled_categories: "rdk.latency"', content("configs/track-event.pbtxt"))
        self.assertIn('expected_stage_count', content("references/01-contract.md"))
        self.assertIn('integrity_status', content("SKILL.md"))


if __name__ == "__main__":
    unittest.main()

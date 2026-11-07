import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import analyze_measurements as am  # noqa: E402


def rec(status="ok", expected="Відкрий Телеграм.", transcript="відкрий телеграм", response=0.5, lang="uk", pl="uk"):
    return {"model": "base", "language_setting": lang, "pass": 1, "prompt_index": 0, "prompt_language": pl,
            "expected": expected, "transcript": transcript, "status": status, "timed_out": False,
            "audio_s": 1.0, "whisper_s": 0.3, "response_s": response}


class Tests(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(am.normalize("П’ятдесят, ВІДСОТКІВ!"), ["п'ятдесят", "відсотків"])

    def test_error_rate(self):
        self.assertEqual(am.error_rate(["a", "b"], ["a", "b"]), 0)
        self.assertEqual(am.error_rate(["a", "b"], ["a"]), 0.5)
        self.assertEqual(am.error_rate([], []), 0)

    def test_failures_count_against_accuracy_not_latency(self):
        rows = [rec(), rec(status="error", transcript="", response=0), rec(status="skipped", transcript="", response=0),
                rec(transcript="відкрий телефон", response=1.5)]
        (s,) = am.summarise(rows)
        self.assertEqual(s["attempts"], 4)
        self.assertEqual(s["exact_match"], 0.25)
        self.assertEqual(s["response_s"]["n"], 2)
        self.assertEqual(s["response_s"]["p50"], 1.0)
        self.assertEqual(s["status_counts"]["skipped"], 1)

    def test_groups_by_model_and_language(self):
        self.assertEqual(len(am.summarise([rec(), rec(lang="auto")])), 2)


if __name__ == "__main__":
    unittest.main()

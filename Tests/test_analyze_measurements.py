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

    def test_timeout_with_correct_text_is_failure(self):
        timeout = dict(rec(), timed_out=True)
        (s,) = am.summarise([timeout])
        self.assertEqual(s["exact_match"], 0)
        self.assertEqual(s["mean_wer"], 1)
        self.assertEqual(s["response_s"]["n"], 0)
        self.assertEqual(s["correct_within_2s"], 0)

    def test_deadline_rate_counts_every_attempt(self):
        rows = [rec(response=2), rec(response=2.01), rec(status="error"),
                rec(status="skipped"), dict(rec(), timed_out=True),
                rec(transcript="неправильний текст")]
        (s,) = am.summarise(rows)
        self.assertAlmostEqual(s["correct_within_2s"], 1 / 6)
        self.assertEqual(s["attempts"], 6)
        self.assertEqual(s["completed_response_s"]["n"], 5)

    def test_failed_completion_latency_is_visible(self):
        (s,) = am.summarise([rec(response=0.5), rec(status="error", response=8)])
        self.assertEqual(s["response_s"]["p50"], 0.5)
        self.assertEqual(s["completed_response_s"]["p50"], 4.25)
        self.assertEqual(s["completed_response_s"]["n"], 2)

    def test_groups_by_model_and_language(self):
        self.assertEqual(len(am.summarise([rec(), rec(lang="auto")])), 2)


if __name__ == "__main__":
    unittest.main()

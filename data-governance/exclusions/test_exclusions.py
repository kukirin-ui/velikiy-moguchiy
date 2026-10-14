import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import exclusions  # noqa: E402

GOOD = "UC" + "a" * 22


class Read(unittest.TestCase):
    def parse(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False, encoding="utf-8") as f:
            f.write(text)
        return exclusions.read(Path(f.name))

    def test_published_log_is_valid(self):
        exclusions.read()

    def test_entry_and_comments(self):
        entries = self.parse(f"# comment\n\n{GOOD}\t2026-10-14\n")
        self.assertEqual([(GOOD, exclusions.dt.date(2026, 10, 14))], entries)

    def test_rejects_bad_lines(self):
        for text in (
            f"{GOOD}\n",
            f"UC123\t2026-10-14\n",
            f"https://youtube.com/channel/{GOOD}\t2026-10-14\n",
            f"{GOOD}\t14.10.2026\n",
            f"{GOOD}\t2026-10-14\textra\n",
            f"{GOOD}\t2026-10-14\n{GOOD}\t2026-10-15\n",
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.parse(text)


if __name__ == "__main__":
    unittest.main()

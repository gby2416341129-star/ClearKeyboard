"""Small deterministic checks for the production initial-prefix index builder."""
import struct
import tempfile
import unittest
from pathlib import Path
from prepare_rime import INITIAL_LIMIT, associations, short_initial_words


class InitialIndexTests(unittest.TestCase):
    def test_completion_is_bounded_and_uses_real_phrases(self):
        words = [("道教典籍", "dao jiao dian ji", 100),
                 ("大家都知道", "da jia dou zhi dao", 80)]
        conversation = [("大家都觉得", "da jia dou jue de", 6000)]
        rows = short_initial_words(words, conversation)
        ordered = sorted(rows["djdj"], reverse=True)
        self.assertEqual(ordered[0][2:], ("大家都觉得", "da jia dou jue de"))
        self.assertEqual([row[2] for row in ordered], ["大家都觉得", "道教典籍"])
        self.assertNotIn("dj", rows)  # No two-letter phrase completion.
        self.assertNotIn("大家都觉得", [r[2] for r in rows.get("d", [])])

    def test_index_has_more_than_one_screen_without_unbounded_buckets(self):
        words = [(f"词{i}", "ci shi", i) for i in range(80)]
        rows = short_initial_words(words)
        self.assertEqual(len(rows["cs"]), INITIAL_LIMIT)
        self.assertGreater(INITIAL_LIMIT, 8)
        self.assertEqual(sorted(rows["cs"], reverse=True)[0][1], 79)

    def test_binary_uses_shared_records_and_preserves_ranking(self):
        words = [("大家都觉得", "da jia dou jue de", 6000),
                 ("道教典籍", "dao jiao dian ji", 100)]
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "index.clx"
            associations(words, [], file, [])
            first = file.read_bytes()
            associations(words, [], file, [])
            self.assertEqual(first, file.read_bytes())
            self.assertEqual(first[:8], b"CLRX0001")
            count, keys, index, results, strings, total = struct.unpack_from("<6I", first, 8)
            self.assertEqual(total, len(first))
            # Two continuation records and two shared initial records; the
            # five-syllable word is indexed under both djd and djdj.
            self.assertEqual(count, 4)
            self.assertGreater(keys, 2)
            for i in range(keys):
                offset, length, start, size = struct.unpack_from("<4I", first, index + i*16)
                key = first[strings+offset:strings+offset+length].decode()
                if key == "i:djdj":
                    records = struct.unpack_from(f"<{size}I", first, results+4*start)
                    text = []
                    for record in records:
                        o, n = struct.unpack_from("<2I", first, 32+record*28)
                        text.append(first[strings+o:strings+o+n].decode())
                    self.assertEqual(text, ["大家都觉得", "道教典籍"])


if __name__ == "__main__":
    unittest.main()

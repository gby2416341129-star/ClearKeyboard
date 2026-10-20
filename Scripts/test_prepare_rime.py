"""Small build-data regressions; no simulator or native runtime required."""
import struct
import tempfile
import unittest
from pathlib import Path

from prepare_rime import INITIAL_LIMIT, associations, short_initial_words


class ShortInitialIndexTests(unittest.TestCase):
    def test_top_words_are_bounded_and_conversation_duplicates_replace(self):
        words = [(f"词{i}", "da jia", i) for i in range(40)]
        values = short_initial_words(words, [("词39", "da jia", 1), ("会话", "da jia", 2)])["dj"]
        self.assertEqual(len(values), INITIAL_LIMIT)
        ranked = sorted(values, reverse=True)
        self.assertEqual([row[2] for row in ranked[:2]], ["会话", "词39"])
        self.assertEqual(sum(row[2] == "词39" for row in values), 1)
        self.assertEqual(ranked[2][2], "词38")

    def test_complete_words_and_bounded_initial_prefixes_are_indexed(self):
        values = short_initial_words([
            ("的", "de", 100), ("道教典籍", "dao jiao dian ji", 50),
            ("超过四个字", "chao guo si ge zi", 20),
        ])
        self.assertEqual(set(values), {"d", "djd", "djdj", "cgs", "cgsg"})
        self.assertEqual(values["djdj"][0][2:], ("道教典籍", "dao jiao dian ji"))

    def test_binary_keeps_readings_and_existing_continuations_and_english(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "associations.clx"
            associations([("的", "de", 100), ("道教典籍", "dao jiao dian ji", 50)],
                         [("iphone", 1000)], path)
            data = path.read_bytes()
        self.assertEqual(data[:8], b"CLRX0001")
        count, indexes, index_offset, results, strings, size = struct.unpack_from("<6I", data, 8)
        self.assertEqual(size, len(data))
        self.assertEqual(index_offset, 32 + count * 28)

        def string(offset):
            start, length = struct.unpack_from("<2I", data, offset)
            return data[strings + start:strings + start + length].decode()

        values = {}
        for i in range(indexes):
            base = index_offset + i * 16
            start, length = struct.unpack_from("<2I", data, base + 8)
            entries = struct.unpack_from(f"<{length}I", data, results + start * 4)
            values[string(base)] = [(string(32 + entry * 28 + 8), string(32 + entry * 28 + 16))
                                    for entry in entries]
        self.assertEqual(values["i:d"], [("的", "de")])
        self.assertEqual(values["i:djdj"], [("道教典籍", "dao jiao dian ji")])
        self.assertEqual(values["t:道教"], [("道教典籍", "")])
        self.assertEqual(values["e:iphone"], [("iphone", "")])


if __name__ == "__main__":
    unittest.main()

"""Small build-data regressions; no simulator or native runtime required."""
import struct
import tempfile
import unittest
from pathlib import Path

from prepare_rime import INITIAL_LIMIT, associations, han_character, han_text, reading_aliases, short_initial_words


class ShortInitialIndexTests(unittest.TestCase):
    def test_han_import_includes_zero_and_supplementary_characters(self):
        for text in ['〇', '𠮷', '𬭁', '𰻞', '𫔭', '𭎂', '你好', '鸡𭎂菌', '\uf900', '\U000323b0']:
            self.assertTrue(han_text(text), text)
        for text in ['', 'nihao', '你好!', '😀', '一\ufe00', '\u4dc0', '\U0002f000']:
            self.assertFalse(han_text(text), text)
        self.assertTrue(han_character('嗯'))

    def test_character_aliases_expand_existing_words_and_keep_originals(self):
        words = {('嗯', 'n'): 731821, ('嗯', 'ng'): 434765, ('嗯嗯', 'ng ng'): 1400,
                 ('嗯好的', 'ng hao de'): 540, ('你说嗯', 'ni shuo n'): 120,
                 ('恩', 'en'): 31821, ('你好', 'ni hao'): 50000}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'aliases.tsv'
            path.write_text('嗯\tn\ten\n嗯\tng\ten\n', encoding='utf8')
            expanded, added = reading_aliases(words, path)
        for key, frequency in words.items(): self.assertEqual(expanded[key], frequency)
        self.assertEqual(expanded['嗯', 'en'], 731821)
        self.assertEqual(expanded['嗯嗯', 'en en'], 1400)
        self.assertEqual(expanded['嗯好的', 'en hao de'], 540)
        self.assertEqual(expanded['你说嗯', 'ni shuo en'], 120)
        self.assertNotIn(('你好', 'en hao'), expanded)
        self.assertEqual(len(added), len({(t, p) for t, p, _ in added}))
        self.assertEqual(len(words), 7, 'Building aliases must not mutate the verified source')

    def test_aliases_reject_unverified_readings_and_unbounded_expansion(self):
        for content, words in [('字\tzi\ten\n', {('嗯', 'ng'): 1}),
                               ('嗯\tng\tng\n', {('嗯', 'ng'): 1}),
                               ('嗯\tng\ten en\n', {('嗯', 'ng'): 1}),
                               ('嗯\tng\ten\n', {('嗯', 'ng'): 1, ('嗯'*7, ' '.join(['ng']*7)): 1})]:
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / 'aliases.tsv'; path.write_text(content, encoding='utf8')
                with self.assertRaises(ValueError): reading_aliases(words, path)

    def test_typing_aliases_do_not_inflate_an_existing_character_reading(self):
        words = {('么', 'me'): 153599, ('么', 'mo'): 407, ('什么', 'shen me'): 283934,
                 ('怎么', 'zen me'): 240869, ('摸', 'mo'): 25000}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'aliases.tsv'; path.write_text('么\tme\tmo\n', encoding='utf8')
            expanded, _ = reading_aliases(words, path)
        self.assertEqual(expanded['么', 'mo'], 407)
        self.assertEqual(expanded['摸', 'mo'], 25000)
        self.assertEqual(expanded['什么', 'shen mo'], 283934)
        self.assertEqual(expanded['怎么', 'zen mo'], 240869)

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
                         [("iphone", 1000)], path, full_readings=[('嗯', 'en', 731821), ('嗯嗯', 'en en', 1400)])
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
        self.assertEqual(values["c:en"], [('嗯', 'en')])
        self.assertEqual(values["c:enen"], [('嗯嗯', 'en en')])
        self.assertNotIn('c:ee', values, 'A full-reading alias must not invent an initial abbreviation')


if __name__ == "__main__":
    unittest.main()

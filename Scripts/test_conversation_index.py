import struct
import tempfile
import unittest
from pathlib import Path
from prepare_rime import associations, conversational_words, mixed_spellings


class ConversationIndexTests(unittest.TestCase):
    def test_address_grammar_generalizes_without_adding_or_removing_syllables(self):
        questions = [("你吃饭吗", "ni chi fan ma", 5600), ("你吃饭没", "ni chi fan mei", 5000),
                     ("你在哪里", "ni zai na li", 4400), ("你们在哪里", "ni men zai na li", 4400),
                     ("我已经到了", "wo yi jing dao le", 5800)]
        addresses = [("妈妈", "ma ma"), ("老师", "lao shi"), ("阿姨", "a yi")]
        words = conversational_words(questions, addresses)
        entries = {(t, p): f for t, p, f in words}
        for address, spelling in addresses:
            self.assertIn((address + "你吃饭吗", spelling + " ni chi fan ma"), entries)
            self.assertIn((address + "你在哪里", spelling + " ni zai na li"), entries)
            self.assertNotIn((address + "我已经到了", spelling + " wo yi jing dao le"), entries)
            self.assertNotIn((address + "你们在哪里", spelling + " ni men zai na li"), entries)
        forms = mixed_spellings("ma ma ni chi fan ma")
        for raw in ["mamncfm", "mamancfm", "mmncfm", "mamanichifanma"]:
            self.assertIn(raw, forms)
        self.assertNotIn("mamcfm", forms)

    def test_binary_fast_mixed_rows_match_frequency_and_reading(self):
        words = conversational_words(
            [("你吃饭吗", "ni chi fan ma", 5600), ("你吃饭没", "ni chi fan mei", 5000)],
            [("妈妈", "ma ma"), ("老师", "lao shi")])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "index.clx"
            associations([], [], path, words)
            data = path.read_bytes()
        count, keys, index, results, strings, total = struct.unpack_from("<6I", data, 8)
        self.assertEqual(total, len(data))
        found = {}
        def string(offset):
            start, size = struct.unpack_from("<2I", data, offset)
            return data[strings + start:strings + start + size].decode()
        for i in range(keys):
            offset = index + i * 16
            start, size = struct.unpack_from("<2I", data, offset + 8)
            ids = struct.unpack_from(f"<{size}I", data, results + start * 4)
            found[string(offset)] = [(string(32 + r * 28), string(32 + r * 28 + 16)) for r in ids]
        self.assertEqual(found["c:mamncfm"], [
            ("妈妈你吃饭吗", "ma ma ni chi fan ma"), ("妈妈你吃饭没", "ma ma ni chi fan mei")])
        self.assertEqual(found["c:laosncfm"][0][0], "老师你吃饭吗")
        self.assertNotIn("c:mamcfm", found)
        self.assertEqual(len(set(found["c:mamncfm"])), len(found["c:mamncfm"]))

    def test_spelling_expansion_has_a_fixed_small_bound(self):
        self.assertLessEqual(len(mixed_spellings("ni men jin tian wan shang chi fan")), 256)
        self.assertEqual(mixed_spellings("wo men jin tian wan shang yao qu chi fan"), ())


if __name__ == "__main__":
    unittest.main()

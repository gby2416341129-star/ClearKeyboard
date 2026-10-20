import hashlib,struct,tempfile,unittest,zlib
from pathlib import Path
from exact_initials import write_index,inspect_index,encode,HEADER

class ExactInitialChecks(unittest.TestCase):
    def test_all_readings_deduplicate_without_changing_words(self):
        words=[('词甲','ci jia',20),('词甲','ci jia',90),('词乙','ci yi',1),('嗯','ng',3)]
        digest=hashlib.sha256(b'dictionary fixture').hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'index.idx';record=write_index(words,target,digest);data=target.read_bytes()
            self.assertEqual(record['dictionaryReadings'],4);self.assertEqual(record['uniqueCodes'],3)
            self.assertEqual(set(struct.unpack_from('<3Q',data,64)),{encode('cj'),encode('cy'),encode('n')})
            write_index(list(reversed(words)),target,digest);self.assertEqual(target.read_bytes(),data)
            self.assertEqual(inspect_index(data,digest),record)
            with self.assertRaises(ValueError):inspect_index(data,'00'*32)
            for position in [0,24,64,len(data)-1]:
                bad=bytearray(data);bad[position]^=1
                with self.assertRaises(ValueError):inspect_index(bad,digest)
            with self.assertRaises(ValueError):inspect_index(data[:-1],digest)

    def test_unsupported_readings_cannot_produce_a_partial_index(self):
        with tempfile.TemporaryDirectory() as directory:
            for reading in ['', 'hm', 'nǐ hao', 'ni 2', 'NI hao', ' '.join(['ci']*13)]:
                with self.assertRaises(ValueError):write_index([('词',reading,1)],Path(directory)/'index.idx','01'*32)
            with self.assertRaises(ValueError):write_index([],Path(directory)/'index.idx','01'*32)

    def test_fixed_width_code_has_no_collisions_or_overflow(self):
        codes=['a','aa','ab','ba','z','zz','z'*12]
        self.assertEqual(len(set(map(encode,codes))),len(codes));self.assertLess(encode('z'*12),1<<60)
        for value in ['', 'a'*13, "a'b", 'A', 'n\0g']:
            with self.assertRaises(ValueError):encode(value)

if __name__=='__main__':unittest.main()

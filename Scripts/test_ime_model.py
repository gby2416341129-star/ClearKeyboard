"""Build-time model integrity and reproducibility checks (standard library only)."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from prepare_ime_model import ROOT, ASSETS, NATIVE_SHA256, export, verified


class ModelAssetTests(unittest.TestCase):
    def test_reproducible_export_and_preserved_attribution(self):
        source=ROOT/'.rime-cache/ime-4m/sentence-model.safetensors'
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'model.clm'
            self.assertEqual(export(source,path)['sha256'],NATIVE_SHA256)
            data=path.read_bytes()
        magic,*fields=struct.unpack_from('<8s14I',data)
        self.assertEqual(magic,b'CLMINT01')
        meta_size,vocab_size,tensor_size,checksum=fields[6:10]
        self.assertEqual(64+meta_size+vocab_size+tensor_size,len(data))
        self.assertEqual(zlib.crc32(data[64:]),checksum)
        provenance=json.loads(data[64:64+meta_size])
        self.assertEqual(provenance['source_sha256'],ASSETS['sentence-model.safetensors'])
        metadata=provenance['metadata']
        self.assertEqual(metadata['license'],'Apache-2.0')
        self.assertIn('C4',metadata['attribution'])
        self.assertIn('LCCC',metadata['attribution'])
        self.assertEqual(len(json.loads(metadata['vocab'])),8192)

    def test_corrupt_source_is_rejected_before_export(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'corrupt.safetensors'
            path.write_bytes(b'not a verified model')
            with self.assertRaises(ValueError):
                verified(path,ASSETS['sentence-model.safetensors'])
            with self.assertRaises(ValueError):
                export(path,Path(folder)/'should-not-exist.clm')
            self.assertFalse((Path(folder)/'should-not-exist.clm').exists())


if __name__=='__main__':
    unittest.main()

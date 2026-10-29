from lexical_assets import ROOT, fetch, unicodedata
def main():
    table = ROOT / 'Core/Resources/Phonetics/unicode-pinyin.tsv'
    expected_source = ROOT / '.build/phonetic-source.txt'
    fetch('https://raw.githubusercontent.com/mozillazg/pinyin-data/' + '9d05c9e29cb6a7e5c79f2f5279f5c1014246a19a' + '/pinyin.txt', expected_source, '90c11bd680ccfe7f2617a6e25abdb1fb87b5540df3e6f011ca50aaf3c7263a89')
    rows = []
    for line in expected_source.read_text(encoding='utf-8').splitlines():
        if not line.startswith('U+'): continue
        key, rest = line.split(':', 1)
        readings = []
        for raw in rest.split('#', 1)[0].strip().split(','):
            raw = raw.lower().replace('ü', 'v')
            # Replace tone-marked umlauts before removing other diacritics.
            for marked in 'ǖǘǚǜ': raw = raw.replace(marked, 'v')
            clean = ''.join(c for c in unicodedata.normalize('NFD', raw) if 'a' <= c <= 'z')
            if clean and clean not in readings: readings.append(clean)
        if readings: rows.append(chr(int(key[2:], 16)) + '\t' + ','.join(readings))
    table.parent.mkdir(parents=True, exist_ok=True)
    table.write_text('\n'.join(rows) + '\n', encoding='utf-8')
    expected_source.unlink(missing_ok=True)

if __name__=='__main__':main()

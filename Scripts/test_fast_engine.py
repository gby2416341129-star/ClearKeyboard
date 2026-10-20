"""Run the real Foundation input engine on macOS, without an iOS simulator."""
import os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
os.chdir(ROOT)
build=ROOT/'.build/fast-engine';build.mkdir(parents=True,exist_ok=True)
framework=next(p for p in (ROOT/'.rime-cache/dynamic').rglob('RimeDynamic.framework') if 'macos' in str(p.parent))
for name in ['Rime','pinyin.clx','english.clx','pinyin-corrections.clx','associations.clx']:
 target=build/name
 if not target.exists():target.symlink_to(ROOT/'Core/Resources'/name,target_is_directory=name=='Rime')
library=build/'libclear-test.dylib'
subprocess.run(['c++','-O3','-std=c++17','-dynamiclib','Scripts/test_fast_engine_bridge.cpp','-F',str(framework.parent),
 '-framework','RimeDynamic','-framework','Accelerate','-Wl,-rpath,'+str(framework.parent),'-o',str(library)],check=True)
sources=['Candidate','Lexicon','FuzzyPinyin','Composition','RepetitionModel','InputEngine','RimeDecoder','CoreMLSentence','CoreMLPrefixState','CoreMLCandidateScorer']
subprocess.run(['swiftc','-O','-parse-as-library','-import-objc-header','CRime/include/ClearRime.h',
 *['Core/'+s+'.swift' for s in sources],'Scripts/test_fast_engine.swift','-L',str(build),'-lclear-test',
 '-Xlinker','-rpath','-Xlinker',str(build),'-o',str(build/'test-fast-engine')],check=True)
subprocess.run([str(build/'test-fast-engine')],check=True)

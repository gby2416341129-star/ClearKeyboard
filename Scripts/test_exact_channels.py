"""Real macOS Rime tuple comparison; no simulator or iOS runtime."""
import os,subprocess
from pathlib import Path
from evaluate_decoder import load_cases,variants
root=Path(__file__).resolve().parents[1];os.chdir(root)
build=root/'.build/exact-channels';build.mkdir(parents=True,exist_ok=True)
inputs=build/'inputs.tsv'
inputs.write_text(''.join(case['variant']+'\t'+case['input']+'\n'
    for family in load_cases(root/'Tests/Evaluation/independent_sentences.tsv') if family['split']=='diagnostic'
    for case in variants(family)),encoding='utf8')
framework=next(p for p in (root/'.rime-cache/dynamic').rglob('RimeDynamic.framework') if 'macos' in str(p.parent))
binary=build/'test-exact-channels';user=build/'user';user.mkdir(exist_ok=True)
subprocess.run(['c++','-O3','-UNDEBUG','-std=c++17','Scripts/test_exact_channels.cpp','-F',str(framework.parent),
    '-framework','RimeDynamic','-framework','Accelerate','-Wl,-rpath,'+str(framework.parent),'-o',str(binary)],check=True)
subprocess.run([str(binary),str(root/'Core/Resources/Rime'),str(user),str(inputs)],check=True)

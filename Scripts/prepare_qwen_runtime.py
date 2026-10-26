#!/usr/bin/env python3
"""Build the pinned Qwen3.5-capable llama.cpp static runtime for iPhone."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
COMMIT = 'caa8191df159f764fb0160e3d2fc6be008948aee'
SHA256 = '8b560fcea314772d6c8255e70ab2114706de72b6ce8c73be21c41d189090e908'


def main():
    base = ROOT / '.build' / 'qwen-runtime'
    base.mkdir(parents=True, exist_ok=True)
    archive = base / 'source.tar.gz'
    if not archive.exists() or hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() != SHA256:
        request = urllib.request.Request('https://codeload.github.com/ggml-org/llama.cpp/tar.gz/' + COMMIT,
                                         headers={'User-Agent': 'ClearKeyboard-build/78'})
        with urllib.request.urlopen(request, timeout=120) as source, archive.open('wb') as target:
            shutil.copyfileobj(source, target)
    with archive.open('rb') as source:
        assert hashlib.file_digest(source, 'sha256').hexdigest() == SHA256, 'Runtime source checksum mismatch'
    source = base / ('llama.cpp-' + COMMIT)
    if not source.is_dir():
        with tarfile.open(archive) as package:
            package.extractall(base, filter='data')
    assert 'LLM_TYPE_0_8B' in (source / 'src/models/qwen35.cpp').read_text(), 'Qwen3.5 architecture missing'
    output = base / 'install'
    build = base / 'iphoneos'
    args = ['cmake', '-S', str(source), '-B', str(build), '-G', 'Unix Makefiles',
            '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=iphoneos',
            '-DCMAKE_SYSTEM_PROCESSOR=arm64', '-DCMAKE_OSX_ARCHITECTURES=arm64',
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0', '-DCMAKE_INSTALL_PREFIX=' + str(output),
            '-DBUILD_SHARED_LIBS=OFF', '-DGGML_NATIVE=OFF', '-DGGML_METAL=OFF',
            '-DGGML_BLAS=OFF', '-DGGML_ACCELERATE=ON', '-DGGML_OPENMP=OFF',
            '-DGGML_BACKEND_DL=OFF', '-DGGML_CPU_ALL_VARIANTS=OFF',
            '-DLLAMA_BUILD_COMMON=OFF', '-DLLAMA_BUILD_TESTS=OFF', '-DLLAMA_BUILD_EXAMPLES=OFF',
            '-DLLAMA_BUILD_TOOLS=OFF', '-DLLAMA_BUILD_SERVER=OFF', '-DLLAMA_BUILD_APP=OFF',
            '-DLLAMA_BUILD_MTMD=OFF', '-DLLAMA_OPENSSL=OFF', '-DLLAMA_TOOLS_INSTALL=OFF',
            '-DLLAMA_BUILD_COMMIT=' + COMMIT]
    subprocess.run(args, check=True)
    subprocess.run(['cmake', '--build', str(build), '--config', 'Release', '--parallel', str(min(6, os.cpu_count() or 2))], check=True)
    subprocess.run(['cmake', '--install', str(build), '--config', 'Release'], check=True)
    for library in ['llama', 'ggml', 'ggml-base', 'ggml-cpu']:
        assert (output / 'lib' / ('lib' + library + '.a')).is_file(), library
    # A matching local binary target keeps Package.swift on this same runtime.
    combined = base / 'libLlamaRuntime.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(combined)] +
                   [str(output / 'lib' / ('lib' + name + '.a')) for name in ['llama', 'ggml', 'ggml-base', 'ggml-cpu']], check=True)
    framework = base / 'llama.xcframework'
    if framework.exists(): shutil.rmtree(framework)
    subprocess.run(['xcodebuild', '-create-xcframework', '-library', str(combined),
                    '-headers', str(output / 'include'), '-output', str(framework)], check=True)
    shutil.copyfile(source / 'LICENSE', ROOT / 'Licenses/llama-cpp.txt')
    print('Pinned Qwen3.5 iPhone runtime compiled.', flush=True)


if __name__ == '__main__':
    main()

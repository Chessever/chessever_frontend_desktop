"""Build the self-contained Windows helper from repository source.
Run with Python 3.11 on a Visual Studio Build Tools host. No runtime Python needed.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
BUILD = ROOT.parents[1] / 'build' / 'cbh_converter'
CMAKE = Path(os.environ.get('CMAKE', 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'))


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    venv = BUILD / 'venv'
    if not (venv / 'Scripts/python.exe').exists():
        run(sys.executable, '-m', 'venv', venv)
    python = venv / 'Scripts/python.exe'
    run(python, '-m', 'pip', 'install', '-r', ROOT / 'requirements-build.txt')
    run(CMAKE, '-S', ROOT / 'native', '-B', BUILD / 'native', '-A', 'x64')
    run(CMAKE, '--build', BUILD / 'native', '--config', 'Release', '--clean-first')
    native = BUILD / 'native/Release/cbh_decode.exe'
    run(python, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--noupx',
        '--name', 'chessever_cbh', '--exclude-module', 'pkg_resources', '--exclude-module', 'setuptools',
        '--distpath', BUILD / 'dist', '--workpath', BUILD / 'pyinstaller',
        '--specpath', BUILD, '--add-binary', str(native) + ';.', ROOT / 'converter.py')
    bundle = BUILD / 'dist/chessever_cbh'
    notices = bundle / 'notices'
    notices.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'NOTICE.md', notices)
    shutil.copy2(ROOT / 'native/LICENSE', notices / 'libcbh-COPYING.txt')
    # Preserve every per-file notice and the corresponding modified native source.
    shutil.copytree(ROOT / 'native', notices / 'native-source', dirs_exist_ok=True)
    for package in ('chess', 'pyinstaller'):
        code = ('import importlib.metadata as m, pathlib, shutil; d=m.distribution(' + repr(package) + '); '
                '[(shutil.copy2(d.locate_file(f), pathlib.Path(' + repr(str(notices)) + ')/(' + repr(package + '-') + '+pathlib.Path(f).name))) '
                'for f in d.files if "license" in str(f).lower() or "copying" in str(f).lower()]')
        run(python, '-c', code)
    shutil.copy2(Path(sys.base_prefix) / 'LICENSE.txt', notices / 'Python-LICENSE.txt')
    manifest = {str(p.relative_to(bundle)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in bundle.rglob('*') if p.is_file()}
    (bundle / 'SHA256.json').write_text(json.dumps(manifest, indent=2), encoding='utf8')
    # Exercise the frozen executable, not merely the interpreter/source path.
    run(bundle / 'chessever_cbh.exe', '--help')
    print('Built self-contained CBH helper: ' + str(bundle))


if __name__ == '__main__':
    main()

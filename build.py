#!/usr/bin/env python3
"""Build a portable Apple Silicon app from already-downloaded local assets."""
import argparse
import json
import re
import plistlib
import shutil
import subprocess
from pathlib import Path

here = Path(__file__).resolve().parent
rtranslate = here.parent / 'RTranslate'
parser = argparse.ArgumentParser()
parser.add_argument('--seed-app', type=Path, help='既存のRSpeech.appから音声実行環境を再利用')
parser.add_argument('--output', type=Path, default=here / 'dist/RSpeech.app')
args = parser.parse_args()
app = args.output.resolve()
contents = app / 'Contents'
macos, resources = contents / 'MacOS', contents / 'Resources'
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)


def copy_tree(source, target, ignore=None):
    shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True, ignore=ignore)


seed = (args.seed_app or here / 'dist/RSpeech.app').resolve() / 'Contents/Resources'
if resources != seed and seed.is_dir() and not (resources / 'Python').exists():
    copy_tree(seed, resources, ignore=shutil.ignore_patterns('voicevox', '__pycache__', '*.pyc'))

python_source = rtranslate / 'dist/SafariPreview/RTranslate.app/Contents/Resources/Python'
if not python_source.is_dir():
    python_source = Path('/Applications/RTranslate.app/Contents/Resources/Python')
if not (resources / 'Python/bin/python3.13').is_file():
    if not python_source.is_dir():
        raise SystemExit('ビルド用のRTranslate Pythonがありません。完成済みRSpeech.appはビルドせずに使えます。')
    # Keep Python's standard library and VOICEVOX; translation/ML packages are unnecessary.
    copy_tree(python_source, resources / 'Python', ignore=shutil.ignore_patterns('site-packages', '__pycache__', '*.pyc'))
    site = python_source / 'lib/python3.13/site-packages'
    dest = resources / 'Python/lib/python3.13/site-packages'
    dest.mkdir(parents=True, exist_ok=True)
    for source in sorted(site.glob('voicevox_core*')):
        copy_tree(source, dest / source.name, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))

# Models and dictionary belong only to RTranslate's Application Support folder.
# Remove a model directory inherited from an older generated app before signing.
old_models = resources / 'voicevox'
if old_models.is_symlink():
    old_models.unlink()
elif old_models.exists():
    shutil.rmtree(old_models)

runtime_dir = resources / 'VoiceRuntime'
runtime_dir.mkdir(exist_ok=True)
if not list(runtime_dir.glob('libvoicevox_onnxruntime*.dylib')):
    source = next((rtranslate / 'Resources/VoiceRuntime/lib').glob('libvoicevox_onnxruntime*.dylib'), None)
    if source is None:
        source = next(Path('/Applications/RTranslate.app/Contents/Resources/VoiceRuntime/lib').glob('libvoicevox_onnxruntime*.dylib'))
    shutil.copy2(source, runtime_dir / source.name)
runtime = sorted(runtime_dir.glob('libvoicevox_onnxruntime*.dylib'))[0]
license_source = rtranslate / 'Resources/VOICEVOX-LICENSE'
if license_source.is_dir():
    copy_tree(license_source, resources / 'VOICEVOX-LICENSE')
shutil.copy2(here / 'Design/RSpeech.icns', resources / 'RSpeech.icns')
copy_tree(here / 'licenses', resources / 'licenses') if (here / 'licenses').is_dir() else None
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macos14.0', '-file-prefix-map', str(here) + '=/RSpeech', '-O', str(here / 'Main.swift'), str(here / 'Pronunciation.swift'), '-o', str(macos / 'RSpeech'), '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'AVFoundation'], check=True)
shutil.copy2(here / 'worker.py', resources / 'worker.py')
shutil.copy2(here / 'PageExtraction.js', resources / 'PageExtraction.js')
shutil.copy2(here / 'Dictionary/common-ja.json', resources / 'common-ja.json')
(resources / 'runtime.json').write_text(json.dumps({'python': 'Python/bin/python3.13', 'runtime': str(runtime.relative_to(resources))}))
info = {'CFBundleIdentifier': 'local.flop.RSpeech', 'CFBundleName': 'RSpeech', 'CFBundleDisplayName': 'RSpeech', 'CFBundleExecutable': 'RSpeech', 'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'RSpeech.icns', 'CFBundleShortVersionString': '1.3.0', 'CFBundleVersion': '6', 'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True, 'NSAppleEventsUsageDescription': 'Safariの現在のページの本文を取得して、端末内のVOICEVOXで読み上げます。'}
with (contents / 'Info.plist').open('wb') as f:
    plistlib.dump(info, f)
# The standalone interpreter has no libpython dependency. Do not ship its unused
# development library, which contains build-machine metadata.
for name in ('libpython3.13.dylib', 'libpython3.13.a'):
    unused = resources / 'Python/lib' / name
    if unused.exists():
        unused.unlink()
# Remove the seed interpreter's machine-specific build prefix from public metadata.
for config in (resources / 'Python/lib/python3.13').glob('_sysconfigdata*.py'):
    text = config.read_text()
    text = re.sub(r'/Users/[^/]+/\.local/share/uv/python/[^/"\s]+', '__RSPEECH_PYTHON_PREFIX__', text)
    if '__RSPEECH_PYTHON_PREFIX__' in text and 'import sys as _rspeech_sys' not in text:
        text += "\nimport sys as _rspeech_sys\nbuild_time_vars = {k: v.replace('__RSPEECH_PYTHON_PREFIX__', _rspeech_sys.base_prefix) if isinstance(v, str) else v for k, v in build_time_vars.items()}\n"
    config.write_text(text)
# Finder metadata copied from the existing distribution cannot be code-signed.
for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
    subprocess.run(['/usr/bin/xattr', '-rd', attribute, str(app)], capture_output=True)
# Sign native nested code before sealing the outer app; no private certificates used.
for binary in sorted((resources / 'Python').rglob('*')):
    if binary.is_file() and not binary.is_symlink() and (binary.suffix in ('.so', '.dylib') or binary.parent.name == 'bin'):
        if subprocess.run(['/usr/bin/file', '-b', str(binary)], capture_output=True, text=True).stdout.startswith('Mach-O'):
            subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True, capture_output=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(runtime)], check=True, capture_output=True)
for attempt in range(3):
    for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
        subprocess.run(['/usr/bin/xattr', '-rd', attribute, str(app)], capture_output=True)
    signed = subprocess.run(['codesign', '--force', '--sign', '-', str(app)], capture_output=True, text=True)
    if signed.returncode == 0:
        break
else:
    raise SystemExit(signed.stderr)
assert not (resources / 'voicevox').exists()
assert not list(resources.rglob('*.vvm'))
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)

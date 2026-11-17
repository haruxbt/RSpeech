#!/usr/bin/env python3
"""Regression: punctuation in one word must not discard a page's word list."""
import argparse
import json
import re
import subprocess
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
resources = parser.parse_args().app.resolve() / 'Contents/Resources'
root = Path(__file__).resolve().parent.parent
rows = json.loads((root / 'Dictionary/common-ja.json').read_text())['entries']
words = [r['word'] for r in rows if re.fullmatch("[A-Za-z][A-Za-z0-9]*(?:[-'][A-Za-z0-9]+)*", r['word']) and len(r['word']) >= 2]
regression = ['ARTEX', 'Cherry-pick', 'Fine-tuning', 'RISC-V', 'PAN-OS', 'BIG-IP', 'Zero-day', "can't", 'AI-driven', 'get', 'read', 'write']
batches = [regression] + [words[i:i + 200] for i in range(0, len(words), 200)]
requests = [{'op': 'analyze', 'words': batch} for batch in batches]
result = subprocess.run([
    str(resources / 'Python/bin/python3.13'), '-B', '-u', str(resources / 'worker.py'),
    str(Path.home() / 'Library/Application Support/RTranslate/Assets/voicevox'),
    str(next((resources / 'VoiceRuntime').glob('libvoicevox_onnxruntime*.dylib')))
], input=''.join(json.dumps(r) + '\n' for r in requests), text=True, capture_output=True, check=True, timeout=60)
replies = [json.loads(line) for line in result.stdout.splitlines()]
assert 'voices' in replies[0]
assert len(replies) == len(requests) + 1
for batch, reply in zip(batches, replies[1:]):
    assert [r['word'] for r in reply.get('words', [])] == batch, 'A word discarded the batch'
    assert all(isinstance(r['isSpelling'], bool) for r in reply['words'])
assert all(r['reading'] for r in replies[1]['words']), 'Regression words must have readings'
print('Native word collection passed:', len(words), 'public terms and hyphen/apostrophe regressions; all rows retained')

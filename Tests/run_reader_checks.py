#!/usr/bin/env python3
"""Compile the real Reader with a fake Safari and in-memory silent speech."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='rspeech-reader-checks-') as temp:
    temp = Path(temp)
    declarations = (root / 'Main.swift').read_text().split('@main\nstruct RSpeechApp')[0]
    (temp / 'main.swift').write_text((root/'Pronunciation.swift').read_text() + '\n' + declarations + (root / 'Tests/ReaderChecks.swift').read_text())
    executable = temp / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(temp/'main.swift'), '-o', str(executable), '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'AVFoundation'], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)

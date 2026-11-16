# Third-party software and voice data

RSpeech's original source code is MIT licensed. The following components retain their own licenses and terms.

- **VOICEVOX Core 0.17.1** — text analysis and speech synthesis. [MIT license](licenses/VOICEVOX-Core-LICENSE.txt). https://github.com/VOICEVOX/voicevox_core
- **VOICEVOX voice models 0.17.1** — unmodified 0.vvm, 1.vvm, and 12.vvm. [Model and voice terms](licenses/VOICEVOX/VOICE-MODELS-README.txt), [model sources](licenses/VOICEVOX/MODEL-SOURCES.json). https://github.com/VOICEVOX/voicevox_vvm
- **VOICEVOX ONNX Runtime 1.17.3** — [terms](licenses/VOICEVOX/ONNX-RUNTIME-TERMS.txt), [third-party notices](licenses/VOICEVOX/ONNX-THIRD-PARTY.html). https://github.com/VOICEVOX/onnxruntime-builder
- **Open JTalk dictionary 1.11** — redistribution terms are included in the app at `Contents/Resources/voicevox/dict/open_jtalk_dic_utf_8-1.11/COPYING`. https://open-jtalk.sourceforge.net/
- **CPython 3.13** and its bundled standard-library components — [Python license](licenses/Python-LICENSE.txt). Additional component notices remain in the embedded runtime. https://www.python.org/
- **linkedom 0.18.15** — ISC-licensed development-only DOM test dependency, not bundled with the app. https://github.com/WebReflection/linkedom

The voice menu exposes the normal talk styles of 四国めたん, ずんだもん, 春日部つむぎ, 雨晴はう, 冥鳴ひまり, and 雀松朱司. The VVM files contain additional styles/voices; the files are not modified or split. RSpeech displays the selected `VOICEVOX:話者名` credit. When publishing generated speech, follow the applicable voice library's terms and credit requirements.

The release app includes these notices, model terms, dictionary terms, and runtime licenses. Model weights and runtimes are distributed in release assets, not committed as source code.

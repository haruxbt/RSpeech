# Third-party software and voice data

RSpeech's original source code is MIT licensed. The following components retain their own licenses and terms.

- **VOICEVOX Core 0.17.1** — text analysis and speech synthesis. [MIT license](licenses/VOICEVOX-Core-LICENSE.txt). https://github.com/VOICEVOX/voicevox_core
- **VOICEVOX voice models 0.17.1** — RSpeech reads unmodified 0.vvm, 1.vvm, and 12.vvm from RTranslate’s Application Support folder; these models are not included in the app. [Model and voice terms](licenses/VOICEVOX/VOICE-MODELS-README.txt), [model sources](licenses/VOICEVOX/MODEL-SOURCES.json). https://github.com/VOICEVOX/voicevox_vvm
- **VOICEVOX ONNX Runtime 1.17.3** — [terms](licenses/VOICEVOX/ONNX-RUNTIME-TERMS.txt), [third-party notices](licenses/VOICEVOX/ONNX-THIRD-PARTY.html). https://github.com/VOICEVOX/onnxruntime-builder
- **Open JTalk dictionary 1.11** — the dictionary is read from RTranslate’s Application Support folder and is not included in RSpeech. Its terms are in the dictionary’s `COPYING` file. https://open-jtalk.sourceforge.net/
- **CPython 3.13** and its bundled standard-library components — [Python license](licenses/Python-LICENSE.txt). Additional component notices remain in the embedded runtime. https://www.python.org/
- **linkedom 0.18.15** — ISC-licensed development-only DOM test dependency, not bundled with the app. https://github.com/WebReflection/linkedom

The voice menu exposes the normal talk styles of 四国めたん, ずんだもん, 春日部つむぎ, 雨晴はう, 冥鳴ひまり, and 雀松朱司. The shared VVM files contain additional styles/voices; RSpeech does not modify or split them. RSpeech displays the selected `VOICEVOX:話者名` credit. When publishing generated speech, follow the applicable voice library's terms and credit requirements.

The release app includes these notices, model terms, and runtime licenses. Voice model weights and the dictionary are not distributed with RSpeech. The release includes the Python/Core/ONNX execution components.

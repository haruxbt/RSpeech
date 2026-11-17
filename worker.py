#!/usr/bin/env python3
"""Private stdio adapter. No network, text logging, or audio files."""
import base64
import json
import re
import sys
from pathlib import Path
from voicevox_core import UserDictWord
from voicevox_core.blocking import Onnxruntime, OpenJtalk, Synthesizer, VoiceModelFile, UserDict


def main():
    root = Path(sys.argv[1])
    jtalk = OpenJtalk(str(next((root / 'dict').glob('open_jtalk_dic*'))))
    synth = Synthesizer(
        Onnxruntime.load_once(filename=sys.argv[2]),
        jtalk,
        acceleration_mode='CPU', cpu_num_threads=2)
    allowed = {'四国めたん', 'ずんだもん', '春日部つむぎ', '雨晴はう', '冥鳴ひまり', '雀松朱司'}
    voices, paths = [], {}
    for path in sorted((root / 'models/vvms').glob('*.vvm')):
        with VoiceModelFile.open(str(path)) as model:
            for meta in model.metas:
                for style in meta.styles:
                    if meta.name in allowed and style.name == 'ノーマル' and style.type in ('talk', 'streaming_talk'):
                        voices.append({'id': style.id, 'name': meta.name})
                        paths[style.id] = path
    print(json.dumps({'voices': voices}, ensure_ascii=False), flush=True)
    def reading(word):
        return ''.join(mora.text for phrase in jtalk.analyze(word) for mora in phrase.moras)
    letters = {}
    active_dictionary = None
    replacement = None
    replacements = {}
    def configure_dictionary(rows):
        nonlocal active_dictionary, replacement, replacements
        if not isinstance(rows, list) or len(rows) > 3000:
            raise ValueError('Invalid dictionary')
        fingerprint = json.dumps(rows, sort_keys=True, ensure_ascii=False)
        if fingerprint == active_dictionary:
            return
        user_dict = UserDict()
        entries = []
        for row in rows:
            word, kana = row['word'], row['reading']
            if not isinstance(word, str) or not isinstance(kana, str) or not 1 <= len(word) <= 64 or not 1 <= len(kana) <= 64:
                raise ValueError('Invalid entry')
            native = re.fullmatch('[ァ-ヴー]+', kana) is not None
            if native:
                user_dict.add_word(UserDictWord(word, kana, int(row.get('accent', 0)), priority=int(row.get('priority', 5))))
            entries.append((word, word if native else kana))
        jtalk.use_user_dict(user_dict)
        letters.clear()
        replacements = {word.casefold(): value for word, value in entries}
        patterns = []
        for word, _ in sorted(entries, key=lambda entry: len(entry[0]), reverse=True):
            left = r'(?<![A-Za-z0-9_])' if word[0].isascii() and (word[0].isalnum() or word[0] == '_') else ''
            right = r'(?![A-Za-z0-9_])' if word[-1].isascii() and (word[-1].isalnum() or word[-1] == '_') else ''
            patterns.append(left + re.escape(word) + right)
        replacement = re.compile('|'.join(patterns), re.IGNORECASE) if patterns else None
        active_dictionary = fingerprint
    def canonical(text):
        return replacement.sub(lambda match: replacements[match.group().casefold()], text) if replacement else text
    loaded_path = loaded_id = None
    for line in sys.stdin:
        try:
            req = json.loads(line)
            configure_dictionary(req.get('dictionary', []))
            if req.get('op') == 'analyze':
                words = req['words']
                if not isinstance(words, list) or len(words) > 200:
                    raise ValueError('Invalid word list')
                results = []
                for word in words:
                    if not isinstance(word, str) or not 1 <= len(word) <= 64 or not word.isascii() or not all(c.isalnum() or c in "-'" for c in word):
                        raise ValueError('Invalid word')
                    try:
                        phrases = jtalk.analyze(canonical(word))
                        kana = ''.join(mora.text for phrase in phrases for mora in phrase.moras)
                        spelled = ''
                        # A separator has no phonemes on its own; analyzing '-' or "'"
                        # throws AnalyzeTextError and used to discard the entire batch.
                        for char in word:
                            if not char.isalnum():
                                continue
                            if char not in letters:
                                letters[char] = reading(char)
                            spelled += letters[char]
                        # Open JTalk renders A as エエ in words and エイ alone.
                        normal = lambda value: value.replace('エエ', 'エイ')
                        results.append({'word': word, 'reading': kana, 'isSpelling': not kana or normal(kana) == normal(spelled), 'accents': [phrase.accent for phrase in phrases]})
                    except Exception:
                        # Keep the word visible for manual registration; one unknown term
                        # must never hide the other terms collected from the article.
                        results.append({'word': word, 'reading': '', 'isSpelling': True, 'accents': []})
                print(json.dumps({'words': results}, ensure_ascii=False), flush=True)
                continue
            text, speaker, speed = req['text'], int(req['speaker']), float(req['speed'])
            if not isinstance(text, str) or not 0 < len(text) <= 12000 or speaker not in paths or not 0.75 <= speed <= 2:
                raise ValueError('Invalid input')
            path = paths[speaker]
            if loaded_path != path:
                if loaded_id is not None:
                    synth.unload_voice_model(loaded_id)
                    loaded_id = loaded_path = None
                with VoiceModelFile.open(str(path)) as model:
                    synth.load_voice_model(model)
                    loaded_id, loaded_path = model.id, path
            query = synth.create_audio_query(canonical(text), speaker)
            query.speed_scale = speed
            wav = synth.synthesis(query, speaker)
            print(json.dumps({'wav': base64.b64encode(wav).decode('ascii'), 'reading': ''.join(mora.text for phrase in query.accent_phrases for mora in phrase.moras)}, ensure_ascii=False), flush=True)
        except Exception:
            print('{"error":"音声の生成に失敗しました。停止して再試行してください。"}', flush=True)


if __name__ == '__main__':
    main()

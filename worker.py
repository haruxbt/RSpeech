#!/usr/bin/env python3
"""Private stdio adapter. No network, text logging, or audio files."""
import base64
import json
import sys
from pathlib import Path
from voicevox_core.blocking import Onnxruntime, OpenJtalk, Synthesizer, VoiceModelFile


def main():
    root = Path(sys.argv[1])
    synth = Synthesizer(
        Onnxruntime.load_once(filename=sys.argv[2]),
        OpenJtalk(str(next((root / 'dict').glob('open_jtalk_dic*')))),
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
    loaded_path = loaded_id = None
    for line in sys.stdin:
        try:
            req = json.loads(line)
            text, speaker, speed = req['text'], int(req['speaker']), float(req['speed'])
            if not isinstance(text, str) or not 0 < len(text) <= 400 or speaker not in paths or not 0.75 <= speed <= 2:
                raise ValueError('Invalid input')
            path = paths[speaker]
            if loaded_path != path:
                if loaded_id is not None:
                    synth.unload_voice_model(loaded_id)
                    loaded_id = loaded_path = None
                with VoiceModelFile.open(str(path)) as model:
                    synth.load_voice_model(model)
                    loaded_id, loaded_path = model.id, path
            query = synth.create_audio_query(text, speaker)
            query.speed_scale = speed
            wav = synth.synthesis(query, speaker)
            print(json.dumps({'wav': base64.b64encode(wav).decode('ascii')}), flush=True)
        except Exception:
            print('{"error":"音声の生成に失敗しました。停止して再試行してください。"}', flush=True)


if __name__ == '__main__':
    main()

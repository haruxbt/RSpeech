#!/usr/bin/env python3
"""Exercise compound readings through the real release worker; audio stays in RAM."""
import argparse
import json
import subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--app',required=True,type=Path);a=p.parse_args()
r=a.app.resolve()/'Contents/Resources'
rows=json.loads((Path(__file__).resolve().parent.parent/'Dictionary/common-ja.json').read_text())['entries']
expected={'OpenAPI':'オープンエーピーアイ','CyberStrikeAI':'サイバーストライクエーアイ','CloudFastener':'クラウドファスナー','getUserName':'ゲットユーザーネーム','XMLParser':'エックスエムエルパーサー','get_user_name':'ゲットユーザーネーム'}
# Core returns long vowels as mora text (e.g. オープン -> オオプン).
# Normalize the expected spoken kana with an independent Open JTalk instance.
normalize_code = """
import json,sys
from pathlib import Path
from voicevox_core.blocking import OpenJtalk
j=OpenJtalk(str(next((Path.home()/'Library/Application Support/RTranslate/Assets/voicevox/dict').glob('open_jtalk_dic*'))))
print(json.dumps({w:''.join(m.text for p in j.analyze(kana) for m in p.moras) for w,kana in json.loads(sys.stdin.read()).items()}))
"""
normalized=json.loads(subprocess.check_output([str(r/'Python/bin/python3.13'),'-B','-c',normalize_code],input=json.dumps(dict(expected,override='シーバーストライクエーアイ')).encode(),timeout=30))
# Test automatic splitting even after this example enters the common dictionary.
rows=[row for row in rows if row['word'].lower()!='cyberstrikeai']
whole=rows+[{'word':'CyberStrikeAI','reading':'サンプル','accent':2,'priority':7}]
parts=[dict(x,reading='シーバー') if x['word'].lower()=='cyber' else x for x in rows]
# Lowercase fallback is useful even when a part is not in the custom dictionary.
lowercase=[x for x in rows if x['word'].lower()!='strike']
requests=[
 {'op':'analyze','words':list(expected)+['OpenQXZV','QXZV','openapi','ARTEX'],'dictionary':rows},
 {'op':'analyze','words':['CyberStrikeAI'],'dictionary':whole},
 {'op':'analyze','words':['CyberStrikeAI'],'dictionary':parts},
 {'op':'analyze','words':['CyberStrikeAI'],'dictionary':lowercase},
 {'op':'analyze','words':['ARTEX']},
 {'text':'OpenAPI CyberStrikeAI CloudFastener getUserName XMLParser get_user_name','speaker':2,'speed':1.2,'dictionary':rows},
 {'text':'CyberStrikeAI','speaker':2,'speed':1.2,'dictionary':whole},
 {'text':'CyberStrikeAI','speaker':2,'speed':1.2,'dictionary':parts},
]
result=subprocess.run([str(r/'Python/bin/python3.13'),'-B','-u',str(r/'worker.py'),str(Path.home()/'Library/Application Support/RTranslate/Assets/voicevox'),str(next((r/'VoiceRuntime').glob('libvoicevox_onnxruntime*.dylib')))],input=''.join(json.dumps(x)+'\n' for x in requests),text=True,capture_output=True,check=True,timeout=60)
reply=[json.loads(l) for l in result.stdout.splitlines()][1:]
assert len(reply)==len(requests)
actual={x['word']:x for x in reply[0]['words']}
for word,kana in expected.items():
 assert actual[word]['reading']==normalized[word],(word,actual[word])
 assert not actual[word]['isSpelling'] and not actual[word]['unresolvedParts'],actual[word]
assert [x['word'] for x in actual['OpenQXZV']['unresolvedParts']]==['QXZV']
assert actual['OpenQXZV']['isSpelling'] and actual['QXZV']['isSpelling']
assert actual['openapi']['unresolvedParts']==[], 'Do not guess boundaries inside lowercase words'
assert reply[1]['words'][0]['reading']=='サンプル' and reply[1]['words'][0]['accents']==[2]
assert reply[2]['words'][0]['reading']==normalized['override']
assert reply[3]['words'][0]['reading']==normalized['CyberStrikeAI'], 'Lowercase English fallback must read strike'
assert reply[4]['words'][0]['isSpelling'], 'Dictionary reset must clear both whole and component entries'
assert reply[5]['reading']==''.join(normalized[w] for w in expected),reply[5].get('reading')
assert reply[6]['reading']=='サンプル'
assert reply[7]['reading']==normalized['override']
assert all(x.get('wav') for x in reply[5:]), 'Actual synthesis must use the same readings as analysis'
print('Compound analysis and actual WAV passed: example words, component overrides, whole-word priority, lowercase fallback, unresolved parts and reset')

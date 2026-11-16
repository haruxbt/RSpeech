#!/usr/bin/env python3
"""Use the release interpreter and real Core; keep words and audio in memory."""
import argparse
import json
import subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parent.parent
resources=a.app.resolve()/'Contents/Resources'
source=json.loads((root/'Dictionary/common-ja.json').read_text())
rows=source['entries']; lookup={r['word'].lower():r for r in rows}
words=['Intent','planner','Write','put','GET','read','write','post','Cisco','catalyst','Paloalto','fortinet','juniper','arista','fortigate','A10','F5','CrowdStrike','Zscaler','Infoblox','Tor','DoS','DDoS']
# Run checks inside the embedded Python, including dictionary validity and expected mora text.
code="""
import json,sys
from pathlib import Path
from voicevox_core import UserDictWord
from voicevox_core.blocking import OpenJtalk,UserDict
source=json.loads(sys.stdin.readline()); u=UserDict()
for row in source['entries']:u.add_word(UserDictWord(row['word'],row['reading'],row['accent'],priority=row['priority']))
r=Path.home()/'Library/Application Support/RTranslate/Assets/voicevox'
j=OpenJtalk(str(next((r/'dict').glob('open_jtalk_dic*'))))
print(json.dumps({w['word'].lower():''.join(m.text for phrase in j.analyze(w['reading']) for m in phrase.moras) for w in source['entries']},ensure_ascii=False))
"""
python=resources/'Python/bin/python3.13'
expected=json.loads(subprocess.check_output([str(python),'-B','-c',code],input=(json.dumps(source)+'\n').encode(),timeout=30))
requests=[{'op':'analyze','words':words,'dictionary':rows}, {'op':'analyze','words':['ARTEX'],'dictionary':[{'word':'ARTEX','reading':'アルテックス','accent':2,'priority':7}]}, {'op':'analyze','words':['ARTEX']}, {'text':'ARTEX put GET read WRITE post','speaker':2,'speed':1.5,'dictionary':rows}, {'text':'Attack Surface Mitre Att@ck Tor Dark web DoS DDoS','speaker':2,'speed':1.5,'dictionary':rows}]
process=subprocess.run([str(python),'-B','-u',str(resources/'worker.py'),str(Path.home()/'Library/Application Support/RTranslate/Assets/voicevox'),str(next((resources/'VoiceRuntime').glob('libvoicevox_onnxruntime*.dylib')))],input=''.join(json.dumps(r)+'\n' for r in requests),text=True,capture_output=True,check=True,timeout=60)
replies=[json.loads(line) for line in process.stdout.splitlines()]
assert len(replies[0]['voices'])==6
for result in replies[1]['words']:
 assert result['reading']==expected[result['word'].lower()],result
assert replies[2]['words'][0]['accents']==[2],replies[2]
assert replies[3]['words'][0]['isSpelling'] is True, 'Clearing dictionary must clear native entries'
expected_query=''.join(expected[w.lower()] for w in ['ARTEX','put','GET','read','WRITE','post'])
assert replies[4]['reading']==expected_query,replies[4]['reading']
assert replies[4]['wav'], 'Actual native-dictionary synthesis must return WAV'
security_query=''.join(expected[w.lower()] for w in ['Attack Surface','MITRE Att@ck','Tor','Dark Web','DoS','DDoS'])
assert replies[5]['reading']==security_query,replies[5]['reading']
assert replies[5]['wav']
print('All',len(rows),'common entries validated; requested words/case variants/native accent and dictionary reset passed')

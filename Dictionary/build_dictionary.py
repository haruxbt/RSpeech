#!/usr/bin/env python3
"""Build the reviewed pronunciation JSON; no article body is retained."""
import json
import uuid
from pathlib import Path
here=Path(__file__).resolve().parent
sources=json.loads((here/'candidates.json').read_text())['sources']
overrides=json.loads((here/'pronunciation-overrides.json').read_text())
entries=[];seen=set()
for line in (here/'readings.tsv').read_text().splitlines():
 if not line.strip():continue
 word,reading=line.split('\t')
 if word.casefold() in seen:raise ValueError('Duplicate: '+word)
 seen.add(word.casefold())
 found=[s['id'] for s in sources if word.lower() in s['words']]
 entries.append({'id':str(uuid.uuid5(uuid.NAMESPACE_URL,'https://github.com/haruxbt/RSpeech#'+word.lower())), 'word':word,'reading':reading,'accent':0,'priority':5,'sources':found or ['curated-it'],**overrides.get(word.lower(),{})})
output={'schemaVersion':1,'version':'2026.11.18.1','description':'IT・プログラミング・AI開発・セキュリティの読み。読みは編集方針による日本語表記、アクセント0は平板の初期値。個人辞書が優先。','sources':[{k:s[k] for k in ['id','title','url','status']} for s in sources], 'entries':entries}
(here/'common-ja.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n')
print('Common entries:',len(entries),'with page occurrence:',sum(e['sources']!=['curated-it'] for e in entries))

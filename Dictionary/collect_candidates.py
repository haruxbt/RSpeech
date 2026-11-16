#!/usr/bin/env python3
"""Collect vocabulary from an explicit list of public pages; never use browser history."""
import collections
import concurrent.futures
import json
import re
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
SOURCES = [
 ('security', 'SoftBank セキュリティ用語解説', 'https://www.softbank.jp/biz/content/security-glossary/'),
 ('zerotrust', 'JPNIC ゼロトラスト', 'https://www.nic.ad.jp/ja/basics/terms/zerotrust.html'),
 ('bedrock', 'Amazon Bedrock 主要な用語', 'https://docs.aws.amazon.com/ja_jp/bedrock/latest/userguide/key-definitions.html'),
 ('kubernetes', 'Kubernetes 概要', 'https://kubernetes.io/ja/docs/concepts/overview/'),
 ('mcp', 'Model Context Protocol Introduction', 'https://modelcontextprotocol.io/docs/getting-started/intro'),
 ('agents', 'Ubie クラウドエージェント基盤', 'https://zenn.dev/ubie_dev/articles/45501469c9c044'),
 ('http', 'MDN HTTP request methods', 'https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Methods'),
 ('javascript', 'MDN JavaScript reference', 'https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference'),
]
class Text(HTMLParser):
 def __init__(self): super().__init__(); self.skip = 0; self.words = []
 def handle_starttag(self, tag, attrs):
  if tag in ('script','style','nav','footer','header'): self.skip += 1
 def handle_endtag(self, tag):
  if tag in ('script','style','nav','footer','header'): self.skip = max(0,self.skip-1)
 def handle_data(self,data):
  if not self.skip: self.words.extend(re.findall(r'(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9+#.-]*',data))
def collect(source):
 sid,title,url=source
 try:
  req=urllib.request.Request(url,headers={'User-Agent':'RSpeech-public-dictionary-builder'})
  with urllib.request.urlopen(req,timeout=20) as r: html=r.read(2_000_001)
  if len(html)>2_000_000: raise ValueError('page too large')
  parser=Text();parser.feed(html.decode('utf-8','replace'))
  words=collections.Counter(w.strip('.').lower() for w in parser.words if 2<=len(w)<=64)
  return {'id':sid,'title':title,'url':url,'status':'ok','words':dict(sorted(words.items()))}
 except Exception as e: return {'id':sid,'title':title,'url':url,'status':type(e).__name__,'words':{}}
if __name__=='__main__':
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: records=list(pool.map(collect,SOURCES))
 Path(__file__).with_name('candidates.json').write_text(json.dumps({'sources':records},ensure_ascii=False,indent=2)+'\n')
 print('Public pages:',sum(x['status']=='ok' for x in records),'/',len(records),'unique candidate words:',len(set(w for x in records for w in x['words'])))

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const script = fs.readFileSync(path.join(__dirname, '../PageExtraction.js'), 'utf8');
const tracker = fs.readFileSync(path.join(__dirname, '../PageSelection.js'), 'utf8');
const windows=[];
function page(html) {
  const dom = new JSDOM(html,{url:'https://example.test/article',pretendToBeVisual:true,runScripts:'outside-only'});
  const w=dom.window; windows.push(w);
  w.HTMLElement.prototype.getBoundingClientRect=function(){return {width:this.hidden?0:600};};
  Object.defineProperty(w.HTMLElement.prototype,'innerText',{get(){return this.textContent;}});
  const context=dom.getInternalVMContext();
  return {w, d:w.document, position(){return JSON.parse(vm.runInContext(tracker,context));},
    extract(selected=true){this.position();return JSON.parse(vm.runInContext(script,context)(selected));},
    select(node,start,endNode=node,end=start+1){const range=w.document.createRange();range.setStart(node,start);range.setEnd(endNode,end);w.getSelection().removeAllRanges();w.getSelection().addRange(range);w.document.dispatchEvent(new w.Event('selectionchange'));}};
}
function extract(html){return page(html).extract();}
let result=extract('<html><head><title>ブラウザのタイトル</title></head><body><header>サイトの名前</header><nav>ナビ</nav><main><article><h1>記事タイトル</h1><p>本文の出だしです。<strong>API</strong>を読みます。</p><h2>本文の小見出し</h2><p>続きです。</p><aside>広告</aside><p hidden>隠れた文章</p><p style="display:none">非表示</p></article></main><footer>フッター</footer></body></html>');
assert.equal(result.text,'本文の出だしです。APIを読みます。\n本文の小見出し\n続きです。');
assert.equal(result.url,'https://example.test/article');
assert.equal(extract('<body><h1>タイトル</h1><p>articleのないページの本文です。</p><script>secret</script>').text,'articleのないページの本文です。');
assert.equal(extract('<article><h1>タイトルのみ</h1></article>').text,'');
assert.equal(extract('<article><div>サイト名と投稿情報</div><h1>タイトル</h1><div class="znc"><p>コンテンツの出だしです。</p><p>次の段落です。</p></div><div>フォローとコメント</div></article>').text,'コンテンツの出だしです。\n次の段落です。');
const p=page('<article><div>余計な冒頭です。</div><p id="first">前半。<strong>選択開始</strong>から読みます。</p><p id="second">続きです。</p><p>続きです。</p><footer>不要</footer></article>');
const selected=p.d.querySelector('strong').firstChild;
p.select(selected,2);
const first=p.extract();
assert.equal(first.text,'開始から読みます。\n続きです。\n続きです。');
assert.equal(p.extract().selectionID,first.selectionID,'Same selection must resume');
assert.ok(p.extract(false).text.startsWith('余計な冒頭です。'));
assert.equal(p.extract().selectionID,first.selectionID,'Whole-page analysis must preserve selection');
p.w.getSelection().setBaseAndExtent(selected,4,selected,2);
assert.equal(p.extract().text,first.text,'Backward drag uses document-order start');
p.select(p.d.querySelector('#first'),1,p.d.querySelector('#first'),2);
assert.equal(p.extract().text,'選択開始から読みます。\n続きです。\n続きです。','Element offsets');
p.select(p.d.querySelectorAll('p')[2].firstChild,0);
assert.equal(p.extract().text,'続きです。','Duplicate words use DOM position');
const before=p.position();p.w.getSelection().removeAllRanges();p.d.dispatchEvent(new p.w.Event('selectionchange'));p.select(p.d.querySelectorAll('p')[2].firstChild,0);
assert.notEqual(p.position().selectionID,before.selectionID,'Reselecting after clear restarts');
p.w.getSelection().collapse(selected,1);
assert.equal(p.position().selectionID,null);
const separate=page('<article><p>'+('長い別記事です。'.repeat(30))+'</p></article><article><p id="short">短い選択記事です。</p><p>最後です。</p></article>');
separate.select(separate.d.querySelector('#short').firstChild,2);
assert.equal(separate.extract().text,'選択記事です。\n最後です。');
assert.notEqual(separate.position().documentID,p.position().documentID);
for(const w of windows)w.close();
console.log('Extraction checks passed: title/navigation/hidden exclusion, selection tails, backward drag, element offsets, duplicate text, article roots and selection identity');

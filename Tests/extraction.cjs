const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { parseHTML } = require('linkedom');
const script = fs.readFileSync(require('node:path').join(__dirname, '../PageExtraction.js'), 'utf8');
function extract(html) {
  const { document, Node, HTMLElement } = parseHTML(html);
  HTMLElement.prototype.getBoundingClientRect = function() { return {width: this.hidden ? 0 : 600}; };
  const blocks = new Set(['BODY','ARTICLE','MAIN','DIV','P','H1','H2','NAV','HEADER','FOOTER','ASIDE','UL','LI']);
  const getComputedStyle = e => ({display:e.style.display || (blocks.has(e.tagName)?'block':'inline'), visibility:e.style.visibility || 'visible'});
  return JSON.parse(vm.runInNewContext(script, {document,Node,getComputedStyle,location:{href:'https://example.test/article'}}));
}
let result = extract('<html><head><title>ブラウザのタイトル</title></head><body><header>サイトの名前</header><nav>ナビ</nav><main><article><h1>記事タイトル</h1><p>本文の出だしです。<strong>API</strong>を読みます。</p><h2>本文の小見出し</h2><p>続きです。</p><aside>広告</aside><p hidden>隠れた文章</p><p style="display:none">非表示</p></article></main><footer>フッター</footer></body></html>');
assert.equal(result.url,'https://example.test/article');
assert.equal(result.text,'本文の出だしです。APIを読みます。\n本文の小見出し\n続きです。');
result=extract('<html><body><h1>タイトル</h1><p>articleのないページの本文です。</p><script>secret</script></body></html>');
assert.equal(result.text,'articleのないページの本文です。');
result=extract('<html><body><article><h1>タイトルのみ</h1></article></body></html>');
assert.equal(result.text,'');
result=extract('<html><body><article><div>サイト名と投稿情報</div><h1>タイトル</h1><div class="znc"><p>コンテンツの出だしです。</p><p>次の段落です。</p></div><div>フォローとコメント</div></article></body></html>');
assert.equal(result.text,'コンテンツの出だしです。\n次の段落です。');
console.log('Extraction checks passed: title/navigation/hidden text omitted, paragraph order preserved, body fallback, empty body');

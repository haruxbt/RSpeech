(() => {
  const excluded = 'script,style,noscript,template,nav,aside,header,footer,h1,[role="navigation"],[role="banner"],[role="dialog"],[aria-hidden="true"],.entry-title,.post-title';
  function visible(element) {
    const style = getComputedStyle(element);
    return !element.hidden && style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse';
  }
  const bodySelectors = '[itemprop="articleBody"],.znc,.markdown-body,.entry-content,.post-content,.article-body,.article-content';
  const specific = [...document.querySelectorAll(bodySelectors)]
    .filter(element => visible(element) && element.getBoundingClientRect().width > 0 && element.innerText.trim());
  const candidates = [...document.querySelectorAll('article,main,[role="main"]')]
    .filter(element => visible(element) && element.getBoundingClientRect().width > 0)
    .sort((a, b) => b.innerText.length - a.innerText.length);
  const root = specific.sort((a, b) => b.innerText.length - a.innerText.length)[0] || candidates[0] || document.body;
  function content(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.replace(/\s+/g, ' ');
    if (node.nodeType !== Node.ELEMENT_NODE || node.matches(excluded) || !visible(node)) return '';
    if (node.tagName === 'BR') return '\n';
    const text = [...node.childNodes].map(content).join('');
    const block = /^(block|flex|grid|table|list-item)/.test(getComputedStyle(node).display);
    return block ? '\n' + text + '\n' : text;
  }
  const text = root ? content(root).split('\n').map(line => line.trim()).filter(Boolean).join('\n') : '';
  return JSON.stringify({ url: location.href, text });
})()

((respectSelection = true) => {
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
  let root = specific.sort((a, b) => b.innerText.length - a.innerText.length)[0] || candidates[0] || document.body;
  const state = window[Symbol.for('RSpeech.selectionTracker.v1')].capture();
  const selection = respectSelection ? state.range : null;
  let start = null;
  if (selection) {
    const element = selection.startContainer.nodeType === Node.ELEMENT_NODE ? selection.startContainer : selection.startContainer.parentElement;
    if (!root || !root.contains(selection.startContainer)) root = element?.closest(bodySelectors + ',article,main,[role="main"]') || document.body;
    start = selection.cloneRange(); start.collapse(true);
  }
  function content(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      if (start && start.comparePoint(node, node.length) <= 0) return '';
      const text = start && node === start.startContainer ? node.nodeValue.slice(start.startOffset) : node.nodeValue;
      return text.replace(/\s+/g, ' ');
    }
    if (node.nodeType !== Node.ELEMENT_NODE || node.matches(excluded) || !visible(node)) return '';
    if (node.tagName === 'BR') return '\n';
    const text = [...node.childNodes].map(content).join('');
    const block = /^(block|flex|grid|table|list-item)/.test(getComputedStyle(node).display);
    return block ? '\n' + text + '\n' : text;
  }
  const text = root ? content(root).split('\n').map(line => line.trim()).filter(Boolean).join('\n') : '';
  return JSON.stringify({ url: location.href, text, documentID: state.documentID, selectionID: selection ? state.selectionID : null });
})

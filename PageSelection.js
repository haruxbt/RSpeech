(() => {
  const key = Symbol.for('RSpeech.selectionTracker.v1');
  if (!window[key]) {
    const tracker = {
      documentID: Date.now().toString(36) + '-' + Math.random().toString(36).slice(2),
      revision: 0,
      signature: undefined,
      capture() {
        const selection = window.getSelection();
        let range = null;
        if (selection && selection.rangeCount && !selection.isCollapsed) {
          const candidate = selection.getRangeAt(0);
          if (candidate.toString().trim() && document.body && document.body.contains(candidate.startContainer)) range = candidate.cloneRange();
        }
        function path(node) {
          const parts = [];
          while (node && node !== document) {
            const parent = node.parentNode;
            if (!parent) break;
            parts.push([...parent.childNodes].indexOf(node));
            node = parent;
          }
          return parts.reverse().join('.');
        }
        const signature = range ? [path(range.startContainer), range.startOffset, path(range.endContainer), range.endOffset].join(':') : null;
        if (signature !== this.signature) { this.signature = signature; this.revision += 1; }
        return { url: location.href, documentID: this.documentID,
          selectionID: range ? this.documentID + ':' + this.revision + ':' + signature : null, range };
      }
    };
    window[key] = tracker;
    document.addEventListener('selectionchange', () => tracker.capture());
  }
  const state = window[key].capture();
  return JSON.stringify({ url: state.url, documentID: state.documentID, selectionID: state.selectionID });
})()

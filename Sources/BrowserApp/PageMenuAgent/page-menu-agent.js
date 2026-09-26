// Page menu agent. Runs in its own isolated content world in every frame.
//
// WebKit builds the context menu without telling the app what was clicked.
// The DOM `contextmenu` event fires before the menu opens, so this reports the
// link, image, media and selected text under the pointer, and the app's own
// menu items ("Open Link in New Window", "Save Image As…", "Copy Image
// Address", "Search for …") act on that.
(function () {
  'use strict';
  if (window.__sbPageMenu) return;
  window.__sbPageMenu = true;
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pageMenu;
  if (!handler) return;

  function closest(path, test) {
    for (var i = 0; i < path.length; i++) {
      var node = path[i];
      if (node instanceof Element && test(node)) return node;
    }
    return null;
  }

  function selectedText(target) {
    // Inside a field the document selection is empty; the field has its own.
    if ((target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) &&
        typeof target.selectionStart === 'number' && target.selectionEnd > target.selectionStart) {
      return target.value.substring(target.selectionStart, target.selectionEnd);
    }
    var selection = window.getSelection();
    return selection ? selection.toString() : '';
  }

  document.addEventListener('contextmenu', function (event) {
    var path = event.composedPath ? event.composedPath() : [event.target];
    var link = closest(path, function (el) { return (el.localName === 'a' || el.localName === 'area') && el.href; });
    var image = closest(path, function (el) { return el.localName === 'img'; });
    var media = closest(path, function (el) { return el.localName === 'video' || el.localName === 'audio'; });
    try {
      handler.postMessage({
        link: link ? String(link.href) : '',
        linkText: link ? (link.textContent || '').trim().slice(0, 200) : '',
        image: image ? (image.currentSrc || image.src || '') : '',
        media: media ? (media.currentSrc || media.src || '') : '',
        selection: selectedText(event.target).slice(0, 5000)
      });
    } catch (e) { /* the view is going away */ }
  }, true);
})();

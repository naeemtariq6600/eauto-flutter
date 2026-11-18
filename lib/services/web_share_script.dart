/// Chrome shows the system share sheet for `navigator.share` and WhatsApp
/// share links. The WebView does not, so those actions are forwarded here.
const String webShareHookScript = r'''
(function () {
  if (window.__eautoShareHook) return;
  if (!document || !document.addEventListener) return;
  window.__eautoShareHook = true;

  var pending = {};
  var chunkSize = 262144;

  function post(payload) {
    if (!window.WebShare || !window.WebShare.postMessage) return;
    window.WebShare.postMessage(JSON.stringify(payload));
  }

  window.__eautoShareResult = function (id, status) {
    var item = pending[id];
    if (!item) return;
    delete pending[id];
    if (status === 'shared') item.resolve();
    else if (status === 'dismissed') item.reject(new DOMException('Share canceled', 'AbortError'));
    else item.reject(new DOMException("Couldn't share", 'NotAllowedError'));
  };

  function isWhatsapp(url) {
    try {
      var parsed = new URL(url, location.href);
      var protocol = (parsed.protocol || '').toLowerCase();
      var host = (parsed.hostname || '').toLowerCase();
      if (protocol === 'whatsapp:') return true;
      if (protocol === 'intent:' && String(url).toLowerCase().indexOf('whatsapp') !== -1) return true;
      return host === 'wa.me' || host === 'api.whatsapp.com' || host === 'web.whatsapp.com' || host === 'chat.whatsapp.com';
    } catch (e) {
      return false;
    }
  }

  function messageFromWhatsapp(url) {
    try {
      var parsed = new URL(url, location.href);
      return parsed.searchParams.get('text') || parsed.href;
    } catch (e) {
      return url;
    }
  }

  function sendFile(id, index, file) {
    return new Promise(function (resolve, reject) {
      var reader = new FileReader();
      reader.onloadend = function () {
        var result = String(reader.result || '');
        var comma = result.indexOf(',');
        var encoded = comma >= 0 ? result.substring(comma + 1) : '';
        post({
          type: 'fileStart',
          id: id,
          index: index,
          name: file.name || 'file',
          mime: file.type || '',
          total: encoded.length
        });
        for (var offset = 0; offset < encoded.length; offset += chunkSize) {
          post({type: 'chunk', id: id, index: index, data: encoded.substring(offset, offset + chunkSize)});
        }
        post({type: 'fileEnd', id: id, index: index});
        resolve();
      };
      reader.onerror = function () { reject(reader.error); };
      reader.readAsDataURL(file);
    });
  }

  function shareData(data) {
    var id = String(Date.now()) + '-' + Math.random().toString(16).slice(2);
    var files = (data && data.files) ? Array.prototype.slice.call(data.files) : [];
    return new Promise(function (resolve, reject) {
      pending[id] = {resolve: resolve, reject: reject};
      post({
        type: 'begin',
        id: id,
        title: (data && data.title) || '',
        text: (data && data.text) || '',
        url: (data && data.url) || '',
        fileCount: files.length
      });
      var chain = Promise.resolve();
      files.forEach(function (file, index) {
        chain = chain.then(function () { return sendFile(id, index, file); });
      });
      chain.then(function () {
        post({type: 'go', id: id});
      }).catch(function () {
        delete pending[id];
        post({type: 'abort', id: id});
        reject(new DOMException("Couldn't share", 'NotAllowedError'));
      });
    });
  }

  navigator.canShare = function (data) {
    if (!data) return false;
    var files = data.files || [];
    if (files.length > 10) return false;
    return !!(data.text || data.url || data.title || files.length);
  };

  navigator.share = function (data) {
    return shareData(data || {});
  };

  function closestAnchor(node) {
    while (node && node !== document) {
      if (node.tagName && String(node.tagName).toLowerCase() === 'a') return node;
      node = node.parentNode;
    }
    return null;
  }

  document.addEventListener('click', function (event) {
    var anchor = closestAnchor(event.target);
    var href = anchor && (anchor.href || anchor.getAttribute('href') || '');
    if (!href || !isWhatsapp(href)) return;
    event.preventDefault();
    event.stopPropagation();
    shareData({text: messageFromWhatsapp(href), title: 'Share'}).catch(function () {});
  }, true);

  var originalOpen = window.open;
  window.open = function (url) {
    if (typeof url === 'string' && isWhatsapp(url)) {
      shareData({text: messageFromWhatsapp(url), title: 'Share'}).catch(function () {});
      return null;
    }
    return originalOpen.apply(window, arguments);
  };
})();
''';

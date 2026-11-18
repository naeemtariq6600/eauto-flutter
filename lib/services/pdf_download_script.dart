/// Injected into every page. The site downloads PDFs through normal links,
/// `download` attributes, and blob URLs. Those succeed in Chrome and are
/// ignored by the in-app browser unless we forward them to Flutter.
const String pdfDownloadHookScript = r'''
(function () {
  if (window.__eautoPdfHook) return;
  if (!document || !document.addEventListener || !window.HTMLAnchorElement) return;
  window.__eautoPdfHook = true;

  var recentUrl = '';
  var recentAt = 0;
  var seq = 0;

  function postToFlutter(payload) {
    if (!window.PdfDownloader || !window.PdfDownloader.postMessage) return;
    window.PdfDownloader.postMessage(JSON.stringify(payload));
  }

  function reportError() {
    postToFlutter({type: 'error', message: "Couldn't download the PDF"});
  }

  function absoluteUrl(url) {
    try { return new URL(url, location.href).href; }
    catch (e) { return url; }
  }

  function isPdfHref(url) {
    try {
      var parsed = new URL(absoluteUrl(url));
      var path = decodeURIComponent(parsed.pathname).toLowerCase().split(';')[0];
      if (path.slice(-4) === '.pdf') return true;
      var format = (parsed.searchParams.get('format') || parsed.searchParams.get('type') || parsed.searchParams.get('ext') || '').toLowerCase();
      return format === 'pdf';
    } catch (e) {
      return false;
    }
  }

  function filenameFromDisposition(header) {
    if (!header) return '';
    var parts = header.split(';');
    var star = '';
    var plain = '';
    for (var i = 0; i < parts.length; i++) {
      var item = parts[i].replace(/^\s+|\s+$/g, '');
      var lower = item.toLowerCase();
      if (lower.indexOf('filename*=') === 0) star = item.substring(item.indexOf('=') + 1);
      else if (lower.indexOf('filename=') === 0) plain = item.substring(item.indexOf('=') + 1);
    }
    var value = star || plain;
    if (!value) return '';
    var marker = value.indexOf("''");
    if (marker !== -1) value = value.substring(marker + 2);
    value = value.replace(/"/g, '').replace(/^\s+|\s+$/g, '');
    try { return decodeURIComponent(value); }
    catch (e) { return value; }
  }

  function remember(url) {
    var now = Date.now();
    if (recentUrl === url && now - recentAt < 1500) return false;
    recentUrl = url;
    recentAt = now;
    return true;
  }

  function postUrl(url, filename, quietIfNotPdf) {
    if (!remember(url)) return;
    postToFlutter({
      type: 'url',
      url: url,
      filename: filename || '',
      referrer: location.href,
      quietIfNotPdf: quietIfNotPdf === true
    });
  }

  function blobLooksLikePdf(blob, name) {
    var mime = (blob.type || '').toLowerCase();
    var pdfName = /\.pdf$/i.test(name || '');
    if (mime.indexOf('pdf') !== -1) return Promise.resolve(true);
    if (pdfName && (mime === '' || mime.indexOf('octet-stream') !== -1 || mime.indexOf('binary') !== -1)) {
      return Promise.resolve(true);
    }
    if (mime && mime.indexOf('octet-stream') === -1 && mime.indexOf('binary') === -1) {
      return Promise.resolve(false);
    }
    return blob.slice(0, 8).text().then(function (text) {
      return text.indexOf('%PDF') !== -1;
    }).catch(function () { return false; });
  }

  function sendBlob(blob, filename) {
    if (!blob || !blob.size) {
      reportError();
      return;
    }
    if (blob.size > 80 * 1024 * 1024) {
      reportError();
      return;
    }
    var reader = new FileReader();
    reader.onloadend = function () {
      var result = String(reader.result || '');
      var comma = result.indexOf(',');
      var b64 = comma >= 0 ? result.substring(comma + 1) : '';
      if (!b64) {
        reportError();
        return;
      }
      var id = String(++seq);
      var chunkSize = 262144;
      postToFlutter({
        type: 'start',
        id: id,
        filename: filename || 'document.pdf',
        mime: blob.type || 'application/pdf',
        total: b64.length
      });
      for (var i = 0; i < b64.length; i += chunkSize) {
        postToFlutter({type: 'chunk', id: id, data: b64.substring(i, i + chunkSize)});
      }
      postToFlutter({type: 'end', id: id});
    };
    reader.onerror = function () { reportError(); };
    reader.readAsDataURL(blob);
  }

  function deliverBlob(blob, name, explicit) {
    return blobLooksLikePdf(blob, name).then(function (ok) {
      if (!ok) {
        if (explicit) reportError();
        return;
      }
      sendBlob(blob, name || 'document.pdf');
    });
  }

  function shouldIntercept(anchor) {
    var href = anchor.href || '';
    if (!href || href.indexOf('javascript:') === 0 || href === location.href.split('#')[0] + '#') return false;
    if (href.indexOf('blob:') === 0 || href.indexOf('data:') === 0) return true;
    if (isPdfHref(href)) return true;
    var type = (anchor.getAttribute('type') || '').toLowerCase();
    if (type.indexOf('pdf') !== -1) return true;
    if (anchor.hasAttribute('download')) {
      var name = anchor.getAttribute('download') || '';
      if (!name || /\.pdf$/i.test(name)) return true;
    }
    return false;
  }

  function handleAnchor(anchor) {
    var href = anchor.href || '';
    if (!href) return;
    var name = anchor.getAttribute('download') || '';
    var explicit = isPdfHref(href) || /\.pdf$/i.test(name) || (anchor.getAttribute('type') || '').toLowerCase().indexOf('pdf') !== -1;
    if (href.indexOf('blob:') === 0 || href.indexOf('data:') === 0) {
      if (!remember(href)) return;
      fetch(href).then(function (res) { return res.blob(); }).then(function (blob) {
        return deliverBlob(blob, name, explicit);
      }).catch(function () { if (explicit) reportError(); });
      return;
    }
    postUrl(absoluteUrl(href), name, !explicit);
  }

  function closestAnchor(node) {
    while (node && node !== document) {
      if (node.tagName && String(node.tagName).toLowerCase() === 'a') return node;
      node = node.parentNode;
    }
    return null;
  }

  document.addEventListener('click', function (event) {
    var anchor = closestAnchor(event.target);
    if (!anchor || !shouldIntercept(anchor)) return;
    event.preventDefault();
    handleAnchor(anchor);
  }, true);

  var originalClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (shouldIntercept(this)) {
      handleAnchor(this);
      return;
    }
    return originalClick.apply(this, arguments);
  };

  function handleForm(form, submitter) {
    var action = form.action || '';
    if (submitter && submitter.formAction) action = submitter.formAction;
    if (!isPdfHref(action)) return false;
    var method = (form.getAttribute('method') || 'get').toLowerCase();
    if (submitter && submitter.getAttribute && submitter.getAttribute('formmethod')) {
      method = String(submitter.getAttribute('formmethod')).toLowerCase();
    }
    if (method === 'get' || method === '') {
      var params = new URLSearchParams(new FormData(form)).toString();
      var url = action;
      if (params) url += (action.indexOf('?') === -1 ? '?' : '&') + params;
      postUrl(url, '', false);
      return true;
    }
    fetch(action, {method: method, body: new FormData(form), credentials: 'include'})
      .then(function (res) {
        return res.blob().then(function (blob) {
          var name = filenameFromDisposition(res.headers.get('content-disposition')) || 'document.pdf';
          return deliverBlob(blob, name, true);
        });
      })
      .catch(reportError);
    return true;
  }

  document.addEventListener('submit', function (event) {
    var form = event.target;
    if (!form || !form.action) return;
    if (handleForm(form, event.submitter || null)) event.preventDefault();
  }, true);

  var originalSubmit = HTMLFormElement.prototype.submit;
  HTMLFormElement.prototype.submit = function () {
    if (handleForm(this, null)) return;
    return originalSubmit.apply(this, arguments);
  };

  var originalOpen = window.open;
  window.open = function (url) {
    if (typeof url === 'string' && isPdfHref(url)) {
      postUrl(absoluteUrl(url), '', false);
      return null;
    }
    return originalOpen.apply(window, arguments);
  };

  var originalAssign = Location.prototype.assign;
  if (originalAssign) {
    Location.prototype.assign = function (url) {
      if (typeof url === 'string' && isPdfHref(url)) {
        postUrl(absoluteUrl(url), '', false);
        return;
      }
      return originalAssign.apply(this, arguments);
    };
  }

  window.__eautoDownload = function (url, filename) {
    if (!url) return;
    if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) {
      if (!remember(url)) return;
      fetch(url).then(function (res) { return res.blob(); }).then(function (blob) {
        return deliverBlob(blob, filename || '', true);
      }).catch(reportError);
      return;
    }
    postUrl(absoluteUrl(url), filename || '', false);
  };
})();
''';

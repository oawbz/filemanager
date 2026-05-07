{{flutter_js}}
{{flutter_build_config}}

const __SPANEL_LOCAL_CANVASKIT_BASE__ = 'canvaskit/';
const __SPANEL_LOCAL_FONT_FALLBACK_BASE__ = 'assets/font_fallbacks/';

// Last-resort guard: rewrite known external engine URLs to local paths.
{
  const __pageBase = (function () {
    var loc = window.location.href;
    var idx = loc.lastIndexOf('/');
    return idx >= 0 ? loc.substring(0, idx + 1) : loc + '/';
  })();

  function __resolveRelative(url) {
    if (/^[a-z][a-z0-9+.\-]*:\/\//i.test(url)) return url;
    if (url.startsWith('//')) return url;
    if (url.startsWith('/')) url = '.' + url;
    try { return new URL(url, __pageBase).href; } catch (_) { return url; }
  }

  function __spanelRewriteExternalUrl(input) {
    const raw = typeof input === 'string' ? input : String(input ?? '');
    if (!raw) return raw;
    if (raw.includes('://www.gstatic.com/flutter-canvaskit/')) {
      const marker = '/flutter-canvaskit/';
      const idx = raw.indexOf(marker);
      if (idx >= 0) {
        const tail = raw.slice(idx + marker.length);
        const slash = tail.indexOf('/');
        const path = slash >= 0 ? tail.slice(slash + 1) : '';
        return `${__SPANEL_LOCAL_CANVASKIT_BASE__}${path}`;
      }
      return __SPANEL_LOCAL_CANVASKIT_BASE__;
    }
    if (raw.includes('://fonts.gstatic.com/s/')) {
      const marker = '/s/';
      const idx = raw.indexOf(marker);
      if (idx >= 0) {
        const tail = raw.slice(idx + marker.length);
        return `${__SPANEL_LOCAL_FONT_FALLBACK_BASE__}${tail}`;
      }
      return __SPANEL_LOCAL_FONT_FALLBACK_BASE__;
    }
    return raw;
  }

  const originalFetch = window.fetch.bind(window);
  window.fetch = function (resource, init) {
    if (typeof resource === 'string') {
      resource = __resolveRelative(__spanelRewriteExternalUrl(resource));
    } else if (resource instanceof Request) {
      var rewritten = __resolveRelative(__spanelRewriteExternalUrl(resource.url));
      if (rewritten !== resource.url) {
        resource = new Request(rewritten, resource);
      }
    }
    return originalFetch(resource, init);
  };

  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, async, user, password) {
    return originalOpen.call(
      this,
      method,
      __resolveRelative(__spanelRewriteExternalUrl(url)),
      async,
      user,
      password,
    );
  };
}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  config: {
    canvasKitBaseUrl: __SPANEL_LOCAL_CANVASKIT_BASE__,
    fontFallbackBaseUrl: __SPANEL_LOCAL_FONT_FALLBACK_BASE__,
  },
});

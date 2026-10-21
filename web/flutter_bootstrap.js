{{flutter_js}}
{{flutter_build_config}}

// index.html fetched this file as flutter_bootstrap.js?build=<hash> and set
// window.__homiBuild to the same hash. Loading main.dart.js under that
// address too means no browser cache or leftover service worker can hand
// back an older build's code — the URL simply never existed before.
if (window.__homiBuild) {
  for (const b of _flutter.buildConfig.builds) {
    if (b.compileTarget === 'dart2js') {
      b.mainJsPath = (b.mainJsPath || 'main.dart.js') + '?build=' + window.__homiBuild;
    }
  }
}

// No serviceWorkerSettings on purpose: Flutter's service worker is deprecated,
// and the caching one older builds installed is what pinned browsers to a
// stale main.dart.js after every deploy. index.html evicts any left behind.
_flutter.loader.load();

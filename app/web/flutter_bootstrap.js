{{flutter_js}}
{{flutter_build_config}}

// No service worker: it kept serving the previous build after a deploy.
// One installed by an earlier version of the page is removed.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then(function (rs) {
    rs.forEach(function (r) { r.unregister(); });
  });
}
_flutter.loader.load();

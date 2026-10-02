{{flutter_js}}
{{flutter_build_config}}

// No service worker: it kept serving the previous build after a deploy.
// One installed by an earlier version of the page is removed.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then(function (rs) {
    rs.forEach(function (r) { r.unregister(); });
  });
}
// Everything comes from this site: CanvasKit is built in
// (--no-web-resources-cdn, tool/build_web.sh), and the fonts for
// characters the bundled ones lack are looked up here, not on Google's
// servers (there are none here: such characters show as boxes).
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
    fontFallbackBaseUrl: 'assets/fonts/fallback/',
  },
});

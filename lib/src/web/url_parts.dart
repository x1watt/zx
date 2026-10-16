// A part set (io/part_set.dart) read over HTTP in the web engine
// (docs/architecture.md section 21): the manifest at a URL names its
// parts by URLs relative to it; each part is read with range requests
// ([HttpRangeInStream]) when first touched, and only a few parts keep
// their block caches. Pure Dart apart from the transport, which the
// engine gives (XhrRangeTransport) and tests fake.

import 'dart:typed_data';

import '../io/part_set.dart';
import 'range_stream.dart';

/// The URL of each part of [m], resolved against [manifestUrl].
List<String> partUrls(ZxPartManifest m, String manifestUrl) {
  final base = Uri.parse(manifestUrl);
  return [for (final p in m.parts) base.resolve(p.file).toString()];
}

/// The parts of [m] (its manifest at [manifestUrl]) as one stream; every
/// part opened gets its own [HttpRangeInStream] through [transport], with
/// [cacheBytes] of blocks of [blockSize], and at most [maxOpen] stay
/// open; [created] sees each stream made (for the statistics of requests
/// and bytes). Blocks are 64 KiB, not the 256 KiB of a whole archive: a
/// database reads small pages here and there (four cold queries of the
/// English Wikipedia test: 3.3 MiB in 27 requests, 7.9 MiB with 256 KiB).
PartSetInStream urlPartSet(ZxPartManifest m, String manifestUrl,
    RangeTransport Function(String url) transport,
    {int maxOpen = 4,
    int cacheBytes = 16 << 20,
    int blockSize = 64 << 10,
    void Function(HttpRangeInStream s)? created}) {
  final urls = partUrls(m, manifestUrl);
  // every part of the warm set stays open, or its blocks would be lost
  final warmParts = {for (final r in m.warmRequests()) r.$1}.length;
  return PartSetInStream(m, (i) {
    final s = HttpRangeInStream(transport(urls[i]), m.parts[i].size,
        cacheBytes: cacheBytes, blockSize: blockSize);
    created?.call(s);
    return s;
  }, maxOpen: warmParts > maxOpen ? warmParts : maxOpen);
}

/// Fetches the warm set of the manifest of [set] (part set over
/// [HttpRangeInStream]s, from [urlPartSet]) with [fetch], [parallel]
/// requests at a time, and puts the blocks into the parts' caches; a
/// redirect seen on the way is remembered by the part's transport.
/// [fetch] gets a URL and an inclusive byte range and gives the bytes and
/// the URL that answered. Returns the requests made and the bytes.
Future<(int, int)> prefetchWarm(PartSetInStream set,
    Future<(Uint8List, String?)> Function(String url, int start, int end) fetch,
    {int parallel = 16}) async {
  final reqs = set.manifest.warmRequests();
  var bytes = 0;
  for (var k = 0; k < reqs.length; k += parallel) {
    final batch = reqs.skip(k).take(parallel).toList();
    final got = await Future.wait([
      for (final (part, off, len) in batch)
        () async {
          final s = set.partStream(part) as HttpRangeInStream;
          final t = s.transport;
          final url = t is RedirectCachingTransport ? t.target : null;
          if (url == null) return null;
          final (b, answeredBy) = await fetch(url, off, off + len - 1);
          if (answeredBy != null && t is RedirectCachingTransport) {
            t.remember(answeredBy);
          }
          return (s, off, b);
        }(),
    ]);
    for (final g in got) {
      if (g == null) continue;
      g.$1.preload(g.$2, g.$3);
      bytes += g.$3.length;
    }
  }
  return (reqs.length, bytes);
}

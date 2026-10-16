// A part set (io/part_set.dart) read over HTTP in the web engine
// (docs/architecture.md section 21): the manifest at a URL names its
// parts by URLs relative to it; each part is read with range requests
// ([HttpRangeInStream]) when first touched, and only a few parts keep
// their block caches. Pure Dart apart from the transport, which the
// engine gives (XhrRangeTransport) and tests fake.

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
  return PartSetInStream(m, (i) {
    final s = HttpRangeInStream(transport(urls[i]), m.parts[i].size,
        cacheBytes: cacheBytes, blockSize: blockSize);
    created?.call(s);
    return s;
  }, maxOpen: maxOpen);
}

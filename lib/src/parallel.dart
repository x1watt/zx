// Parallel encoding in worker isolates: the MtCoder part of the SDK.
//
// The codecs below lib/src are synchronous and single threaded. Where the
// SDK hands independent blocks to MtCoder threads, the port exposes the two
// halves of that path (encode one block, write the blocks in order), and
// this file runs the first half in a [WorkerPool]. The bytes are the same
// as those of the sequential path, which are the same as the SDK's
// multithreaded output (test/api_test.dart checks both).

import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'format/xz/xz_enc.dart';
import 'io/streams.dart';
import 'pool.dart';

/// Encodes [input] as one xz stream to [output] like [XzEnc.encode] on its
/// multithreaded path, with the blocks encoded by [pool]. [props] are
/// normalized XzProps with more than one block thread
/// (`props.numBlockThreadsReduced > 1`). [onBlock] gets the unpacked and
/// packed totals after each block is written.
Future<void> xzEncodeParallel(
    XzProps props, InStream input, OutStream output, WorkerPool pool,
    {void Function(int inSize, int outSize)? onBlock}) async {
  final blockSize = xzMtBlockSize(props);
  final writer = XzMtBlockWriter(props, output);
  final pending = ListQueue<Future<(TransferableTypedData, int, int)>>();
  // One block per worker plus one read ahead: each block in flight holds
  // its input and its output, so this bounds the memory.
  final maxInFlight = pool.size + 1;
  final buf = Uint8List(blockSize);
  var finished = false;
  while (!finished || pending.isNotEmpty) {
    while (!finished && pending.length < maxInFlight) {
      // MtCoder: SeqInStream_ReadMax of one block; the block is the last
      // one when it is not full.
      final size = readFully(input, buf, 0, blockSize);
      finished = size != blockSize;
      final data =
          TransferableTypedData.fromList([Uint8List.sublistView(buf, 0, size)]);
      pending.add(pool.run(_xzBlockJob(props, data, size)));
    }
    final (bytes, unpackSize, totalSize) = await pending.removeFirst();
    writer.write(XzEncodedMtBlock(
        bytes.materialize().asUint8List(), unpackSize, totalSize));
    onBlock?.call(writer.inOffset, writer.outOffset);
  }
  writer.finish();
}

// Built outside the async function, so that the closure captures only its
// arguments (all sendable).
(TransferableTypedData, int, int) Function() _xzBlockJob(
        XzProps props, TransferableTypedData data, int size) =>
    () {
      final b = xzEncodeMtBlock(props, data.materialize().asUint8List(), size);
      return (
        TransferableTypedData.fromList([b.bytes]),
        b.unpackSize,
        b.totalSize
      );
    };

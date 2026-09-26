// Registers every decoder of the port (7-Zip's REGISTER_CODEC tables).

import 'codec.dart';
import 'copy.dart';
import 'filters/filters.dart';
import 'lzma/lzma_coder.dart';
import 'ppmd/ppmd_coder.dart';
import '../crypto/seven_zip_aes.dart';

bool _registered = false;

/// Fills [decoderRegistry] once. Safe to call from every entry point and
/// from every isolate.
void registerAllCodecs() {
  if (_registered) return;
  _registered = true;
  registerCopyCodec(decoderRegistry);
  registerLzmaCodecs(decoderRegistry);
  registerPpmdCodecs(decoderRegistry);
  registerFilterCodecs(decoderRegistry);
  registerCryptoCodecs(decoderRegistry);
}

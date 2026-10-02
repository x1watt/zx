/// The part of the zx API that a user interface holds, for the native
/// platforms and the browser alike: the archive handle, its items,
/// listings, results and errors, seals, SQL results, READMEs. In a browser
/// [ZxArchive] is the client of the engine worker (lib/src/web), which
/// reads archives only; everywhere else it is the native one of
/// package:zx/zx.dart. Nothing here needs 64-bit integers, so it compiles
/// with dart2js too (docs/architecture.md section 20).
library;

export 'src/zx_client_native.dart'
    if (dart.library.js_interop) 'src/web/zx_api_web.dart';

export 'src/api_types.dart';
export 'src/zx_types.dart';
export 'src/io/streams.dart' show SevenZipException, SevenZipError;
export 'src/format/zx/zx_seal_types.dart';
export 'src/db/sql/sql_result.dart';
export 'src/db/storage_api.dart' show ZxDbException, ZxDbError;
export 'src/readme/markdown.dart';
export 'src/readme/readme.dart';
export 'src/readme/readme_links.dart';
export 'src/crypto/nip19.dart'
    show npubEncode, nsecEncode, parsePublicKey, parseSecretKey;
export 'src/crypto/sha256.dart' show Sha256;
export 'src/util/tlsh.dart' show Tlsh, tlshDistance;
export 'src/version.dart' show zxVersionString;

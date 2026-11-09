/// The browser's side of zxdb (docs/architecture.md section 20): the files
/// a database lives in when the library is compiled for the web, and the
/// change list a host persists (IndexedDB, OPFS). Plain Dart: importable
/// anywhere, used only by a web build's storage glue.
library;

export 'src/host/web_fs.dart'
    show
        ZxWebFs,
        ZxWebFsChange,
        ZxWebFsFile,
        ZxWebFsDelete,
        ZxWebFsDir,
        zxWebChunk;

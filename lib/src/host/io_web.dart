// The web side of host/io.dart: dart:io with a web Platform, and files held
// in memory (web_fs.dart; the host persists them) instead of dart:io's file
// classes, which throw in a browser.
export 'dart:io'
    hide
        Platform,
        File,
        Directory,
        FileStat,
        RandomAccessFile,
        FileMode,
        FileSystemException,
        OSError,
        FileSystemEntity,
        FileSystemEntityType,
        Link,
        pid;
export 'platform_web.dart';
export 'web_fs.dart';

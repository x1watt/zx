// The version of zx, shared by the command line banner, the .zx writer
// (writer_version and the "introduced in" versions of the codec registry)
// and the .zx reader (the min_reader_version check).

/// The zx release, as a string.
const String zxVersionString = '0.5.0';

/// The zx release as (major, minor, patch), for the .zx format.
const (int, int, int) zxVersion = (0, 5, 0);

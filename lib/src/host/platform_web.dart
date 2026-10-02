// Platform on the web (host/io.dart): the members the library uses, with
// the answers of a single threaded, POSIX-like host without a file system
// of its own.
abstract final class Platform {
  static const String pathSeparator = '/';
  static const bool isWindows = false;
  static const bool isLinux = false;
  static const bool isMacOS = false;
  static const bool isAndroid = false;
  static const bool isIOS = false;
  static const bool isFuchsia = false;
  static const String operatingSystem = 'web';
  static const String version = 'web';
  static const String localeName = 'en_US';
  static const int numberOfProcessors = 1;
  static const Map<String, String> environment = {};
}

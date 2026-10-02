// The interfaces of services.dart that the views use, without their
// desktop implementations: the web version (lib/main_web.dart) implements
// them for the browser.

/// Opens files and folders with the programs of the desktop.
abstract class Launcher {
  Future<void> openFile(String path);
  Future<void> openFolder(String path);

  /// Opens a web address (http, https or mailto) in the browser or mail
  /// program; false when that is not possible here.
  Future<bool> openUrl(String url);
}

/// The file and folder dialogs.
abstract class FilePicker {
  /// An archive to open.
  Future<String?> openArchive({String? initialDirectory});

  /// Files to add.
  Future<List<String>> pickFiles({String? initialDirectory});

  /// A folder (to add, or to extract to).
  Future<String?> pickFolder({String? initialDirectory, String? title});

  /// Where to save a file (an export).
  Future<String?> saveFile({String? initialDirectory, String? suggestedName});
}

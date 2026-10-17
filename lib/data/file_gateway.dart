import 'package:flutter/services.dart';

/// Thin bridge to Android's Storage Access Framework (see MainActivity.kt).
/// The system picker grants access to exactly the files/folder the user
/// chooses, so the app needs NO storage permission.
class FileGateway {
  static const _ch = MethodChannel('pocket_ledger/saf');

  /// Lets the user choose a folder, then writes every file into it.
  /// Returns the number of files written, or null if the user cancelled.
  Future<int?> saveToFolder(Map<String, Uint8List> files) async {
    return _ch.invokeMethod<int>('saveToFolder', {'files': files});
  }

  /// Lets the user pick one or more CSV files. Returns {} if cancelled.
  Future<Map<String, Uint8List>> pickCsvFiles() async {
    final res = await _ch.invokeMethod<List<Object?>>('pickCsvFiles');
    final out = <String, Uint8List>{};
    for (final item in res ?? const []) {
      final m = (item as Map).cast<String, Object?>();
      out[m['name'] as String] = m['bytes'] as Uint8List;
    }
    return out;
  }
}

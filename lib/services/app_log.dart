import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only log file in the app's sandboxed Application Support folder.
/// Never log the token. Rotates once past ~1 MB, keeping one older file.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const _maxBytes = 1024 * 1024;
  File? _file;

  String? get path => _file?.path;

  Future<void> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/gnotify.log');
      if (!_file!.existsSync()) _file!.createSync(recursive: true);
      _rotateIfNeeded();
    } catch (e) {
      debugPrint('log init failed: $e');
      _file = null;
    }
  }

  void info(String message) => _write('INFO ', message);
  void warn(String message) => _write('WARN ', message);
  void error(String message) => _write('ERROR', message);

  void _write(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} $level $message';
    debugPrint(line);
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      _rotateIfNeeded();
    } catch (_) {}
  }

  void _rotateIfNeeded() {
    final f = _file;
    if (f == null) return;
    try {
      if (f.lengthSync() < _maxBytes) return;
      final old = File('${f.path}.1');
      if (old.existsSync()) old.deleteSync();
      f.renameSync(old.path);
      _file = File(f.path)..createSync();
    } catch (_) {}
  }
}

import 'package:flutter/services.dart';

/// Secrets live in the macOS Keychain, reached through the app's method
/// channel. Keychain items are encrypted at rest and other processes have to
/// go through a system prompt to read them, unlike the UserDefaults plist
/// that holds the rest of the settings.
class SecureStore {
  static const _channel = MethodChannel('com.jasoncamp.gnotify/menubar');

  Future<String?> read(String key) async {
    final value = await _channel.invokeMethod<String>('secureRead', {'key': key});
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> write(String key, String value) async {
    if (value.isEmpty) return delete(key);
    await _channel.invokeMethod('secureWrite', {'key': key, 'value': value});
  }

  Future<void> delete(String key) async {
    await _channel.invokeMethod('secureDelete', {'key': key});
  }
}

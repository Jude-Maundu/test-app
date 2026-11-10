import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages persistent tool authorizations and user default app configurations.
/// Fulfills the requirement: "once i have given it permission once it should always go ahead".
class PermissionManager {
  PermissionManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const String _keyPersistentAuth = 'jarvis_persistent_authorizations';
  static const String _keyAlwaysAllow = 'jarvis_always_allow_authorized';
  static const String _keyOnboardingDone = 'has_completed_onboarding';
  static const String _keyDefaultMusic = 'jarvis_default_music_app';
  static const String _keyDefaultEmail = 'jarvis_default_email_app';
  static const String _keyDefaultCalendar = 'jarvis_default_calendar_app';
  static const String _keyDefaultClock = 'jarvis_default_clock_app';
  static const String _keyNotifyOnTask = 'jarvis_notify_on_task_completion';

  /// Default authorized sensitive tools once approved.
  static const List<String> defaultSensitiveTools = [
    'send_sms',
    'send_whatsapp_message',
    'make_call',
    'send_email',
  ];

  /// Checks if onboarding has been completed.
  Future<bool> hasCompletedOnboarding() async {
    final val = await _storage.read(key: _keyOnboardingDone);
    return val == 'true';
  }

  /// Sets onboarding completion status.
  Future<void> setCompletedOnboarding(bool completed) async {
    await _storage.write(key: _keyOnboardingDone, value: completed.toString());
  }

  /// Checks if "always allow once granted" setting is enabled (default true).
  Future<bool> isAlwaysAllowEnabled() async {
    final val = await _storage.read(key: _keyAlwaysAllow);
    if (val == null) return true; // Default to true: remember permission
    return val == 'true';
  }

  /// Sets the "always allow once granted" toggle.
  Future<void> setAlwaysAllowEnabled(bool enabled) async {
    await _storage.write(key: _keyAlwaysAllow, value: enabled.toString());
  }

  /// Retrieves list of tools that have been permanently authorized by user.
  Future<List<String>> getAuthorizedTools() async {
    final raw = await _storage.read(key: _keyPersistentAuth);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.whereType<String>().toList();
    } catch (_) {
      return [];
    }
  }

  /// Checks if a specific tool is authorized.
  Future<bool> isToolAuthorized(String toolName) async {
    final alwaysAllow = await isAlwaysAllowEnabled();
    if (!alwaysAllow) return false;
    final authorized = await getAuthorizedTools();
    return authorized.contains(toolName);
  }

  /// Permanently grants authorization for a tool.
  Future<void> grantToolAuthorization(String toolName) async {
    final authorized = await getAuthorizedTools();
    if (!authorized.contains(toolName)) {
      authorized.add(toolName);
      await _storage.write(key: _keyPersistentAuth, value: jsonEncode(authorized));
    }
  }

  /// Revokes authorization for a tool.
  Future<void> revokeToolAuthorization(String toolName) async {
    final authorized = await getAuthorizedTools();
    authorized.remove(toolName);
    await _storage.write(key: _keyPersistentAuth, value: jsonEncode(authorized));
  }

  /// Clears all stored tool authorizations.
  Future<void> resetAllAuthorizations() async {
    await _storage.delete(key: _keyPersistentAuth);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Default App Preferences
  // ───────────────────────────────────────────────────────────────────────────

  Future<String> getDefaultMusicApp() async {
    return await _storage.read(key: _keyDefaultMusic) ?? 'spotify';
  }

  Future<void> setDefaultMusicApp(String app) async {
    await _storage.write(key: _keyDefaultMusic, value: app);
  }

  Future<String> getDefaultEmailApp() async {
    return await _storage.read(key: _keyDefaultEmail) ?? 'gmail';
  }

  Future<void> setDefaultEmailApp(String app) async {
    await _storage.write(key: _keyDefaultEmail, value: app);
  }

  Future<String> getDefaultCalendarApp() async {
    return await _storage.read(key: _keyDefaultCalendar) ?? 'google_calendar';
  }

  Future<void> setDefaultCalendarApp(String app) async {
    await _storage.write(key: _keyDefaultCalendar, value: app);
  }

  Future<String> getDefaultClockApp() async {
    return await _storage.read(key: _keyDefaultClock) ?? 'google_clock';
  }

  Future<void> setDefaultClockApp(String app) async {
    await _storage.write(key: _keyDefaultClock, value: app);
  }

  Future<bool> shouldNotifyOnTaskCompletion() async {
    final val = await _storage.read(key: _keyNotifyOnTask);
    if (val == null) return true; // default true
    return val == 'true';
  }

  Future<void> setNotifyOnTaskCompletion(bool notify) async {
    await _storage.write(key: _keyNotifyOnTask, value: notify.toString());
  }
}

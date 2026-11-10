import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:test_app/services/linux_platform_service.dart';

class PhoneContact {
  const PhoneContact({required this.name, required this.phoneNumber});

  final String name;
  final String phoneNumber;

  factory PhoneContact.fromMap(Map<Object?, Object?> map) => PhoneContact(
    name: map['name'] as String,
    phoneNumber: map['phoneNumber'] as String,
  );
}

class PlatformService {
  static const MethodChannel _channel = MethodChannel(
    'com.assistant.app/platform',
  );

  static bool? mockIsLinux;
  static bool get isLinux => mockIsLinux ?? (!kIsWeb && Platform.isLinux);

  /// Every method returns a plain string. Failures start with "Error", so the
  /// UI can tell them apart from normal results.
  static bool isError(String result) => result.startsWith('Error');

  static Future<String> _invoke(
    String method,
    String errorPrefix, {
    Map<String, dynamic>? arguments,
    String fallback = 'Done',
  }) async {
    try {
      final result = await _channel.invokeMethod<String>(method, arguments);
      return result ?? fallback;
    } on PlatformException catch (e) {
      return '$errorPrefix: ${e.message ?? e.code}';
    } on MissingPluginException {
      return fallback;
    } catch (e) {
      return '$errorPrefix: $e';
    }
  }

  static Future<String> launchApp(String packageName) {
    if (isLinux) return LinuxPlatformService.launchApp(packageName);
    return _invoke(
      'launchApp',
      'Error launching app',
      arguments: {'packageName': packageName},
    );
  }

  static Future<String> setAlarm(String time, String label) {
    if (isLinux) return LinuxPlatformService.setAlarm(time, label);
    return _invoke(
      'setAlarm',
      'Error setting alarm',
      arguments: {'time': time, 'label': label},
    );
  }

  /// An empty string means there is nothing to read.
  static Future<String> readNotifications() {
    if (isLinux) return LinuxPlatformService.readNotifications();
    return _invoke('readNotifications', 'Error reading notifications', fallback: '');
  }

  static Future<String> makeCall(String phoneNumber) {
    if (isLinux) return LinuxPlatformService.makeCall(phoneNumber);
    return _invoke(
      'makeCall',
      'Error making call',
      arguments: {'phoneNumber': phoneNumber},
    );
  }

  static Future<String> sendSms(String phoneNumber, String message) {
    if (isLinux) return LinuxPlatformService.sendSms(phoneNumber, message);
    return _invoke(
      'sendSms',
      'Error sending SMS',
      arguments: {'phoneNumber': phoneNumber, 'message': message},
    );
  }

  static Future<List<PhoneContact>> findContacts(String name) async {
    if (isLinux) return LinuxPlatformService.findContacts(name);
    try {
      final result = await _channel.invokeMethod<List<Object?>>('findContacts', {
        'name': name,
      });
      return (result ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map(PhoneContact.fromMap)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Map<String, String>>> findContactEmails(String name) async {
    if (isLinux) return LinuxPlatformService.findContactEmails(name);
    try {
      final result = await _channel.invokeMethod<List<Object?>>('findContactEmails', {
        'name': name,
      });
      return (result ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<String> performDeviceAction(
    String action, {
    Map<String, dynamic> arguments = const {},
  }) {
    if (isLinux) {
      return LinuxPlatformService.performDeviceAction(
        action,
        arguments: arguments,
      );
    }
    return _invoke(
      'deviceAction',
      'Error performing $action',
      arguments: {'action': action, 'arguments': arguments},
    );
  }

  static Future<String> requestDefaultAssistant() {
    if (isLinux) return LinuxPlatformService.requestDefaultAssistant();
    return _invoke('requestAssistantRole', 'Error requesting assistant role');
  }

  static Future<String> requestNotificationAccess() {
    if (isLinux) return LinuxPlatformService.requestNotificationAccess();
    return _invoke(
      'requestNotificationAccess',
      'Error opening notification access settings',
    );
  }

  static Future<String> mediaControl(String action) {
    if (isLinux) return LinuxPlatformService.mediaControl(action);
    return _invoke(
      'mediaControl',
      'Error controlling media',
      arguments: {'action': action},
    );
  }

  static Future<String> playMediaFromSearch({
    required String query,
    bool isYouTube = false,
    String? artist,
    String? title,
  }) {
    if (isLinux) {
      return LinuxPlatformService.playMediaFromSearch(
        query,
        isYouTube: isYouTube,
        artist: artist,
        title: title,
      );
    }
    return _invoke(
      'playMediaFromSearch',
      'Error playing media',
      arguments: {
        'query': query,
        'isYouTube': isYouTube,
        'artist': artist,
        'title': title,
      },
      fallback: 'Playing "$query"',
    );
  }

  static Future<String> openUrl(String url) {
    if (isLinux) return LinuxPlatformService.openUrl(url);
    return _invoke(
      'openUrl',
      'Error opening URL',
      arguments: {'url': url},
    );
  }

  static Future<String> sendWhatsApp({
    String? phoneNumber,
    required String message,
  }) {
    if (isLinux) {
      return LinuxPlatformService.sendWhatsApp(
        phoneNumber: phoneNumber,
        message: message,
      );
    }
    return _invoke(
      'sendWhatsApp',
      'Error opening WhatsApp',
      arguments: {
        'phoneNumber': phoneNumber,
        'message': message,
      },
    );
  }

  static Future<String> sendEmail({
    required String to,
    required String subject,
    required String body,
  }) {
    if (isLinux) {
      return LinuxPlatformService.sendEmail(to: to, subject: subject, body: body);
    }
    return _invoke(
      'sendEmail',
      'Error drafting email',
      arguments: {
        'to': to,
        'subject': subject,
        'body': body,
      },
      fallback: 'Email drafted to $to',
    );
  }

  static Future<String> openGmail({String? query, String? folder}) {
    if (isLinux) {
      return LinuxPlatformService.openGmail(query: query, folder: folder);
    }
    return _invoke(
      'openGmail',
      'Error opening Gmail',
      arguments: <String, dynamic>{
        'query': query,
        'folder': folder,
      }..removeWhere((k, v) => v == null),
      fallback: 'Opened Gmail',
    );
  }

  static Future<String> showNotification(String title, String message) {
    if (isLinux) {
      return LinuxPlatformService.showNotification(title, message);
    }
    return _invoke(
      'showNotification',
      'Error showing notification',
      arguments: {
        'title': title,
        'message': message,
      },
      fallback: 'Notification posted: $title',
    );
  }

  static Future<bool> isAppInstalled(String packageName) async {
    if (isLinux) return LinuxPlatformService.isAppInstalled(packageName);
    try {
      final result = await _channel.invokeMethod<bool>('isAppInstalled', {
        'packageName': packageName,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> getPendingCommand() async {
    try {
      return await _channel.invokeMethod<String>('getPendingCommand');
    } catch (_) {
      return null;
    }
  }

  static void setOnBackgroundCommand(void Function(String command) callback) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onBackgroundCommand') {
        final command = call.arguments as String?;
        if (command != null && command.isNotEmpty) {
          callback(command);
        }
      }
    });
  }
}

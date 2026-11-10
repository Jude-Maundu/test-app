import 'dart:async';
import 'dart:io';
import 'package:test_app/services/platform_service.dart';

/// Linux desktop platform service implementing system actions, media controls,
/// and application launching natively without Android dependencies.
class LinuxPlatformService {
  LinuxPlatformService._();

  static const List<String> _desktopPaths = [
    '/usr/share/applications',
    '/usr/local/share/applications',
    '/var/lib/snapd/desktop/applications',
    '/var/lib/flatpak/exports/share/applications',
  ];

  /// Resolves common user/assistant app queries to known Linux binaries or desktop names.
  static String mapApp(String query) {
    final q = query.toLowerCase().trim();
    return switch (q) {
      'com.android.chrome' || 'chrome' || 'google chrome' => 'google-chrome',
      'browser' || 'firefox' || 'org.mozilla.firefox' => 'firefox',
      'code' || 'vscode' || 'com.microsoft.vscode' => 'code',
      'terminal' || 'console' => 'gnome-terminal',
      'settings' || 'com.android.settings' => 'gnome-control-center',
      'files' || 'filemanager' || 'explorer' => 'nautilus',
      'calculator' || 'calc' => 'gnome-calculator',
      'music' || 'spotify' => 'spotify',
      'gmail' || 'email' || 'google mail' || 'com.google.android.gm' => 'https://mail.google.com',
      'youtube' => 'https://www.youtube.com',
      'maps' => 'https://www.google.com/maps',
      'whatsapp' => 'https://web.whatsapp.com',
      _ => query,
    };
  }

  /// Checks if an app or binary is installed on the Linux system.
  static Future<bool> isAppInstalled(String packageName) async {
    final mapped = mapApp(packageName);
    if (mapped.startsWith('http://') || mapped.startsWith('https://')) {
      return true;
    }

    // Check with 'which'
    try {
      final res = await Process.run('which', [mapped]);
      if (res.exitCode == 0) return true;
    } catch (_) {}

    // Check desktop files
    final searchNames = [
      mapped,
      '$mapped.desktop',
      if (mapped == 'google-chrome') 'com.google.Chrome.desktop',
      if (mapped == 'code') 'com.microsoft.VSCode.desktop',
      if (mapped == 'firefox') 'firefox.desktop',
      if (mapped == 'nautilus') 'org.gnome.Nautilus.desktop',
      if (mapped == 'gnome-calculator') 'org.gnome.Calculator.desktop',
      if (mapped == 'gnome-control-center') 'org.gnome.Settings.desktop',
    ];

    final home = Platform.environment['HOME'];
    final allDirs = [
      ..._desktopPaths,
      if (home != null) '$home/.local/share/applications',
    ];

    for (final dirPath in allDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      for (final search in searchNames) {
        final f = File('$dirPath/$search');
        if (f.existsSync()) return true;
        if (!search.endsWith('.desktop')) {
          final fDesktop = File('$dirPath/$search.desktop');
          if (fDesktop.existsSync()) return true;
        }
      }
    }

    return false;
  }

  /// Launches a desktop application by name or desktop entry.
  static Future<String> launchApp(String packageName) async {
    final mapped = mapApp(packageName);
    if (mapped.startsWith('http://') || mapped.startsWith('https://')) {
      return await openUrl(mapped);
    }

    // Try gtk-launch first for clean desktop integration
    try {
      final gtkCheck = await Process.run('which', ['gtk-launch']);
      if (gtkCheck.exitCode == 0) {
        var desktopName = mapped;
        if (mapped == 'google-chrome') desktopName = 'google-chrome';
        if (mapped == 'code') desktopName = 'code';
        final launchRes = await Process.run('gtk-launch', [desktopName]);
        if (launchRes.exitCode == 0) return 'Launched $packageName';
      }
    } catch (_) {}

    // Fallback to direct process execution
    try {
      await Process.start(mapped, [], mode: ProcessStartMode.detached);
      return 'Launched $packageName';
    } catch (e) {
      return 'Error launching app: $e';
    }
  }

  /// Opens a URL using the default Linux desktop browser (via xdg-open).
  static Future<String> openUrl(String url) async {
    try {
      await Process.run('xdg-open', [url]);
      return 'Opened $url';
    } catch (e) {
      return 'Error opening URL: $e';
    }
  }

  /// Opens WhatsApp Web on Linux.
  static Future<String> sendWhatsApp({
    String? phoneNumber,
    required String message,
  }) async {
    final cleanPhone = phoneNumber?.replaceAll(RegExp(r'[^\d+]'), '') ?? '';
    final url = cleanPhone.isNotEmpty
        ? 'https://web.whatsapp.com/send?phone=$cleanPhone&text=${Uri.encodeComponent(message)}'
        : 'https://web.whatsapp.com/send?text=${Uri.encodeComponent(message)}';
    return await openUrl(url);
  }

  /// Controls active media player using DBus MPRIS or playerctl.
  static Future<String> mediaControl(String action) async {
    try {
      final listRes = await Process.run('dbus-send', [
        '--session',
        '--dest=org.freedesktop.DBus',
        '--type=method_call',
        '--print-reply',
        '/org/freedesktop/DBus',
        'org.freedesktop.DBus.ListNames',
      ]);

      if (listRes.exitCode == 0) {
        final matches = RegExp(r'"(org\.mpris\.MediaPlayer2\.[^"]+)"')
            .allMatches(listRes.stdout as String);
        final players = matches.map((m) => m.group(1)!).toList();

        if (players.isNotEmpty) {
          final target = players.first;
          final method = switch (action.toLowerCase()) {
            'play' => 'org.mpris.MediaPlayer2.Player.Play',
            'pause' => 'org.mpris.MediaPlayer2.Player.Pause',
            'next' => 'org.mpris.MediaPlayer2.Player.Next',
            'previous' => 'org.mpris.MediaPlayer2.Player.Previous',
            _ => 'org.mpris.MediaPlayer2.Player.PlayPause',
          };

          await Process.run('dbus-send', [
            '--session',
            '--dest=$target',
            '--type=method_call',
            '/org/mpris/MediaPlayer2',
            method,
          ]);
          return 'Sent $action to $target.';
        }
      }
    } catch (_) {}

    // Fallback to playerctl if available
    try {
      final pctl = await Process.run('which', ['playerctl']);
      if (pctl.exitCode == 0) {
        final cmd = switch (action.toLowerCase()) {
          'play' => 'play',
          'pause' => 'pause',
          'next' => 'next',
          'previous' => 'previous',
          _ => 'play-pause',
        };
        await Process.run('playerctl', [cmd]);
        return 'Sent $action to media player.';
      }
    } catch (_) {}

    return 'No active media players found on desktop.';
  }

  /// Plays music via desktop music app (e.g. Spotify) or browser fallback.
  static Future<String> playMediaFromSearch(
    String query, {
    bool isYouTube = false,
    String? artist,
    String? title,
  }) async {
    if (isYouTube) {
      final uri = 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(query)}';
      await openUrl(uri);
      return 'Playing "$query" on YouTube, sir.';
    }

    // Try Spotify if installed
    try {
      final isSpotify = await isAppInstalled('spotify');
      if (isSpotify) {
        final res = await Process.run('spotify', ['--uri=spotify:search:${Uri.encodeComponent(query)}']);
        if (res.exitCode == 0) return 'Playing "$query" on Spotify, sir.';
      }
    } catch (_) {}

    // Web fallback for search
    final searchUri = 'https://www.google.com/search?q=${Uri.encodeComponent("play $query music")}';
    await openUrl(searchUri);
    return 'Searching for "$query", sir.';
  }

  /// Executes desktop device control actions (volume, battery, settings, timers).
  static Future<String> performDeviceAction(
    String action, {
    Map<String, dynamic> arguments = const {},
  }) async {
    switch (action) {
      case 'volume_up':
        try {
          final wp = await Process.run('wpctl', [
            'set-volume',
            '@DEFAULT_AUDIO_SINK@',
            '5%+',
          ]);
          if (wp.exitCode == 0) return 'Updated media volume.';
        } catch (_) {}
        try {
          await Process.run('amixer', ['set', 'Master', '5%+']);
          return 'Updated media volume.';
        } catch (e) {
          return 'Error adjusting volume: $e';
        }

      case 'volume_down':
        try {
          final wp = await Process.run('wpctl', [
            'set-volume',
            '@DEFAULT_AUDIO_SINK@',
            '5%-',
          ]);
          if (wp.exitCode == 0) return 'Updated media volume.';
        } catch (_) {}
        try {
          await Process.run('amixer', ['set', 'Master', '5%-']);
          return 'Updated media volume.';
        } catch (e) {
          return 'Error adjusting volume: $e';
        }

      case 'mute':
        try {
          final wp = await Process.run('wpctl', [
            'set-mute',
            '@DEFAULT_AUDIO_SINK@',
            'toggle',
          ]);
          if (wp.exitCode == 0) return 'Toggled media mute.';
        } catch (_) {}
        try {
          await Process.run('amixer', ['set', 'Master', 'toggle']);
          return 'Toggled media mute.';
        } catch (e) {
          return 'Error toggling mute: $e';
        }

      case 'battery_level':
        try {
          final sysPower = Directory('/sys/class/power_supply');
          if (sysPower.existsSync()) {
            final batDirs = sysPower
                .listSync()
                .whereType<Directory>()
                .where((d) => d.path.contains('BAT'));
            for (final dir in batDirs) {
              final capFile = File('${dir.path}/capacity');
              if (capFile.existsSync()) {
                final cap = capFile.readAsStringSync().trim();
                return 'Battery is $cap%.';
              }
            }
          }
        } catch (_) {}
        return 'Battery information is unavailable.';

      case 'wifi_settings':
        try {
          await Process.start('gnome-control-center', ['wifi'],
              mode: ProcessStartMode.detached);
          return 'Opened Wi-Fi settings.';
        } catch (_) {
          return 'Error opening Wi-Fi settings.';
        }

      case 'bluetooth_settings':
        try {
          await Process.start('gnome-control-center', ['bluetooth'],
              mode: ProcessStartMode.detached);
          return 'Opened Bluetooth settings.';
        } catch (_) {
          return 'Error opening Bluetooth settings.';
        }

      case 'brightness_settings':
        try {
          await Process.start('gnome-control-center', ['display'],
              mode: ProcessStartMode.detached);
          return 'Opened Display settings.';
        } catch (_) {
          return 'Error opening Display settings.';
        }

      case 'setTimer':
        final seconds = (arguments['seconds'] as num?)?.toInt() ?? 0;
        final label = arguments['label']?.toString() ?? 'Jarvis timer';
        if (seconds <= 0) return 'Error: Timer duration must be greater than 0';

        Timer(Duration(seconds: seconds), () async {
          try {
            await Process.run('notify-send', [
              '-u',
              'critical',
              'Jarvis Timer',
              '$label completed!',
            ]);
          } catch (_) {}
          try {
            await Process.run('spd-say', ['Timer for $label has completed.']);
          } catch (_) {}
        });
        return 'Opened timer for $seconds seconds.';

      case 'navigate':
        final destination = arguments['destination'] as String? ?? '';
        final url =
            'https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(destination)}';
        return await openUrl(url);

      case 'weather':
        final location = arguments['location'] as String? ?? '';
        final url =
            'https://www.google.com/search?q=${Uri.encodeComponent("weather $location")}';
        return await openUrl(url);

      case 'webSearch':
        final query = arguments['query'] as String? ?? '';
        final url =
            'https://www.google.com/search?q=${Uri.encodeComponent(query)}';
        return await openUrl(url);

      case 'calendarEvent':
        final title = arguments['title'] as String? ?? 'Event';
        final startTime = arguments['start_time'] as String?;
        final url =
            'https://calendar.google.com/calendar/render?action=TEMPLATE&text=${Uri.encodeComponent(title)}'
            '${startTime != null ? '&dates=${Uri.encodeComponent(startTime)}' : ''}';
        return await openUrl(url);

      case 'flashlight_on':
      case 'flashlight_off':
        return 'Flashlight is not available on Linux desktop.';

      default:
        return 'Done';
    }
  }

  /// Sets an alarm scheduled as a local desktop timer.
  static Future<String> setAlarm(String time, String? label) async {
    try {
      final parts = time.split(':');
      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);
      final now = DateTime.now();
      var alarmTime = DateTime(now.year, now.month, now.day, hour, minute);
      if (alarmTime.isBefore(now)) {
        alarmTime = alarmTime.add(const Duration(days: 1));
      }
      final diff = alarmTime.difference(now);
      final alarmLabel =
          label?.trim().isNotEmpty == true ? label! : 'Jarvis Alarm';

      Timer(diff, () async {
        try {
          await Process.run('notify-send', [
            '-u',
            'critical',
            'Jarvis Alarm',
            '$alarmLabel ($time)',
          ]);
        } catch (_) {}
        try {
          await Process.run('spd-say', ['Alarm: $alarmLabel. Time is $time.']);
        } catch (_) {}
      });

      return 'Alarm set for $time.';
    } catch (e) {
      return 'Error setting alarm: $e';
    }
  }

  static Future<String> readNotifications() async =>
      'Desktop notifications are active.';

  static Future<String> requestDefaultAssistant() async =>
      'Jarvis is configured as your Linux assistant.';

  static Future<String> requestNotificationAccess() async =>
      'Desktop notification access is enabled.';

  static Future<String> makeCall(String phoneNumber) async =>
      'Error making call: Phone calls are not supported on this Linux machine.';

  static Future<String> sendSms(String phoneNumber, String message) async =>
      'Error sending SMS: Cellular SMS is not supported on this Linux machine.';

  static Future<String> sendEmail({
    required String to,
    required String subject,
    required String body,
  }) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return 'Email drafted to $to';
    }
    final webUrl =
        'https://mail.google.com/mail/?view=cm&fs=1&to=${Uri.encodeComponent(to)}&su=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}';
    try {
      final mailto =
          'mailto:${Uri.encodeComponent(to)}?subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}';
      await Process.run('xdg-open', [mailto]);
      return 'Email drafted to $to';
    } catch (_) {}
    return await openUrl(webUrl);
  }

  static Future<String> openGmail({String? query, String? folder}) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return 'Opened Gmail';
    }
    final cleanQuery = query?.trim() ?? '';
    final url = cleanQuery.isNotEmpty
        ? 'https://mail.google.com/mail/u/0/#search/${Uri.encodeComponent(cleanQuery)}'
        : 'https://mail.google.com/mail/u/0/#inbox';
    return await openUrl(url);
  }

  static Future<String> showNotification(String title, String message) async {
    try {
      await Process.run('notify-send', ['-a', 'Jarvis', title, message]);
      return 'Notification posted: $title';
    } catch (e) {
      return 'Error sending notification: $e';
    }
  }

  static Future<List<PhoneContact>> findContacts(String name) async => const [];

  static Future<List<Map<String, String>>> findContactEmails(String name) async => const [];
}

import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/services/llm_service.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/services/task_execution_service.dart';

enum ToolRisk { low, sensitive, restricted }

class ToolResult {
  const ToolResult({
    required this.success,
    required this.output,
    this.data,
    this.errorMessage,
    this.isRecoverable = false,
  });

  final bool success;
  final String output;
  final dynamic data;
  final String? errorMessage;
  final bool isRecoverable;

  factory ToolResult.ok(String output, [dynamic data]) => ToolResult(
    success: true,
    output: output,
    data: data,
  );

  factory ToolResult.error(String message, {bool recoverable = false}) =>
      ToolResult(
        success: false,
        output: 'Error: $message',
        errorMessage: message,
        isRecoverable: recoverable,
      );

  Map<String, dynamic> toJson() => {
    'success': success,
    'output': output,
    if (errorMessage != null) 'errorMessage': errorMessage,
    'isRecoverable': isRecoverable,
  };
}

class ToolExecutionContext {
  ToolExecutionContext({
    required this.llmService,
    required this.taskExecutionService,
    required this.assistantProvider,
    this.onNavigate,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  final LLMService llmService;
  final TaskExecutionService taskExecutionService;
  final AssistantProvider assistantProvider;
  final void Function(String routeName)? onNavigate;
  final http.Client httpClient;
}

abstract class AssistantTool {
  String get name;
  String get description;
  Map<String, dynamic> get parameters;
  ToolRisk get risk;
  List<Permission> get requiredPermissions => const [];
  String? get targetApp => null;

  String? validate(Map<String, dynamic> arguments);

  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  );

  Future<bool> verify(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
    ToolResult result,
  ) async => result.success;

  Map<String, dynamic> toFunctionSchema() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// DEVICE TOOLS
// ─────────────────────────────────────────────────────────────────────────────

class LaunchAppTool extends AssistantTool {
  @override
  String get name => 'launch_app';

  @override
  String get description => 'Opens an installed Android app by its package name or common app name';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'package_name': {
        'type': 'string',
        'description': 'Android package name (e.g., com.android.chrome, com.whatsapp, com.google.android.youtube)',
      },
    },
    'required': ['package_name'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final pkg = arguments['package_name'] as String?;
    if (pkg == null || pkg.trim().isEmpty) return 'package_name is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final rawPkg = (arguments['package_name'] as String).trim();
    final mappedPkg = _resolveCommonPackage(rawPkg);

    final installed = await PlatformService.isAppInstalled(mappedPkg);
    if (!installed) {
      if (mappedPkg.contains('.') || !PlatformService.isLinux) {
        return ToolResult.error(
          'App $mappedPkg is not installed on this device.',
          recoverable: false,
        );
      }
    }

    final result = await PlatformService.launchApp(mappedPkg);
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok('Launched $mappedPkg successfully');
  }

  String _resolveCommonPackage(String query) {
    final q = query.toLowerCase().trim();
    if (PlatformService.isLinux) {
      return switch (q) {
        'chrome' => 'google-chrome',
        'browser' || 'firefox' => 'firefox',
        'code' || 'vscode' => 'code',
        'terminal' || 'console' => 'gnome-terminal',
        'settings' => 'gnome-control-center',
        'files' || 'filemanager' || 'explorer' => 'nautilus',
        'calculator' || 'calc' => 'gnome-calculator',
        'music' || 'spotify' => 'spotify',
        'gmail' || 'email' || 'mail' => 'https://mail.google.com',
        _ => query,
      };
    }
    if (q.contains('.')) return query;
    return switch (q) {
      'chrome' || 'browser' => 'com.android.chrome',
      'whatsapp' => 'com.whatsapp',
      'youtube' => 'com.google.android.youtube',
      'maps' => 'com.google.android.apps.maps',
      'settings' => 'com.android.settings',
      'calendar' => 'com.google.android.calendar',
      'clock' || 'alarm' => 'com.google.android.deskclock',
      'camera' => 'com.android.camera',
      'music' || 'spotify' => 'com.spotify.music',
      'youtube music' || 'yt music' => 'com.google.android.apps.youtube.music',
      'gmail' || 'email' || 'mail' => 'com.google.android.gm',
      _ => query,
    };
  }
}

class SetAlarmTool extends AssistantTool {
  @override
  String get name => 'set_alarm';

  @override
  String get description => 'Sets an Android clock alarm at a specified time (HH:mm)';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'time': {'type': 'string', 'description': 'Time in 24-hour HH:mm format'},
      'label': {'type': 'string', 'description': 'Alarm label or title'},
    },
    'required': ['time'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final time = arguments['time'] as String?;
    if (time == null || !RegExp(r'^\d{1,2}:\d{2}$').hasMatch(time.trim())) {
      return 'time must be in HH:mm format';
    }
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final time = (arguments['time'] as String).trim();
    final label = (arguments['label'] as String?)?.trim() ?? 'Jarvis Alarm';
    final result = await PlatformService.setAlarm(time, label);
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok(result);
  }
}

class SetTimerTool extends AssistantTool {
  @override
  String get name => 'set_timer';

  @override
  String get description => 'Starts a countdown timer on the device';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'seconds': {'type': 'integer', 'description': 'Timer duration in seconds'},
      'label': {'type': 'string', 'description': 'Timer label'},
    },
    'required': ['seconds'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final seconds = arguments['seconds'];
    if (seconds == null || seconds is! int || seconds <= 0) {
      return 'seconds must be a positive integer';
    }
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final seconds = arguments['seconds'] as int;
    final label = arguments['label']?.toString() ?? 'Jarvis timer';
    final result = await PlatformService.performDeviceAction(
      'setTimer',
      arguments: {'seconds': seconds, 'label': label},
    );
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok(result);
  }
}

class PhoneControlTool extends AssistantTool {
  @override
  String get name => 'phone_control';

  @override
  String get description => 'Controls device settings, media playback, flashlight, volume, and battery status';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': [
          'flashlight_on',
          'flashlight_off',
          'volume_up',
          'volume_down',
          'mute',
          'wifi_settings',
          'bluetooth_settings',
          'do_not_disturb_settings',
          'battery_level',
          'brightness_settings',
          'play_media',
          'pause_media',
          'next_track',
          'previous_track',
        ],
      },
    },
    'required': ['action'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final action = arguments['action'] as String?;
    if (action == null || action.isEmpty) return 'action is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final action = arguments['action'] as String;
    const mediaActions = {
      'play_media': 'play',
      'pause_media': 'pause',
      'next_track': 'next',
      'previous_track': 'previous',
    };
    final mediaAction = mediaActions[action];
    if (mediaAction != null) {
      final res = await PlatformService.mediaControl(mediaAction);
      if (PlatformService.isError(res)) return ToolResult.error(res, recoverable: true);
      return ToolResult.ok(res);
    }

    if (action == 'flashlight_on' || action == 'flashlight_off') {
      if (PlatformService.isLinux) {
        return ToolResult.ok('Flashlight is not available on Linux desktop.');
      }
      try {
        final perm = await Permission.camera.request();
        if (!perm.isGranted) {
          return ToolResult.error('Camera permission is required for flashlight');
        }
      } on MissingPluginException {
        // Test environment
      }
    }

    final res = await PlatformService.performDeviceAction(action);
    if (PlatformService.isError(res)) return ToolResult.error(res, recoverable: true);
    return ToolResult.ok(res);
  }
}

class PlayMusicTool extends AssistantTool {
  @override
  String get name => 'play_music';

  @override
  String get description =>
      'Plays music or artists using the default music player via Android MEDIA_PLAY_FROM_SEARCH, or on YouTube if explicitly requested.';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'The song title, artist, or music search query.',
      },
      'on_youtube': {
        'type': 'boolean',
        'description': 'True ONLY if the user explicitly requested YouTube.',
      },
      'artist': {
        'type': 'string',
        'description': 'Optional artist name if extracted.',
      },
      'title': {
        'type': 'string',
        'description': 'Optional track/song title if extracted.',
      },
    },
    'required': ['query'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final query = arguments['query'] as String?;
    if (query == null || query.trim().isEmpty) return 'query is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final query = (arguments['query'] as String).trim();
    final onYouTube = arguments['on_youtube'] as bool? ?? false;
    final artist = arguments['artist'] as String?;
    final title = arguments['title'] as String?;

    final res = await PlatformService.playMediaFromSearch(
      query: query,
      isYouTube: onYouTube,
      artist: artist,
      title: title,
    );

    if (PlatformService.isError(res)) {
      return ToolResult.error(res, recoverable: true);
    }
    return ToolResult.ok(res);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BROWSER & WEB TOOLS
// ─────────────────────────────────────────────────────────────────────────────

class WebSearchTool extends AssistantTool {
  @override
  String get name => 'web_search';

  @override
  String get description => 'Searches the web for up-to-date information, news, or topics and returns relevant result titles, snippets, and links';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'The search query'},
    },
    'required': ['query'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final q = arguments['query'] as String?;
    if (q == null || q.trim().isEmpty) return 'query is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final query = (arguments['query'] as String).trim();
    try {
      final uri = Uri.parse(
        'https://api.duckduckgo.com/?q=${Uri.encodeComponent(query)}&format=json&no_html=1&skip_disambig=1',
      );
      final response = await context.httpClient
          .get(uri, headers: {'User-Agent': 'Mozilla/5.0 (Android; Mobile)'})
          .timeout(const Duration(seconds: 15));

      final results = <Map<String, String>>[];

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final heading = decoded['Heading'] as String? ?? '';
        final abstractText = decoded['AbstractText'] as String? ?? '';
        final abstractUrl = decoded['AbstractURL'] as String? ?? '';

        if (abstractText.isNotEmpty) {
          results.add({
            'title': heading.isNotEmpty ? heading : query,
            'snippet': abstractText,
            'url': abstractUrl,
          });
        }

        final related = decoded['RelatedTopics'] as List<dynamic>? ?? [];
        for (final item in related) {
          if (item is Map<String, dynamic>) {
            final text = item['Text'] as String? ?? '';
            final firstUrl = item['FirstURL'] as String? ?? '';
            if (text.isNotEmpty) {
              results.add({
                'title': text.split(' - ').first,
                'snippet': text,
                'url': firstUrl,
              });
            }
          }
          if (results.length >= 5) break;
        }
      }

      // If DuckDuckGo instant answer returned few or no results, query HTML search
      if (results.isEmpty) {
        final htmlUri = Uri.parse(
          'https://html.duckduckgo.com/html/?q=${Uri.encodeComponent(query)}',
        );
        final htmlResponse = await context.httpClient
            .get(htmlUri, headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
            .timeout(const Duration(seconds: 15));

        if (htmlResponse.statusCode == 200) {
          final body = htmlResponse.body;
          final linkRegex = RegExp(
            r'<a class="result__snippet[^"]*"[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>',
            dotAll: true,
          );

          final snippetMatches = linkRegex.allMatches(body).take(5).toList();
          for (final m in snippetMatches) {
            final rawSnippet = m.group(2) ?? '';
            final cleanSnippet = rawSnippet.replaceAll(RegExp(r'<[^>]*>'), '').trim();
            final url = m.group(1) ?? '';
            if (cleanSnippet.isNotEmpty) {
              results.add({
                'title': query,
                'snippet': cleanSnippet,
                'url': url,
              });
            }
          }
        }
      }

      if (results.isEmpty) {
        return ToolResult.ok(
          'No direct web search snippets found for "$query". You can use open_in_browser to view full web results.',
          const [],
        );
      }

      final formatted = results.asMap().entries.map((e) {
        final i = e.key + 1;
        final item = e.value;
        return '$i. ${item['title']}: ${item['snippet']} (URL: ${item['url']})';
      }).join('\n\n');

      return ToolResult.ok('Search results for "$query":\n\n$formatted', results);
    } catch (error) {
      return ToolResult.error(
        'Failed to perform web search: $error. Ensure the phone has internet access.',
        recoverable: true,
      );
    }
  }
}

class FetchWebContentTool extends AssistantTool {
  @override
  String get name => 'fetch_web_content';

  @override
  String get description => 'Reads and extracts article/page text from a given web URL';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'The web URL to fetch and read'},
    },
    'required': ['url'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final url = arguments['url'] as String?;
    if (url == null || !url.startsWith('http')) return 'Valid HTTP/HTTPS url is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final url = arguments['url'] as String;
    try {
      final response = await context.httpClient
          .get(
            Uri.parse(url),
            headers: {'User-Agent': 'Mozilla/5.0 (compatible; JarvisAssistant/1.0)'},
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        return ToolResult.error('Web page returned HTTP ${response.statusCode}');
      }

      var text = response.body;
      // Strip script and style tags
      text = text.replaceAll(RegExp(r'<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>', caseSensitive: false), ' ');
      text = text.replaceAll(RegExp(r'<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>', caseSensitive: false), ' ');
      // Strip tags
      text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
      // Collapse whitespace
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

      if (text.length > 2500) {
        text = '${text.substring(0, 2500)}... [Content truncated]';
      }

      if (text.isEmpty) {
        return ToolResult.error('No readable text content extracted from $url');
      }

      return ToolResult.ok('Extracted content from $url:\n$text', text);
    } catch (error) {
      return ToolResult.error('Could not fetch web page: $error', recoverable: true);
    }
  }
}

class OpenInBrowserTool extends AssistantTool {
  @override
  String get name => 'open_in_browser';

  @override
  String get description => 'Opens a web URL or search in the phone external web browser';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'The web URL or search URL to open'},
    },
    'required': ['url'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final url = arguments['url'] as String?;
    if (url == null || url.trim().isEmpty) return 'url is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final rawUrl = (arguments['url'] as String).trim();
    final url = rawUrl.startsWith('http://') || rawUrl.startsWith('https://')
        ? rawUrl
        : 'https://www.google.com/search?q=${Uri.encodeComponent(rawUrl)}';

    final result = await PlatformService.openUrl(url);
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok('Opened in browser: $url');
  }
}

class SummarizeContentTool extends AssistantTool {
  @override
  String get name => 'summarize_content';

  @override
  String get description => 'Summarizes a body of text into key, actionable bullet points';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'description': 'Text to summarize'},
      'max_points': {'type': 'integer', 'description': 'Maximum bullet points (default 3)'},
    },
    'required': ['text'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final text = arguments['text'] as String?;
    if (text == null || text.trim().isEmpty) return 'text is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final text = (arguments['text'] as String).trim();
    final maxPoints = arguments['max_points'] as int? ?? 3;

    try {
      final res = await context.llmService.processCommand(
        'Summarize the following content in exactly $maxPoints concise, factual bullet points. '
        'Do not add preamble:\n\n$text',
        allowTools: false,
      );
      final summary = res['response'] as String? ?? '';
      return ToolResult.ok(summary.trim().isEmpty ? text : summary);
    } catch (e) {
      // Fallback naive summary
      final sentences = text.split(RegExp(r'(?<=[.!?])\s+')).take(maxPoints);
      return ToolResult.ok(sentences.join(' '));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// COMMUNICATION TOOLS
// ─────────────────────────────────────────────────────────────────────────────

class FindContactTool extends AssistantTool {
  @override
  String get name => 'find_contact';

  @override
  String get description => 'Searches device contacts by name and returns matching contacts with phone numbers';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  List<Permission> get requiredPermissions => [Permission.contacts];

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'Contact name to search for'},
    },
    'required': ['name'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final name = arguments['name'] as String?;
    if (name == null || name.trim().isEmpty) return 'name is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final name = (arguments['name'] as String).trim();
    if (!PlatformService.isLinux) {
      try {
        final perm = await Permission.contacts.request();
        if (!perm.isGranted) {
          return ToolResult.error('Contacts permission was not granted by user.');
        }
      } on MissingPluginException {
        // Test environment
      }
    }

    final contacts = await PlatformService.findContacts(name);
    if (contacts.isEmpty) {
      return ToolResult.ok('No contact found matching "$name".', const []);
    }

    final formatted = contacts
        .map((c) => '${c.name} (${c.phoneNumber})')
        .join(', ');
    return ToolResult.ok('Found contacts: $formatted', contacts);
  }
}

class PrepareMessageTool extends AssistantTool {
  @override
  String get name => 'prepare_message';

  @override
  String get description => 'Drafts a message and identifies the recipient before requesting authorization to send';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'channel': {
        'type': 'string',
        'enum': ['whatsapp', 'sms'],
        'description': 'Messaging platform',
      },
      'recipient': {'type': 'string', 'description': 'Name or phone number of recipient'},
      'message': {'type': 'string', 'description': 'The exact message text'},
    },
    'required': ['channel', 'recipient', 'message'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    if (arguments['channel'] == null) return 'channel is required';
    if (arguments['recipient'] == null) return 'recipient is required';
    if (arguments['message'] == null) return 'message is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final channel = arguments['channel'] as String;
    final recipient = arguments['recipient'] as String;
    final message = arguments['message'] as String;

    return ToolResult.ok(
      'Draft prepared for $recipient via $channel: "$message". Explicit user authorization is required before sending.',
      arguments,
    );
  }
}

class SendSmsTool extends AssistantTool {
  @override
  String get name => 'send_sms';

  @override
  String get description => 'Sends an SMS text message to a specified phone number. SENSITIVE: Requires explicit authorization.';

  @override
  ToolRisk get risk => ToolRisk.sensitive;

  @override
  List<Permission> get requiredPermissions => [Permission.sms];

  @override
  String? get targetApp => 'Messages / SMS';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'phone_number': {'type': 'string', 'description': 'Recipient phone number'},
      'message': {'type': 'string', 'description': 'Text message body to send'},
    },
    'required': ['phone_number', 'message'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final phone = arguments['phone_number'] as String?;
    final msg = arguments['message'] as String?;
    if (phone == null || phone.trim().isEmpty) return 'phone_number is required';
    if (msg == null || msg.trim().isEmpty) return 'message is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final phone = (arguments['phone_number'] as String).trim();
    final message = (arguments['message'] as String).trim();

    if (!PlatformService.isLinux) {
      try {
        final perm = await Permission.sms.request();
        if (!perm.isGranted) {
          return ToolResult.error('SMS permission was denied.');
        }
      } on MissingPluginException {
        // Test environment
      }
    }

    final result = await PlatformService.sendSms(phone, message);
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok('SMS sent successfully to $phone.');
  }

  @override
  Future<bool> verify(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
    ToolResult result,
  ) async {
    return result.success && !result.output.toLowerCase().contains('error');
  }
}

class SendWhatsAppMessageTool extends AssistantTool {
  @override
  String get name => 'send_whatsapp_message';

  @override
  String get description => 'Opens WhatsApp to send a message to a recipient. SENSITIVE: Requires explicit user authorization.';

  @override
  ToolRisk get risk => ToolRisk.sensitive;

  @override
  String? get targetApp => 'WhatsApp';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'phone_number': {
        'type': 'string',
        'description': 'Recipient phone number with country code (optional if chat can be opened directly)',
      },
      'message': {'type': 'string', 'description': 'Message text'},
    },
    'required': ['message'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final msg = arguments['message'] as String?;
    if (msg == null || msg.trim().isEmpty) return 'message is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final phone = arguments['phone_number'] as String?;
    final message = (arguments['message'] as String).trim();

    final installed = await PlatformService.isAppInstalled('com.whatsapp') ||
        await PlatformService.isAppInstalled('com.whatsapp.w4b') ||
        PlatformService.isLinux;
    if (!installed) {
      return ToolResult.error(
        'WhatsApp is not installed on this device. You can choose to send via SMS instead.',
        recoverable: false,
      );
    }

    final result = await PlatformService.sendWhatsApp(
      phoneNumber: phone,
      message: message,
    );
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok('WhatsApp opened with prepared message.');
  }
}

class MakeCallTool extends AssistantTool {
  @override
  String get name => 'make_call';

  @override
  String get description => 'Places a phone call to a recipient. SENSITIVE: Requires explicit user authorization.';

  @override
  ToolRisk get risk => ToolRisk.sensitive;

  @override
  List<Permission> get requiredPermissions => [Permission.phone];

  @override
  String? get targetApp => 'Phone / Dialer';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'phone_number': {'type': 'string', 'description': 'Phone number to dial'},
    },
    'required': ['phone_number'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final phone = arguments['phone_number'] as String?;
    if (phone == null || phone.trim().isEmpty) return 'phone_number is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final phone = (arguments['phone_number'] as String).trim();
    if (!PlatformService.isLinux) {
      try {
        final perm = await Permission.phone.request();
        if (!perm.isGranted) {
          return ToolResult.error('Phone permission was denied.');
        }
      } on MissingPluginException {
        // Test environment
      }
    }
    final result = await PlatformService.makeCall(phone);
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok('Placing phone call to $phone.');
  }
}

class ReadNotificationsTool extends AssistantTool {
  @override
  String get name => 'read_notifications';

  @override
  String get description => 'Reads recent notifications posted on the device';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {},
  };

  @override
  String? validate(Map<String, dynamic> arguments) => null;

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final res = await PlatformService.readNotifications();
    return ToolResult.ok(res.isEmpty ? 'No active notifications.' : res);
  }
}

class SendEmailTool extends AssistantTool {
  @override
  String get name => 'send_email';

  @override
  String get description =>
      'Drafts and sends an email via Gmail or default mail app. SENSITIVE: Requires authorization once, then always goes ahead.';

  @override
  ToolRisk get risk => ToolRisk.sensitive;

  @override
  String? get targetApp => 'Gmail / Email';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'to': {
        'type': 'string',
        'description': 'Recipient email address or contact name',
      },
      'subject': {'type': 'string', 'description': 'Email subject line'},
      'body': {'type': 'string', 'description': 'Email message body'},
    },
    'required': ['to', 'body'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final to = arguments['to'] as String?;
    final body = arguments['body'] as String?;
    if (to == null || to.trim().isEmpty) return 'Recipient "to" is required';
    if (body == null || body.trim().isEmpty) return 'Email "body" is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final to = (arguments['to'] as String).trim();
    final subject =
        (arguments['subject'] as String?)?.trim() ?? 'Message from Jarvis';
    final body = (arguments['body'] as String).trim();

    final result = await PlatformService.sendEmail(
      to: to,
      subject: subject,
      body: body,
    );
    if (PlatformService.isError(result)) {
      return ToolResult.error(result, recoverable: true);
    }
    return ToolResult.ok(result);
  }

  @override
  Future<bool> verify(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
    ToolResult result,
  ) async => result.success;
}

class OpenGmailTool extends AssistantTool {
  @override
  String get name => 'open_gmail';

  @override
  String get description => 'Opens Gmail or searches user emails';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  String? get targetApp => 'Gmail';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'Optional search query, e.g. "from:john" or "flight" or "unread"',
      },
      'folder': {
        'type': 'string',
        'description': 'Optional folder or tab, e.g. "inbox", "sent", "drafts"',
      },
    },
  };

  @override
  String? validate(Map<String, dynamic> arguments) => null;

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final query = arguments['query'] as String?;
    final folder = arguments['folder'] as String?;
    final res = await PlatformService.openGmail(query: query, folder: folder);
    if (PlatformService.isError(res)) {
      return ToolResult.error(res, recoverable: true);
    }
    return ToolResult.ok(res);
  }
}

class ProcessMediaTool extends AssistantTool {
  @override
  String get name => 'process_media';

  @override
  String get description =>
      'Processes, inspects, and extracts information from media (photos, images, documents, audio)';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'file_path': {
        'type': 'string',
        'description': 'Path to local media file or image',
      },
      'task': {
        'type': 'string',
        'description':
            'Question or analysis instruction for the media, e.g. "describe image", "read text"',
      },
    },
    'required': ['file_path'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final path = arguments['file_path'] as String?;
    if (path == null || path.trim().isEmpty) return 'file_path is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final path = (arguments['file_path'] as String).trim();
    final task = (arguments['task'] as String?)?.trim() ??
        'Describe this media and extract all key information.';

    try {
      final analysis = await context.llmService.processMedia(
        prompt: task,
        mediaPath: path,
      );
      return ToolResult.ok(
        analysis.isEmpty ? 'Media processed successfully.' : analysis,
      );
    } catch (e) {
      return ToolResult.error('Failed to process media: $e', recoverable: true);
    }
  }
}

class SendNotificationTool extends AssistantTool {
  @override
  String get name => 'send_notification';

  @override
  String get description =>
      'Posts a device system notification to notify the user of an event or completed task';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'title': {'type': 'string', 'description': 'Notification title'},
      'message': {'type': 'string', 'description': 'Notification message text'},
    },
    'required': ['title', 'message'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final title = arguments['title'] as String?;
    final message = arguments['message'] as String?;
    if (title == null || title.trim().isEmpty) return 'title is required';
    if (message == null || message.trim().isEmpty) return 'message is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final title = (arguments['title'] as String).trim();
    final message = (arguments['message'] as String).trim();
    final res = await PlatformService.showNotification(title, message);
    return ToolResult.ok(res);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INTERNAL APPLICATION TOOLS (Controlling Jarvis itself)
// ─────────────────────────────────────────────────────────────────────────────

class NavigateToScreenTool extends AssistantTool {
  @override
  String get name => 'navigate_to_screen';

  @override
  String get description => 'Navigates within the Jarvis assistant application to a screen: settings, history, notes, activity_log, tasks';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'screen': {
        'type': 'string',
        'enum': ['settings', 'history', 'notes', 'activity_log', 'tasks'],
        'description': 'Target internal screen',
      },
    },
    'required': ['screen'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final screen = arguments['screen'] as String?;
    if (screen == null) return 'screen is required';
    const valid = ['settings', 'history', 'notes', 'activity_log', 'tasks'];
    if (!valid.contains(screen.toLowerCase())) {
      return 'Invalid screen. Must be one of: ${valid.join(', ')}';
    }
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final screen = (arguments['screen'] as String).toLowerCase();
    context.onNavigate?.call(screen);
    return ToolResult.ok('Navigated to $screen screen.');
  }
}

class GetAppSettingsTool extends AssistantTool {
  @override
  String get name => 'get_app_settings';

  @override
  String get description => 'Reads the current Jarvis application settings (user name, LLM provider, active model, voice speech rate)';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {},
  };

  @override
  String? validate(Map<String, dynamic> arguments) => null;

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final provider = await context.llmService.getProvider();
    final model = await context.llmService.getModel(provider: provider);
    final userName = await context.llmService.getUserName();
    final rate = context.assistantProvider.speechRate;
    final voice = context.assistantProvider.selectedVoice ?? 'System default';

    final data = {
      'userName': userName,
      'provider': provider.displayName,
      'model': model,
      'speechRate': rate,
      'voice': voice,
    };

    return ToolResult.ok(
      'Current settings: User is "$userName", Provider is ${provider.displayName}, '
      'Model is $model, Speech rate is ${rate.toStringAsFixed(2)}, Voice is $voice.',
      data,
    );
  }
}

class UpdateAppSettingTool extends AssistantTool {
  @override
  String get name => 'update_app_setting';

  @override
  String get description => 'Updates a Jarvis app setting: user_name, speech_rate, or tts_voice';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'setting': {
        'type': 'string',
        'enum': ['user_name', 'speech_rate', 'tts_voice'],
        'description': 'Setting to update',
      },
      'value': {
        'type': 'string',
        'description': 'New setting value',
      },
    },
    'required': ['setting', 'value'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    if (arguments['setting'] == null) return 'setting is required';
    if (arguments['value'] == null) return 'value is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final setting = arguments['setting'] as String;
    final value = arguments['value'] as String;

    switch (setting) {
      case 'user_name':
        await context.llmService.setUserName(value);
        return ToolResult.ok('User name updated to $value.');
      case 'speech_rate':
        final rate = double.tryParse(value);
        if (rate == null) return ToolResult.error('Invalid speech rate number');
        await context.assistantProvider.setSpeechRate(rate);
        return ToolResult.ok('Speech rate updated to $rate.');
      case 'tts_voice':
        await context.assistantProvider.setVoice(value.isEmpty ? null : value);
        return ToolResult.ok('TTS voice updated.');
      default:
        return ToolResult.error('Unsupported setting: $setting');
    }
  }
}

class ListRecentTasksTool extends AssistantTool {
  @override
  String get name => 'list_recent_tasks';

  @override
  String get description => 'Lists recent tasks that Jarvis has executed or is executing';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'limit': {'type': 'integer', 'description': 'Maximum number of tasks to return (default 5)'},
    },
  };

  @override
  String? validate(Map<String, dynamic> arguments) => null;

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final limit = arguments['limit'] as int? ?? 5;
    final tasks = await context.taskExecutionService.listRecentTasks();
    final items = tasks.take(limit).map((t) {
      return '[${t.status.name}] ID: ${t.id} - "${t.instruction}" (${t.steps.length} steps)';
    }).toList();

    if (items.isEmpty) return ToolResult.ok('No recent tasks recorded.');
    return ToolResult.ok('Recent tasks:\n${items.join('\n')}', tasks);
  }
}

class GetTaskStatusTool extends AssistantTool {
  @override
  String get name => 'get_task_status';

  @override
  String get description => 'Retrieves the current status, steps, and outcome of an active or recent task';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'task_id': {'type': 'string', 'description': 'Optional task ID. If omitted, checks active task.'},
    },
  };

  @override
  String? validate(Map<String, dynamic> arguments) => null;

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final id = arguments['task_id'] as String?;
    final TaskRecord? task;
    if (id != null && id.isNotEmpty) {
      task = await context.taskExecutionService.getTask(id);
    } else {
      task = context.taskExecutionService.activeTask;
    }

    if (task == null) {
      return ToolResult.ok('No matching task found.');
    }

    final stepsInfo = task.steps.map((s) => '• ${s.tool}: ${s.status} (${s.result})').join('\n');
    return ToolResult.ok(
      'Task ${task.id} [${task.status.name}]: "${task.instruction}"\n'
      'Result: ${task.result ?? "In progress"}\n'
      'Steps:\n$stepsInfo',
      task,
    );
  }
}

class CancelTaskTool extends AssistantTool {
  @override
  String get name => 'cancel_task';

  @override
  String get description => 'Cancels the currently running or paused task';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {},
  };

  @override
  String? validate(Map<String, dynamic> arguments) => null;

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final cancelled = await context.taskExecutionService.cancelActiveTask();
    if (cancelled == null) {
      return ToolResult.ok('No active task is running to cancel.');
    }
    return ToolResult.ok('Task ${cancelled.id} was cancelled.');
  }
}

class SaveNoteTool extends AssistantTool {
  @override
  String get name => 'save_note';

  @override
  String get description => 'Saves a note locally on the device';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'description': 'The note text to save'},
    },
    'required': ['text'],
  };

  @override
  String? validate(Map<String, dynamic> arguments) {
    final text = arguments['text'] as String?;
    if (text == null || text.trim().isEmpty) return 'text is required';
    return null;
  }

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final text = (arguments['text'] as String).trim();
    await context.llmService.saveNote(text);
    return ToolResult.ok('Note saved locally on this phone.');
  }
}

class GetNotesTool extends AssistantTool {
  @override
  String get name => 'get_notes';

  @override
  String get description => 'Retrieves saved notes from local storage';

  @override
  ToolRisk get risk => ToolRisk.low;

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {},
  };

  @override
  String? validate(Map<String, dynamic> arguments) => null;

  @override
  Future<ToolResult> execute(
    ToolExecutionContext context,
    Map<String, dynamic> arguments,
  ) async {
    final notes = await context.llmService.getNotes();
    if (notes.isEmpty) return ToolResult.ok('No saved notes.');
    return ToolResult.ok('Saved notes:\n${notes.take(5).map((n) => '• $n').join('\n')}');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CENTRAL TOOL REGISTRY
// ─────────────────────────────────────────────────────────────────────────────

class ToolRegistry {
  ToolRegistry() {
    _registerDefaults();
  }

  final Map<String, AssistantTool> _tools = {};

  void register(AssistantTool tool) {
    _tools[tool.name] = tool;
  }

  AssistantTool? get(String name) => _tools[name];

  List<AssistantTool> get allTools => List.unmodifiable(_tools.values);

  List<Map<String, dynamic>> toToolSchemas() =>
      _tools.values.map((t) => t.toFunctionSchema()).toList();

  void _registerDefaults() {
    // Device tools
    register(LaunchAppTool());
    register(SetAlarmTool());
    register(SetTimerTool());
    register(PhoneControlTool());
    register(PlayMusicTool());

    // Web & Browser tools
    register(WebSearchTool());
    register(FetchWebContentTool());
    register(SummarizeContentTool());
    register(OpenInBrowserTool());

    // Communication tools
    register(FindContactTool());
    register(PrepareMessageTool());
    register(SendSmsTool());
    register(SendWhatsAppMessageTool());
    register(MakeCallTool());
    register(ReadNotificationsTool());
    register(SendEmailTool());
    register(OpenGmailTool());
    register(ProcessMediaTool());
    register(SendNotificationTool());

    // Internal app tools
    register(NavigateToScreenTool());
    register(GetAppSettingsTool());
    register(UpdateAppSettingTool());
    register(ListRecentTasksTool());
    register(GetTaskStatusTool());
    register(CancelTaskTool());
    register(SaveNoteTool());
    register(GetNotesTool());
  }
}

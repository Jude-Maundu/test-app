/// Represents an incomplete action waiting for user follow-up input.
class PendingConversationContext {
  const PendingConversationContext({
    required this.toolName,
    required this.arguments,
    required this.missingField,
    required this.promptQuestion,
    this.recipient,
  });

  final String toolName;
  final Map<String, dynamic> arguments;
  final String missingField; // e.g. 'message', 'phone_number', 'time'
  final String promptQuestion;
  final String? recipient;

  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        'arguments': arguments,
        'missingField': missingField,
        'promptQuestion': promptQuestion,
        if (recipient != null) 'recipient': recipient,
      };

  factory PendingConversationContext.fromJson(Map<String, dynamic> json) =>
      PendingConversationContext(
        toolName: json['toolName'] as String,
        arguments: json['arguments'] as Map<String, dynamic>? ?? {},
        missingField: json['missingField'] as String,
        promptQuestion: json['promptQuestion'] as String,
        recipient: json['recipient'] as String?,
      );
}

/// Offline rule-based intent parser and conversational memory assistant.
/// Solves:
/// 1. Offline functionality without Ollama or cloud models.
/// 2. Conversational memory retention across multi-turn exchanges.
class OfflineIntentService {
  PendingConversationContext? _pendingContext;

  PendingConversationContext? get pendingContext => _pendingContext;

  void setPendingContext(PendingConversationContext? context) {
    _pendingContext = context;
  }

  void clearPendingContext() {
    _pendingContext = null;
  }

  /// Attempts to resolve user input against a pending multi-turn conversation.
  /// If the user is answering a previous question (e.g. "What to text Jude?"),
  /// this merges the input into the pending tool action!
  Map<String, dynamic>? resolveWithContext(String userInput) {
    if (_pendingContext == null) return null;

    final trimmed = userInput.trim();
    if (trimmed.isEmpty) return null;

    // Check if user is cancelling the pending action
    final lower = trimmed.toLowerCase();
    if (lower == 'cancel' || lower == 'nevermind' || lower == 'stop' || lower == 'abort') {
      clearPendingContext();
      return {
        'thought': 'User cancelled the pending action.',
        'final_answer': 'Cancelled the previous action.',
      };
    }

    final context = _pendingContext!;
    clearPendingContext();

    final updatedArgs = Map<String, dynamic>.from(context.arguments);

    // Clean up typical spoken phrases like "tell him that...", "say that..."
    var content = trimmed;
    final cleanRegex = RegExp(
      r'^(?:tell\s+(?:him|her|them|it|jude|[a-z]+)\s+(?:that\s+)?|say\s+(?:that\s+)?|text\s+(?:that\s+)?|message\s+(?:that\s+)?)(.*)$',
      caseSensitive: false,
    );
    final match = cleanRegex.firstMatch(trimmed);
    if (match != null && match.group(1)?.trim().isNotEmpty == true) {
      content = match.group(1)!.trim();
    }

    updatedArgs[context.missingField] = content;

    return {
      'thought': 'Continuing pending action "${context.toolName}" with follow-up input.',
      'tool': context.toolName,
      'arguments': updatedArgs,
    };
  }

  static const String creatorName = 'Jude';
  static const String creatorAnswer = 'I was created by Jude.';

  /// Returns true if the user query is asking about who created or built the assistant or app.
  static bool isCreatorQuery(String rawInput) {
    final cleaned = rawInput.trim().toLowerCase().replaceAll(RegExp(r'[?!.,]'), '');
    if (cleaned.isEmpty) return false;

    // Verb pattern: "who created you", "who made it", "who built this app", "who developed you", etc.
    final verbPattern = RegExp(
      r'\bwho\s+(?:actually\s+)?(?:created|made|built|developed|programmed|designed|invented|wrote)\s+(?:you|it|this|jarvis|(?:this|the)\s+(?:app|assistant|bot|system))\b',
    );
    if (verbPattern.hasMatch(cleaned)) return true;

    // Noun pattern: "who is your creator", "who is the creator", "who's your maker", "who is your developer"
    final nounPattern = RegExp(
      r"\bwho(?:'s|\s+is|\s+was)\s+(?:your|the)\s+(?:creator|maker|developer|builder|author|programmer|founder|inventor)\b",
    );
    if (nounPattern.hasMatch(cleaned)) return true;

    // Passive pattern: "who were you created by", "who was it made by", "who was this app made by"
    final passivePattern = RegExp(
      r'\bwho\s+(?:were|was|are|is)\s+(?:you|it|this|jarvis|(?:this|the)\s+(?:app|assistant|bot|system))\s+(?:created|made|built|developed|programmed)\s+by\b',
    );
    if (passivePattern.hasMatch(cleaned)) return true;

    // Short direct variations: "your creator?", "who created you", "who created it"
    final shortPattern = RegExp(
      r'^(?:your\s+creator|creator\s+of\s+jarvis|who\s+created\s+(?:you|it)|who\s+made\s+(?:you|it))$',
    );
    if (shortPattern.hasMatch(cleaned)) return true;

    return false;
  }

  /// Parses offline commands directly using rule-based pattern matching.
  Map<String, dynamic>? parseOfflineCommand(String rawInput) {
    final input = rawInput.trim();
    if (isCreatorQuery(input)) {
      return {
        'thought': 'User is asking who created the assistant.',
        'final_answer': creatorAnswer,
      };
    }
    final lower = input.toLowerCase();

    // 1. WhatsApp messaging
    // e.g., "text jude on whatsapp", "whatsapp jude hello there", "send whatsapp message to jude"
    if (lower.contains('whatsapp')) {
      final onWaMatch = RegExp(
        r'^(?:text|message|send\s+whatsapp\s+message\s+to|send\s+message\s+to|whatsapp)\s+([a-zA-Z0-9_]+)\s+on\s+whatsapp(?:\s+(?:saying|that|to\s+say|with\s+message\s+)?|\s*:\s*)(.*)$',
        caseSensitive: false,
      ).firstMatch(input);

      if (onWaMatch != null) {
        final recipient = onWaMatch.group(1)!.trim();
        final message = onWaMatch.group(2)!.trim();
        if (message.isNotEmpty) {
          return {
            'thought': 'Detected WhatsApp message request offline.',
            'tool': 'send_whatsapp_message',
            'arguments': {'phone_number': recipient, 'message': message},
          };
        } else {
          setPendingContext(
            PendingConversationContext(
              toolName: 'send_whatsapp_message',
              arguments: {'phone_number': recipient},
              missingField: 'message',
              promptQuestion: 'What would you like me to text $recipient on WhatsApp?',
              recipient: recipient,
            ),
          );
          return {
            'thought': 'User requested WhatsApp message but did not specify content.',
            'final_answer': 'What would you like me to text $recipient on WhatsApp?',
          };
        }
      }

      final waDirectMatch = RegExp(
        r'^whatsapp\s+([a-zA-Z0-9_]+)(?:\s+(?:saying|that|to\s+say)\s+|\s*:\s*|\s+)(.*)$',
        caseSensitive: false,
      ).firstMatch(input);
      if (waDirectMatch != null) {
        final recipient = waDirectMatch.group(1)!.trim();
        final message = waDirectMatch.group(2)!.trim();
        if (message.isNotEmpty) {
          return {
            'thought': 'Detected WhatsApp message request offline.',
            'tool': 'send_whatsapp_message',
            'arguments': {'phone_number': recipient, 'message': message},
          };
        }
      }

      final simpleMatch = RegExp(
        r'^(?:text|whatsapp|message)\s+([a-zA-Z0-9_]+)(?:\s+on\s+whatsapp)?$',
        caseSensitive: false,
      ).firstMatch(input);
      if (simpleMatch != null) {
        final recipient = simpleMatch.group(1)!.trim();
        setPendingContext(
          PendingConversationContext(
            toolName: 'send_whatsapp_message',
            arguments: {'phone_number': recipient},
            missingField: 'message',
            promptQuestion: 'What would you like me to text $recipient on WhatsApp?',
            recipient: recipient,
          ),
        );
        return {
          'thought': 'User requested WhatsApp message but did not specify content.',
          'final_answer': 'What would you like me to text $recipient on WhatsApp?',
        };
      }
    }

    // 2. SMS messaging
    // e.g. "text jude I will be late", "send sms to 12345 saying hello"
    if (lower.startsWith('text ') ||
        lower.startsWith('sms ') ||
        lower.startsWith('send sms') ||
        lower.startsWith('send a text')) {
      final explicitSms = RegExp(
        r'^(?:text|sms|send\s+sms\s+to|send\s+a?\s*text\s+to)\s+([a-zA-Z0-9_]+)(?:\s+(?:saying|that|to\s+say|with\s+message)\s+|\s*:\s*)(.*)$',
        caseSensitive: false,
      ).firstMatch(input);

      if (explicitSms != null) {
        final recipient = explicitSms.group(1)!.trim();
        final message = explicitSms.group(2)!.trim();
        if (message.isNotEmpty) {
          return {
            'thought': 'Detected SMS message request offline.',
            'tool': 'send_sms',
            'arguments': {'phone_number': recipient, 'message': message},
          };
        }
      }

      final words = input.trim().split(RegExp(r'\s+'));
      if (words.length >= 2) {
        final recipient = words[1];
        if (words.length == 2) {
          setPendingContext(
            PendingConversationContext(
              toolName: 'send_sms',
              arguments: {'phone_number': recipient},
              missingField: 'message',
              promptQuestion: 'What would you like to text $recipient?',
              recipient: recipient,
            ),
          );
          return {
            'thought': 'User requested SMS without message content.',
            'final_answer': 'What would you like to text $recipient?',
          };
        } else {
          final message = words.sublist(2).join(' ');
          return {
            'thought': 'Detected SMS message request offline.',
            'tool': 'send_sms',
            'arguments': {'phone_number': recipient, 'message': message},
          };
        }
      }
    }

    // 3. Email / Gmail
    if (lower.contains('gmail') || lower.contains('email') || lower.contains('mail')) {
      if (lower == 'open gmail' || lower == 'launch gmail' || lower == 'check gmail' || lower == 'open mail') {
        return {
          'thought': 'Opening Gmail.',
          'tool': 'open_gmail',
          'arguments': <String, dynamic>{},
        };
      }
      final emailPattern = RegExp(
        r'(?:send\s+email\s+to|email)\s+([a-zA-Z0-9_.@]+)(?:\s+(?:saying|about|with\s+message)\s+|\s*:\s*|\s+)(.*)$',
        caseSensitive: false,
      );
      final emMatch = emailPattern.firstMatch(input);
      if (emMatch != null) {
        return {
          'thought': 'Sending email offline.',
          'tool': 'send_email',
          'arguments': {
            'to': emMatch.group(1)!.trim(),
            'subject': 'Message from Jarvis',
            'body': emMatch.group(2)!.trim(),
          },
        };
      }
    }

    // 4. Phone calls
    // e.g. "call jude", "dial 123456"
    final callMatch = RegExp(r'^(?:call|dial|phone)\s+([a-zA-Z0-9_\s]+)$', caseSensitive: false).firstMatch(input);
    if (callMatch != null) {
      final recipient = callMatch.group(1)!.trim();
      return {
        'thought': 'Placing call offline.',
        'tool': 'make_call',
        'arguments': {'phone_number': recipient},
      };
    }

    // 5. Alarms
    // e.g. "set alarm for 7:30", "alarm 08:00", "wake me up at 6:45"
    final alarmMatch = RegExp(r'(?:set\s+an?\s+alarm\s+(?:for|at)|alarm\s+(?:for|at)?|wake\s+me\s+up\s+at)\s+(\d{1,2}:\d{2})(?:\s+(?:am|pm))?', caseSensitive: false).firstMatch(input);
    if (alarmMatch != null) {
      final time = alarmMatch.group(1)!;
      return {
        'thought': 'Setting alarm offline.',
        'tool': 'set_alarm',
        'arguments': {'time': time, 'label': 'Jarvis Alarm'},
      };
    }

    // 6. Timers
    // e.g. "set a timer for 5 minutes", "timer 30 seconds"
    final timerMatch = RegExp(r'(?:set\s+a?\s*timer\s+(?:for\s+)?|timer\s+(?:for\s+)?)(\d+)\s*(minute|second|min|sec)s?', caseSensitive: false).firstMatch(input);
    if (timerMatch != null) {
      final count = int.tryParse(timerMatch.group(1)!) ?? 60;
      final unit = timerMatch.group(2)!.toLowerCase();
      final seconds = unit.startsWith('min') ? count * 60 : count;
      return {
        'thought': 'Setting countdown timer offline.',
        'tool': 'set_timer',
        'arguments': {'seconds': seconds, 'label': 'Jarvis timer'},
      };
    }

    // 7. Media controls & music playback
    if (lower.startsWith('play ') && lower != 'play' && lower != 'play music') {
      var songQuery = input.substring(5).trim();
      var onYouTube = false;
      final ytRegex = RegExp(r'\s+on\s+youtube\b', caseSensitive: false);
      if (ytRegex.hasMatch(songQuery)) {
        onYouTube = true;
        songQuery = songQuery.replaceAll(ytRegex, '').trim();
      }
      return {
        'thought': onYouTube
            ? 'Playing music on YouTube.'
            : 'Playing music via Android MEDIA_PLAY_FROM_SEARCH default player.',
        'tool': 'play_music',
        'arguments': {
          'query': songQuery,
          'on_youtube': onYouTube,
        },
      };
    }
    if (lower == 'play' || lower == 'play music' || lower == 'resume') {
      return {
        'thought': 'Playing media.',
        'tool': 'phone_control',
        'arguments': {'action': 'play_media'},
      };
    }
    if (lower == 'pause' || lower == 'pause music' || lower == 'stop music') {
      return {
        'thought': 'Pausing media.',
        'tool': 'phone_control',
        'arguments': {'action': 'pause_media'},
      };
    }
    if (lower == 'next track' || lower == 'next song' || lower == 'skip') {
      return {
        'thought': 'Skipping to next track.',
        'tool': 'phone_control',
        'arguments': {'action': 'next_track'},
      };
    }
    if (lower == 'previous track' || lower == 'previous song') {
      return {
        'thought': 'Going to previous track.',
        'tool': 'phone_control',
        'arguments': {'action': 'previous_track'},
      };
    }
    if (lower == 'volume up' || lower == 'increase volume' || lower == 'louder') {
      return {
        'thought': 'Raising volume.',
        'tool': 'phone_control',
        'arguments': {'action': 'volume_up'},
      };
    }
    if (lower == 'volume down' || lower == 'decrease volume' || lower == 'softer') {
      return {
        'thought': 'Lowering volume.',
        'tool': 'phone_control',
        'arguments': {'action': 'volume_down'},
      };
    }
    if (lower == 'mute' || lower == 'unmute') {
      return {
        'thought': 'Toggling mute.',
        'tool': 'phone_control',
        'arguments': {'action': 'mute'},
      };
    }

    // 8. Flashlight
    if (lower.contains('flashlight on') || lower.contains('torch on') || lower.contains('turn on flashlight')) {
      return {
        'thought': 'Turning on flashlight.',
        'tool': 'phone_control',
        'arguments': {'action': 'flashlight_on'},
      };
    }
    if (lower.contains('flashlight off') || lower.contains('torch off') || lower.contains('turn off flashlight')) {
      return {
        'thought': 'Turning off flashlight.',
        'tool': 'phone_control',
        'arguments': {'action': 'flashlight_off'},
      };
    }

    // 9. Battery
    if (lower.contains('battery') || lower.contains('power status')) {
      return {
        'thought': 'Checking battery level.',
        'tool': 'phone_control',
        'arguments': {'action': 'battery_level'},
      };
    }

    // 10. Open/Launch Apps
    final openAppMatch = RegExp(r'^(?:open|launch|start)\s+([a-zA-Z0-9_\s]+)$', caseSensitive: false).firstMatch(input);
    if (openAppMatch != null) {
      final appName = openAppMatch.group(1)!.trim();
      return {
        'thought': 'Opening requested app offline.',
        'tool': 'launch_app',
        'arguments': {'package_name': appName},
      };
    }

    // 11. Notes
    final saveNoteMatch = RegExp(r'^(?:save\s+note|take\s+note|note\s+down|write\s+note)\s+(.*)$', caseSensitive: false).firstMatch(input);
    if (saveNoteMatch != null) {
      final noteText = saveNoteMatch.group(1)!.trim();
      return {
        'thought': 'Saving note offline.',
        'tool': 'save_note',
        'arguments': {'text': noteText},
      };
    }
    if (lower == 'show notes' || lower == 'get notes' || lower == 'read notes') {
      return {
        'thought': 'Reading notes offline.',
        'tool': 'get_notes',
        'arguments': <String, dynamic>{},
      };
    }

    // 12. Read Notifications
    if (lower.contains('read notifications') || lower.contains('check notifications')) {
      return {
        'thought': 'Reading notifications offline.',
        'tool': 'read_notifications',
        'arguments': <String, dynamic>{},
      };
    }

    return null;
  }
}

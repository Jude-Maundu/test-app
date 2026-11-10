import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/app_skill.dart';
import 'package:test_app/skills/call_skill.dart';
import 'package:test_app/skills/command_router.dart';
import 'package:test_app/skills/creator_skill.dart';
import 'package:test_app/skills/music_skill.dart';
import 'package:test_app/skills/reminder_skill.dart';
import 'package:test_app/skills/skill_base.dart';
import 'package:test_app/skills/time_skill.dart';
import 'package:test_app/skills/weather_skill.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> methodCalls = [];

  setUp(() {
    PlatformService.mockIsLinux = false;
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.assistant.app/platform'),
      (MethodCall call) async {
        methodCalls.add(call);
        final args = call.arguments is Map ? call.arguments as Map : {};
        switch (call.method) {
          case 'playMediaFromSearch':
            final query = args['query'] as String? ?? '';
            final isYouTube = args['isYouTube'] as bool? ?? false;
            if (query == 'nonexistent_music_player_trigger') {
              return 'NO_MUSIC_APP: No music player application was found.';
            }
            if (isYouTube) {
              return 'Playing "$query" on YouTube, sir.';
            }
            return 'Playing "$query" on your default music player, sir.';
          case 'mediaControl':
            final action = args['action'] as String? ?? '';
            return 'Sent $action command, sir.';
          case 'launchApp':
            return 'Launched app';
          case 'makeCall':
            return 'Placed call';
          case 'setAlarm':
            return 'Alarm set';
          case 'deviceAction':
            return 'Device action executed';
          default:
            return 'Done';
        }
      },
    );
  });

  tearDown(() {
    PlatformService.mockIsLinux = null;
  });

  group('1. Wake Word & Personality', () {
    test('Recognizes "Jarvis", "Hey Jarvis", "OK Jarvis" wake words', () {
      final p1 = CommandRouter.parseWakeWord('Jarvis, play Queen');
      expect(p1.hadWakeWord, isTrue);
      expect(p1.command, 'play Queen');
      expect(p1.isWakeWordOnly, isFalse);

      final p2 = CommandRouter.parseWakeWord('Hey Jarvis what time is it');
      expect(p2.hadWakeWord, isTrue);
      expect(p2.command, 'what time is it');
      expect(p2.isWakeWordOnly, isFalse);

      final p3 = CommandRouter.parseWakeWord('Jarvis');
      expect(p3.hadWakeWord, isTrue);
      expect(p3.command, isEmpty);
      expect(p3.isWakeWordOnly, isTrue);
    });

    test('Replies politely when called with only the wake word', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route('Jarvis');
      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('At your service, sir'));
    });

    test('Addresses the user by their preferred name or title', () async {
      final router = CommandRouter(context: SkillContext(userName: 'boss'));
      final res = await router.route('Hey Jarvis');
      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('boss'));
    });
  });

  group('2. Music Control via Android Intent & YouTube Targeting', () {
    test('Uses Android default player intent (MEDIA_PLAY_FROM_SEARCH) without YouTube by default', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route('Jarvis, play Bohemian Rhapsody');

      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('Playing "Bohemian Rhapsody", sir.'));

      // Verify MethodChannel invocation
      final playCall = methodCalls.firstWhere((c) => c.method == 'playMediaFromSearch');
      expect(playCall.arguments['query'], 'Bohemian Rhapsody');
      expect(playCall.arguments['isYouTube'], isFalse); // STRICTLY false by default!
    });

    test('Only routes to YouTube if explicitly requested with "on YouTube"', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route('play Queen on YouTube');

      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('on YouTube'));

      final playCall = methodCalls.firstWhere((c) => c.method == 'playMediaFromSearch');
      expect(playCall.arguments['query'], 'Queen');
      expect(playCall.arguments['isYouTube'], isTrue);
    });

    test('Supports playback controls: pause, resume, next, previous, volume up, volume down', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));

      // Pause
      methodCalls.clear();
      var res = await router.route('pause music');
      expect(res.speechResponse, contains('Paused, sir.'));
      expect(methodCalls.any((c) => c.method == 'mediaControl' && c.arguments['action'] == 'pause'), isTrue);

      // Resume
      methodCalls.clear();
      res = await router.route('resume');
      expect(res.speechResponse, contains('Resuming playback, sir.'));
      expect(methodCalls.any((c) => c.method == 'mediaControl' && c.arguments['action'] == 'resume'), isTrue);

      // Next
      methodCalls.clear();
      res = await router.route('next track');
      expect(res.speechResponse, contains('Skipping to the next track, sir.'));
      expect(methodCalls.any((c) => c.method == 'mediaControl' && c.arguments['action'] == 'next'), isTrue);

      // Previous
      methodCalls.clear();
      res = await router.route('previous song');
      expect(res.speechResponse, contains('Returning to the previous track, sir.'));
      expect(methodCalls.any((c) => c.method == 'mediaControl' && c.arguments['action'] == 'previous'), isTrue);

      // Volume Up
      methodCalls.clear();
      res = await router.route('volume up');
      expect(res.speechResponse, contains('Volume increased, sir.'));
      expect(methodCalls.any((c) => c.method == 'mediaControl' && c.arguments['action'] == 'volume_up'), isTrue);

      // Volume Down
      methodCalls.clear();
      res = await router.route('volume down');
      expect(res.speechResponse, contains('Volume decreased, sir.'));
      expect(methodCalls.any((c) => c.method == 'mediaControl' && c.arguments['action'] == 'volume_down'), isTrue);
    });

    test('Speaks out loud and asks what to do if no music app can handle the request', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route('play nonexistent_music_player_trigger');

      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('couldn\'t find a music player installed'));
      expect(res.speechResponse, contains('play it on YouTube instead?'));
      expect(router.context.recall(MusicSkill.keyPendingAction), 'ask_youtube');

      // User replies "yes" to follow-up question
      methodCalls.clear();
      final followUp = await router.route('yes please');
      expect(followUp.speechResponse, contains('Playing "nonexistent_music_player_trigger" on YouTube, sir.'));
      final ytCall = methodCalls.firstWhere((c) => c.method == 'playMediaFromSearch');
      expect(ytCall.arguments['isYouTube'], isTrue);
    });
  });

  group('3. Conversational Short-Term Memory', () {
    test('"play it again" replays the previously requested song', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));

      // Turn 1: Play song
      await router.route('play Hotel California');
      expect(router.context.recall(MusicSkill.keyLastPlayedQuery), 'Hotel California');

      // Turn 2: "play it again"
      methodCalls.clear();
      final replayRes = await router.route('Jarvis, play it again');
      expect(replayRes.speechResponse, contains('Replaying "Hotel California", sir.'));
      final replayCall = methodCalls.firstWhere((c) => c.method == 'playMediaFromSearch');
      expect(replayCall.arguments['query'], 'Hotel California');
    });

    test('"play something similar" seeds from the previous artist or track', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));

      // Turn 1: Play song by artist
      await router.route('play Yesterday by The Beatles');
      expect(router.context.recall(MusicSkill.keyLastPlayedArtist), 'The Beatles');

      // Turn 2: "play something similar"
      methodCalls.clear();
      final similarRes = await router.route('play something similar');
      expect(similarRes.speechResponse, contains('Playing music similar to The Beatles, sir.'));
      final call = methodCalls.firstWhere((c) => c.method == 'playMediaFromSearch');
      expect(call.arguments['query'], contains('The Beatles'));
    });
  });

  group('4. Command Router Architecture & Modular Skills', () {
    test('Router holds skills in a modular dictionary', () {
      final router = CommandRouter();
      expect(router.skills.containsKey('music'), isTrue);
      expect(router.skills.containsKey('time'), isTrue);
      expect(router.skills.containsKey('weather'), isTrue);
      expect(router.skills.containsKey('open_apps'), isTrue);
      expect(router.skills.containsKey('calls'), isTrue);
      expect(router.skills.containsKey('reminders'), isTrue);
      expect(router.skills.containsKey('creator'), isTrue);
    });

    test('Routes time queries to TimeSkill', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route('what time is it');
      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('The time is'));
    });

    test('Routes app queries to AppSkill', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route('open Spotify');
      expect(res.handled, isTrue);
      expect(res.speechResponse, 'Opening Spotify, sir.');
      expect(methodCalls.any((c) => c.method == 'launchApp' && c.arguments['packageName'] == 'Spotify'), isTrue);
    });

    test('Routes alarm queries to ReminderSkill', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route('set alarm for 07:30 am');
      expect(res.handled, isTrue);
      expect(res.speechResponse, 'Alarm set for 07:30 AM, sir.');
    });

    test('Routes creator queries to CreatorSkill', () async {
      final router = CommandRouter();
      final res = await router.route('who created you?');
      expect(res.handled, isTrue);
      expect(res.speechResponse, 'I was created by Jude.');
    });

    test('Falls back to LLM for unmatched commands', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      final res = await router.route(
        'Explain quantum computing in one sentence',
        customLlmFallback: (instruction) async {
          return 'Quantum computing uses quantum mechanics to solve complex problems exponentially faster, sir.';
        },
      );
      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('Quantum computing'));
    });
  });
}

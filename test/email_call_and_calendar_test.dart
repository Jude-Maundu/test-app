import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test_app/services/calendar_service.dart';
import 'package:test_app/services/gmail_service.dart';
import 'package:test_app/services/google_oauth_service.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/calendar_skill.dart';
import 'package:test_app/skills/call_skill.dart';
import 'package:test_app/skills/command_router.dart';
import 'package:test_app/skills/email_skill.dart';
import 'package:test_app/skills/skill_base.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> platformCalls = [];
  late GoogleOAuthService oauthService;
  late GmailService gmailService;
  late GoogleCalendarService calendarService;

  setUp(() async {
    platformCalls.clear();
    PlatformService.mockIsLinux = false;
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});

    // Mock HTTP for Google APIs
    final mockHttp = MockClient((request) async {
      // Token refresh
      if (request.url.host == 'oauth2.googleapis.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'mock-access-token-12345',
            'expires_in': 3600,
          }),
          200,
        );
      }
      // Gmail send
      if (request.url.path.contains('/messages/send')) {
        return http.Response(
          jsonEncode({'id': 'msg-101', 'threadId': 'th-101'}),
          200,
        );
      }
      // Gmail list
      if (request.url.path.endsWith('/messages')) {
        return http.Response(
          jsonEncode({
            'messages': [
              {'id': 'msg-101'},
            ],
          }),
          200,
        );
      }
      // Gmail message detail
      if (request.url.path.contains('/messages/msg-101')) {
        return http.Response(
          jsonEncode({
            'snippet': 'Project status update for Friday.',
            'payload': {
              'headers': [
                {'name': 'From', 'value': 'Pepper Potts <pepper@stark.com>'},
                {'name': 'Subject', 'value': 'Quarterly Briefing'},
                {'name': 'Date', 'value': 'Mon, 27 Oct 2026 10:00:00 GMT'},
              ],
            },
          }),
          200,
        );
      }
      // Calendar list
      if (request.url.path.contains('/calendars/primary/events') && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'ev-1',
                'summary': 'Board Meeting',
                'location': 'Stark Tower Lab',
                'start': {'dateTime': '2026-10-27T09:00:00Z'},
                'end': {'dateTime': '2026-10-27T10:00:00Z'},
              },
              {
                'id': 'ev-2',
                'summary': 'Armor Diagnostics',
                'location': 'Hangar 4',
                'start': {'dateTime': '2026-10-27T14:00:00Z'},
                'end': {'dateTime': '2026-10-27T15:00:00Z'},
              },
            ],
          }),
          200,
        );
      }
      // Calendar create
      if (request.url.path.contains('/calendars/primary/events') && request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'id': 'ev-created',
            'summary': 'New Event',
            'htmlLink': 'https://calendar.google.com/event?id=ev-created',
          }),
          201,
        );
      }
      return http.Response('Not found', 404);
    });

    oauthService = GoogleOAuthService(httpClient: mockHttp);
    await oauthService.storeCredentials(
      clientId: 'client-id-123',
      refreshToken: 'refresh-token-xyz',
      accessToken: 'initial-access-token',
      expiresInSeconds: 3600,
    );

    gmailService = GmailService(oauthService: oauthService, httpClient: mockHttp);
    calendarService = GoogleCalendarService(oauthService: oauthService, httpClient: mockHttp);

    // Mock platform channel for contacts & phone calls
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.assistant.app/platform'),
      (MethodCall call) async {
        platformCalls.add(call);
        final args = call.arguments is Map ? call.arguments as Map : {};
        switch (call.method) {
          case 'makeCall':
            return 'Calling ${args['phoneNumber']}, sir.';
          case 'findContacts':
            final name = (args['name'] as String? ?? '').toLowerCase();
            if (name.contains('tony')) {
              return [
                {'name': 'Tony Stark', 'phoneNumber': '+1-212-555-0100'},
              ];
            } else if (name.contains('dave')) {
              return [
                {'name': 'Dave Miller', 'phoneNumber': '111-222-3333'},
                {'name': 'Dave Wilson', 'phoneNumber': '444-555-6666'},
              ];
            }
            return <Map<String, String>>[];
          case 'findContactEmails':
            final name = (args['name'] as String? ?? '').toLowerCase();
            if (name.contains('pepper')) {
              return [
                {'name': 'Pepper Potts', 'email': 'pepper@stark.com'},
              ];
            } else if (name.contains('bruce')) {
              return [
                {'name': 'Bruce Wayne (Work)', 'email': 'bruce@waynecorp.com'},
                {'name': 'Bruce Wayne (Personal)', 'email': 'bruce@batcave.org'},
              ];
            }
            return <Map<String, String>>[];
          default:
            return 'Done';
        }
      },
    );
  });

  tearDown(() {
    PlatformService.mockIsLinux = null;
  });

  group('5. Email (Gmail) with OAuth 2.0 & Contacts Lookup', () {
    test('Drafts email, looks up contact, reads draft back, and asks confirmation', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(EmailSkill(gmailService: gmailService));

      final res = await router.route('send an email to Pepper about Project Mark VII');
      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('I have prepared the email for Pepper Potts'));
      expect(res.speechResponse, contains('Shall I send it, sir?'));
      expect(router.context.recall(EmailSkill.keyPendingDraft), isNotNull);
    });

    test('Allows changing tone or adding content before confirmation', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(EmailSkill(gmailService: gmailService));

      // 1. Initial draft
      await router.route('send an email to Pepper about Meeting Tomorrow');

      // 2. Change tone
      final toneRes = await router.route('change the tone to formal');
      expect(toneRes.speechResponse, contains('formal correspondence'));
      expect(toneRes.speechResponse, contains('Shall I send it now, sir?'));

      // 3. Add content
      final addRes = await router.route('add that I will bring the prototypes');
      expect(addRes.speechResponse, contains('Additionally, I will bring the prototypes'));
      expect(addRes.speechResponse, contains('Shall I send it now, sir?'));

      // 4. Final confirmation
      final sendRes = await router.route('yes send it');
      expect(sendRes.speechResponse, contains('The email has been sent to pepper@stark.com, sir.'));
      expect(router.context.recall(EmailSkill.keyPendingDraft), isNull);
    });

    test('Asks user when multiple email addresses exist for contact', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(EmailSkill(gmailService: gmailService));

      final res = await router.route('send an email to Bruce about Gotham Tech Summit');
      expect(res.speechResponse, contains('multiple email addresses for Bruce'));
      expect(res.speechResponse, contains('bruce@waynecorp.com'));
      expect(res.speechResponse, contains('bruce@batcave.org'));
      expect(res.speechResponse, contains('Which one shall I use, sir?'));

      // User selects one
      final pickRes = await router.route('use bruce@batcave.org');
      expect(pickRes.speechResponse, contains('I have prepared the email'));
      expect(pickRes.speechResponse, contains('Shall I send it, sir?'));
    });

    test('Reads recent emails when asked', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(EmailSkill(gmailService: gmailService));

      final res = await router.route('check my email');
      expect(res.speechResponse, contains('recent messages'));
      expect(res.speechResponse, contains('Quarterly Briefing'));
      expect(res.speechResponse, contains('Pepper Potts'));
    });
  });

  group('6. Phone Calls with Direct ACTION_CALL & Contact Disambiguation', () {
    test('Places direct call with ACTION_CALL when single contact matches', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(CallSkill());

      final res = await router.route('call Tony');
      expect(res.handled, isTrue);
      expect(res.speechResponse, 'Calling Tony Stark at +1-212-555-0100 now, sir.');

      // Verify MethodChannel invocation
      final call = platformCalls.firstWhere((c) => c.method == 'makeCall');
      expect(call.arguments['phoneNumber'], '+1-212-555-0100');
    });

    test('Asks for clarification when several contacts match', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(CallSkill());

      final res = await router.route('call Dave');
      expect(res.speechResponse, contains('several contacts matching Dave'));
      expect(res.speechResponse, contains('Dave Miller'));
      expect(res.speechResponse, contains('Dave Wilson'));
      expect(res.speechResponse, contains('Which one should I call, sir?'));

      // User picks one
      platformCalls.clear();
      final pickRes = await router.route('Dave Wilson');
      expect(pickRes.speechResponse, contains('Calling Dave Wilson at 444-555-6666 now, sir.'));
      final call = platformCalls.firstWhere((c) => c.method == 'makeCall');
      expect(call.arguments['phoneNumber'], '444-555-6666');
    });

    test('Asks for number when contact is not found', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(CallSkill());

      final res = await router.route('call Natasha');
      expect(res.speechResponse, contains('couldn\'t find Natasha in your contacts'));
      expect(res.speechResponse, contains('What number would you like me to dial?'));
    });
  });

  group('7. Google Calendar and Schedule with Gap Detection', () {
    test('Summarizes daily schedule including times, locations, and gaps', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(CalendarSkill(calendarService: calendarService));

      final res = await router.route('what\'s my schedule today');
      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('Board Meeting'));
      expect(res.speechResponse, contains('Stark Tower Lab'));
      expect(res.speechResponse, contains('Armor Diagnostics'));
      expect(res.speechResponse, contains('Hangar 4'));
      // Verifies natural gap calculation
      expect(res.speechResponse, contains('free window of 4 hours'));
    });

    test('Prepares calendar event and confirms before adding', () async {
      final router = CommandRouter(context: SkillContext(userName: 'sir'));
      router.registerSkill(CalendarSkill(calendarService: calendarService));

      final res = await router.route('add Flight Test to my calendar at 4pm');
      expect(res.handled, isTrue);
      expect(res.speechResponse, contains('I have prepared the event "Flight Test" for 4 PM. Shall I add it to your calendar, sir?'));
      expect(router.context.recall(CalendarSkill.keyPendingEvent), isNotNull);

      // Confirm
      final confirmRes = await router.route('yes add it');
      expect(confirmRes.speechResponse, contains('I have added "Flight Test" to your calendar, sir.'));
      expect(router.context.recall(CalendarSkill.keyPendingEvent), isNull);
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/services/llm_service.dart';
import 'package:test_app/services/offline_intent_service.dart';
import 'package:test_app/services/permission_manager.dart';
import 'package:test_app/services/task_execution_service.dart';
import 'package:test_app/services/task_orchestrator.dart';
import 'package:test_app/services/tool_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterSecureStoragePlatform testStorage;
  late PermissionManager permissionManager;
  late OfflineIntentService offlineIntentService;
  late AssistantProvider assistantProvider;
  late TaskExecutionService taskExecutionService;

  setUp(() {
    testStorage = TestFlutterSecureStoragePlatform({});
    FlutterSecureStoragePlatform.instance = testStorage;
    permissionManager = PermissionManager();
    offlineIntentService = OfflineIntentService();
    assistantProvider = AssistantProvider();
    taskExecutionService = TaskExecutionService();
  });

  group('1. Persistent Permissions ("Grant once, always go ahead")', () {
    test('Stores and remembers tool authorization after initial approval', () async {
      expect(await permissionManager.isToolAuthorized('send_sms'), isFalse);
      expect(await permissionManager.isToolAuthorized('send_whatsapp_message'), isFalse);

      await permissionManager.grantToolAuthorization('send_sms');
      expect(await permissionManager.isToolAuthorized('send_sms'), isTrue);
      expect(await permissionManager.isToolAuthorized('send_whatsapp_message'), isFalse);

      final tools = await permissionManager.getAuthorizedTools();
      expect(tools, contains('send_sms'));

      await permissionManager.revokeToolAuthorization('send_sms');
      expect(await permissionManager.isToolAuthorized('send_sms'), isFalse);
    });

    test('Bypasses authorization dialog once permission is persistently granted', () async {
      // Pre-grant send_sms in permission manager
      await permissionManager.grantToolAuthorization('send_sms');

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': 'Sending SMS',
                  'tool_calls': [
                    {
                      'function': {
                        'name': 'send_sms',
                        'arguments': '{"phone_number":"1234567890","message":"I am on my way"}',
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final llm = LLMService(client: mockClient);
      await llm.setProvider(LLMProvider.openAi);
      await llm.setProviderApiKey(LLMProvider.openAi, 'key-123');

      final orchestrator = TaskOrchestrator(
        llmService: llm,
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
        permissionManager: permissionManager,
      );

      // Execute instruction - since send_sms is already authorized, it shouldn't pause for authorization
      final task = await orchestrator.executeInstruction('Text 1234567890 I am on my way');

      expect(task.status, TaskStatus.completed);
      expect(orchestrator.status, isNot(TaskStatus.waitingForAuthorization));
      expect(task.steps.any((s) => s.tool == 'send_sms'), isTrue);
    });
  });

  group('2. Gmail & Email Integration', () {
    test('SendEmailTool validates arguments and prepares email', () async {
      final tool = SendEmailTool();
      expect(tool.name, 'send_email');
      expect(tool.risk, ToolRisk.sensitive);

      expect(tool.validate({}), isNotNull);
      expect(tool.validate({'to': 'test@gmail.com'}), isNotNull);
      expect(tool.validate({'to': 'test@gmail.com', 'body': 'Hello world'}), isNull);

      final executionContext = ToolExecutionContext(
        llmService: LLMService(),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final result = await tool.execute(executionContext, {
        'to': 'jude@example.com',
        'subject': 'Meeting time',
        'body': 'See you at 3 PM',
      });

      expect(result.success, isTrue);
      expect(result.output, contains('jude@example.com'));
    });

    test('OpenGmailTool opens Gmail search or inbox', () async {
      final tool = OpenGmailTool();
      expect(tool.name, 'open_gmail');
      expect(tool.risk, ToolRisk.low);

      final executionContext = ToolExecutionContext(
        llmService: LLMService(),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final result = await tool.execute(executionContext, {'query': 'flight'});
      expect(result.success, isTrue);
      expect(result.output, contains('Gmail'));
    });
  });

  group('3. Conversational Memory & Multi-turn Context Retention', () {
    test('Detects missing follow-up content and resolves with next user answer', () {
      // Step A: User says "Text Jude on WhatsApp" without message content
      final stepA = offlineIntentService.parseOfflineCommand('Text Jude on WhatsApp');
      expect(stepA, isNotNull);
      expect(stepA!['final_answer'], contains('What would you like me to text Jude on WhatsApp?'));
      expect(offlineIntentService.pendingContext, isNotNull);
      expect(offlineIntentService.pendingContext!.recipient, 'Jude');
      expect(offlineIntentService.pendingContext!.toolName, 'send_whatsapp_message');

      // Step B: User responds with what to text: "Tell him I am 5 minutes away"
      final stepB = offlineIntentService.resolveWithContext('Tell him I am 5 minutes away');
      expect(stepB, isNotNull);
      expect(stepB!['tool'], 'send_whatsapp_message');
      expect(stepB['arguments']['phone_number'], 'Jude');
      expect(stepB['arguments']['message'], 'I am 5 minutes away');
      expect(offlineIntentService.pendingContext, isNull); // cleared after resolution
    });

    test('Allows user to cancel a pending conversation context', () {
      offlineIntentService.parseOfflineCommand('Text Alex on WhatsApp');
      expect(offlineIntentService.pendingContext, isNotNull);

      final cancelled = offlineIntentService.resolveWithContext('Cancel');
      expect(cancelled, isNotNull);
      expect(cancelled!['final_answer'], contains('Cancelled'));
      expect(offlineIntentService.pendingContext, isNull);
    });
  });

  group('4. Offline Execution & Ollama Local Robustness', () {
    test('Parses and formats offline alarm, timer, media and note commands', () {
      // Alarm
      final alarm = offlineIntentService.parseOfflineCommand('Set alarm for 07:30');
      expect(alarm, isNotNull);
      expect(alarm!['tool'], 'set_alarm');
      expect(alarm['arguments']['time'], '07:30');

      // Timer
      final timer = offlineIntentService.parseOfflineCommand('Set a timer for 15 minutes');
      expect(timer, isNotNull);
      expect(timer!['tool'], 'set_timer');
      expect(timer['arguments']['seconds'], 900);

      // Media
      final play = offlineIntentService.parseOfflineCommand('play music');
      expect(play!['tool'], 'phone_control');
      expect(play['arguments']['action'], 'play_media');

      // Save Note
      final note = offlineIntentService.parseOfflineCommand('Save note Buy coffee and oat milk');
      expect(note!['tool'], 'save_note');
      expect(note['arguments']['text'], 'Buy coffee and oat milk');

      // App Launch
      final app = offlineIntentService.parseOfflineCommand('Open Spotify');
      expect(app!['tool'], 'launch_app');
      expect(app['arguments']['package_name'], 'Spotify');
    });

    test('Ollama model resolution finds tag alias when available', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/api/tags')) {
          return http.Response(
            jsonEncode({
              'models': [
                {'name': 'llama3.2:latest'},
                {'name': 'qwen3.5:4b'},
              ],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final llm = LLMService(client: mockClient);
      final model = await llm.getOllamaModel();
      expect(model, contains('llama3.2'));
    });
  });

  group('5. Media Processing & System Notifications', () {
    test('SendNotificationTool posts system notification', () async {
      final tool = SendNotificationTool();
      expect(tool.name, 'send_notification');

      final executionContext = ToolExecutionContext(
        llmService: LLMService(),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final res = await tool.execute(executionContext, {
        'title': 'Task Finished',
        'message': 'WhatsApp message sent to Jude',
      });

      expect(res.success, isTrue);
      expect(res.output, contains('Task Finished'));
    });

    test('ProcessMediaTool validates file path requirement', () async {
      final tool = ProcessMediaTool();
      expect(tool.name, 'process_media');
      expect(tool.validate({}), isNotNull);
      expect(tool.validate({'file_path': '/path/to/img.png'}), isNull);
    });

    test('LLMService processes media with local mock file', () async {
      final tempFile = File('${Directory.systemTemp.path}/test_image.png');
      tempFile.writeAsBytesSync([1, 2, 3, 4, 5]);

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/api/chat')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['messages'], isNotEmpty);
          final userMsg = (body['messages'] as List).first as Map<String, dynamic>;
          expect(userMsg['images'], isNotEmpty); // image base64 verified
          return http.Response(
            jsonEncode({
              'message': {
                'role': 'assistant',
                'content': 'The image shows a sunny landscape with mountains.',
              },
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/api/tags')) {
          return http.Response(
            jsonEncode({
              'models': [
                {'name': 'qwen3.5:4b'},
              ],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final llm = LLMService(client: mockClient);
      await llm.setProvider(LLMProvider.ollama);

      final result = await llm.processMedia(
        prompt: 'What is in this picture?',
        mediaPath: tempFile.path,
      );

      expect(result, contains('sunny landscape'));

      if (tempFile.existsSync()) tempFile.deleteSync();
    });
  });

  group('6. Customization & First-Time Onboarding State', () {
    test('Tracks onboarding completion and default app preferences', () async {
      expect(await permissionManager.hasCompletedOnboarding(), isFalse);

      await permissionManager.setDefaultMusicApp('spotify');
      await permissionManager.setDefaultEmailApp('gmail');
      await permissionManager.setDefaultClockApp('google_clock');
      await permissionManager.setDefaultCalendarApp('google_calendar');
      await permissionManager.setCompletedOnboarding(true);

      expect(await permissionManager.hasCompletedOnboarding(), isTrue);
      expect(await permissionManager.getDefaultMusicApp(), 'spotify');
      expect(await permissionManager.getDefaultEmailApp(), 'gmail');
      expect(await permissionManager.getDefaultClockApp(), 'google_clock');
      expect(await permissionManager.getDefaultCalendarApp(), 'google_calendar');
    });
  });

  group('7. Creator Identity ("Always Jude")', () {
    test('Identifies creator queries across various phrasings', () {
      expect(OfflineIntentService.isCreatorQuery('who created you'), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who created it'), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who created it?'), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who made you'), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who is your creator'), isTrue);
      expect(OfflineIntentService.isCreatorQuery("who's your maker"), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who developed this app'), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who is your developer'), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who built you'), isTrue);
      expect(OfflineIntentService.isCreatorQuery('who were you created by'), isTrue);

      // Negative checks
      expect(OfflineIntentService.isCreatorQuery('who is jude'), isFalse);
      expect(OfflineIntentService.isCreatorQuery('who created google'), isFalse);
      expect(OfflineIntentService.isCreatorQuery('create a note'), isFalse);
    });

    test('Answers that Jude created it via OfflineIntentService', () {
      final res = offlineIntentService.parseOfflineCommand('who created it?');
      expect(res, isNotNull);
      expect(res!['final_answer'], 'I was created by Jude.');
    });

    test('Answers that Jude created it via LLMService.processCommand', () async {
      final llm = LLMService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      final result = await llm.processCommand('who created you?');
      expect(result['response'], 'I was created by Jude.');
    });

    test('Answers that Jude created it via TaskOrchestrator.executeInstruction', () async {
      final llm = LLMService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      final orchestrator = TaskOrchestrator(
        llmService: llm,
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
        permissionManager: permissionManager,
      );
      final task = await orchestrator.executeInstruction('who created it');
      expect(task.status, TaskStatus.completed);
      expect(task.result, 'I was created by Jude.');
    });
  });
}

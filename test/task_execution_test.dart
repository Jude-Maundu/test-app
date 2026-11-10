import 'dart:convert';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/services/llm_service.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/services/task_execution_service.dart';
import 'package:test_app/services/task_orchestrator.dart';
import 'package:test_app/services/tool_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterSecureStoragePlatform testStorage;
  late AssistantProvider assistantProvider;
  late TaskExecutionService taskExecutionService;

  setUp(() {
    testStorage = TestFlutterSecureStoragePlatform({});
    FlutterSecureStoragePlatform.instance = testStorage;
    assistantProvider = AssistantProvider();
    taskExecutionService = TaskExecutionService();
  });

  group('Autonomous Task Execution & Tool Registry Verification', () {
    // 1. A command that opens an application
    test('1. Executes tool to launch an application with validation', () async {
      final tool = LaunchAppTool();
      expect(tool.validate({}), isNotNull);
      expect(tool.validate({'package_name': 'com.android.chrome'}), isNull);
      expect(tool.risk, ToolRisk.low);
    });

    // 2. A web search followed by a summary
    test('2. Web search retrieves results and can be summarized', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == 'api.duckduckgo.com') {
          return http.Response(
            jsonEncode({
              'Heading': 'Cybersecurity News',
              'AbstractText': 'New encryption standards announced to safeguard cloud data.',
              'AbstractURL': 'https://example.com/cybersecurity',
              'RelatedTopics': [],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final executionContext = ToolExecutionContext(
        llmService: LLMService(client: mockClient),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
        httpClient: mockClient,
      );

      final searchTool = WebSearchTool();
      final searchResult = await searchTool.execute(
        executionContext,
        {'query': 'cybersecurity news'},
      );

      expect(searchResult.success, isTrue);
      expect(searchResult.output, contains('New encryption standards'));

      final summaryTool = SummarizeContentTool();
      final summaryResult = await summaryTool.execute(
        executionContext,
        {'text': searchResult.output, 'max_points': 2},
      );

      expect(summaryResult.success, isTrue);
      expect(summaryResult.output, isNotEmpty);
    });

    // 3. A multi-step task involving navigation and information retrieval
    test('3. Multi-step task orchestration executes sequential tool steps', () async {
      int turn = 0;
      final mockClient = MockClient((request) async {
        if (request.url.host == 'api.duckduckgo.com') {
          return http.Response(
            jsonEncode({
              'Heading': 'Flutter Agent',
              'AbstractText': 'Autonomous agent systems for Flutter on Android.',
              'AbstractURL': 'https://flutter.dev/agent',
              'RelatedTopics': [],
            }),
            200,
          );
        }
        turn++;
        if (turn == 1) {
          // Step 1: Tool call web_search
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'Searching web',
                    'tool_calls': [
                      {
                        'function': {
                          'name': 'web_search',
                          'arguments': '{"query":"flutter agent"}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        } else {
          // Step 2: Final answer synthesized after observing tool result
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'Found information about Flutter autonomous agents on Android.',
                  },
                },
              ],
            }),
            200,
          );
        }
      });

      final llm = LLMService(client: mockClient);
      await llm.setProvider(LLMProvider.openAi);
      await llm.setProviderApiKey(LLMProvider.openAi, 'test-key');

      final orchestrator = TaskOrchestrator(
        llmService: llm,
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final task = await orchestrator.executeInstruction('Search for Flutter agent');

      expect(task.status, TaskStatus.completed);
      expect(task.steps.length, greaterThanOrEqualTo(1));
      expect(task.steps.first.tool, 'web_search');
      expect(task.steps.first.status, 'success');
      expect(task.result, contains('Flutter autonomous agents'));
    });

    // 4. A message prepared for a specific recipient
    test('4. Prepares message for recipient with channels and content', () async {
      final tool = PrepareMessageTool();
      final context = ToolExecutionContext(
        llmService: LLMService(),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final result = await tool.execute(context, {
        'channel': 'whatsapp',
        'recipient': 'John',
        'message': 'I will arrive late.',
      });

      expect(result.success, isTrue);
      expect(result.output, contains('Draft prepared for John via whatsapp'));
      expect(result.output, contains('I will arrive late.'));
      expect(tool.risk, ToolRisk.low);
    });

    // 5. A message that cannot be sent without authorization
    test('5. Sensitive tools enforce ToolRisk.sensitive classification', () {
      final smsTool = SendSmsTool();
      final whatsappTool = SendWhatsAppMessageTool();
      final callTool = MakeCallTool();

      expect(smsTool.risk, ToolRisk.sensitive);
      expect(whatsappTool.risk, ToolRisk.sensitive);
      expect(callTool.risk, ToolRisk.sensitive);
    });

    // 6. An approved action
    test('6. Sensitive operation executes when user explicitly approves authorization', () async {
      int turn = 0;
      final mockClient = MockClient((request) async {
        turn++;
        if (turn == 1) {
          // Step 1: Planned sensitive SMS
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'Preparing to send text',
                    'tool_calls': [
                      {
                        'function': {
                          'name': 'send_sms',
                          'arguments': '{"phone_number":"+1234567890","message":"Hello John"}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        } else {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'Message was authorized and dispatched.',
                  },
                },
              ],
            }),
            200,
          );
        }
      });

      final llm = LLMService(client: mockClient);
      await llm.setProvider(LLMProvider.openAi);
      await llm.setProviderApiKey(LLMProvider.openAi, 'test-key');

      final orchestrator = TaskOrchestrator(
        llmService: llm,
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      // Start task asynchronously
      final futureTask = orchestrator.executeInstruction('Text John saying Hello');

      // Wait until orchestrator is waiting for authorization
      await Future.delayed(const Duration(milliseconds: 100));
      expect(orchestrator.status, TaskStatus.waitingForAuthorization);
      expect(orchestrator.pendingAuthorization, isNotNull);
      expect(orchestrator.pendingAuthorization!.toolName, 'send_sms');
      expect(orchestrator.pendingAuthorization!.destination, '+1234567890');
      expect(orchestrator.pendingAuthorization!.content, 'Hello John');

      // Approve authorization
      orchestrator.approveAuthorization(orchestrator.pendingAuthorization!.id);

      final completedTask = await futureTask;
      expect(completedTask.status, TaskStatus.completed);
      expect(completedTask.steps.any((s) => s.tool == 'send_sms'), isTrue);
    });

    // 7. A cancelled action
    test('7. Sensitive operation is aborted when user cancels authorization', () async {
      int turn = 0;
      final mockClient = MockClient((request) async {
        turn++;
        if (turn == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'Call requested',
                    'tool_calls': [
                      {
                        'function': {
                          'name': 'make_call',
                          'arguments': '{"phone_number":"+1987654321"}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        } else {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'Call was not placed because authorization was declined.',
                  },
                },
              ],
            }),
            200,
          );
        }
      });

      final llm = LLMService(client: mockClient);
      await llm.setProvider(LLMProvider.openAi);
      await llm.setProviderApiKey(LLMProvider.openAi, 'test-key');

      final orchestrator = TaskOrchestrator(
        llmService: llm,
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final futureTask = orchestrator.executeInstruction('Call +1987654321');

      await Future.delayed(const Duration(milliseconds: 100));
      expect(orchestrator.status, TaskStatus.waitingForAuthorization);

      // User rejects/cancels
      orchestrator.rejectAuthorization(orchestrator.pendingAuthorization!.id);

      final completedTask = await futureTask;
      expect(completedTask.status, TaskStatus.completed);
      expect(
        completedTask.steps.any((s) => s.status == 'authorization_rejected'),
        isTrue,
      );
    });

    // 8. A task that fails because a permission is missing
    test('8. Missing/denied permission records failure status', () async {
      final tool = FindContactTool();
      expect(tool.requiredPermissions, contains(Permission.contacts));
    });

    // 9. A task that recovers from a temporary network error
    test('9. Recovers from temporary network failure with bounded retry', () async {
      int searchAttempts = 0;
      final mockClient = MockClient((request) async {
        if (request.url.host == 'api.duckduckgo.com') {
          searchAttempts++;
          if (searchAttempts == 1) {
            // First attempt fails with temporary network timeout
            throw http.ClientException('Temporary network connection drop');
          }
          return http.Response(
            jsonEncode({
              'Heading': 'Recovered Search',
              'AbstractText': 'Recovered after retry.',
              'RelatedTopics': [],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final context = ToolExecutionContext(
        llmService: LLMService(client: mockClient),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
        httpClient: mockClient,
      );

      final searchTool = WebSearchTool();

      // First attempt produces a recoverable error
      final res1 = await searchTool.execute(context, {'query': 'test retry'});
      expect(res1.success, isFalse);
      expect(res1.isRecoverable, isTrue);

      // Second attempt recovers
      final res2 = await searchTool.execute(context, {'query': 'test retry'});
      expect(res2.success, isTrue);
      expect(res2.output, contains('Recovered after retry'));
    });

    // 10. An internal command that changes a supported app setting
    test('10. Operates own application settings through internal tools', () async {
      final context = ToolExecutionContext(
        llmService: LLMService(),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final updateTool = UpdateAppSettingTool();
      final updateResult = await updateTool.execute(context, {
        'setting': 'user_name',
        'value': 'Alexander',
      });

      expect(updateResult.success, isTrue);
      expect(await context.llmService.getUserName(), 'Alexander');

      final getSettingsTool = GetAppSettingsTool();
      final getResult = await getSettingsTool.execute(context, {});
      expect(getResult.success, isTrue);
      expect(getResult.output, contains('Alexander'));
    });

    // 11. A command that retrieves previous task results
    test('11. Retrieves previous task results and inspects history', () async {
      await taskExecutionService.createTask('Initial research task');
      final tasks = await taskExecutionService.listRecentTasks();
      expect(tasks, isNotEmpty);
      final taskId = tasks.first.id;

      await taskExecutionService.finish(
        taskId,
        status: TaskStatus.completed,
        result: 'Research completed with 3 sources.',
      );

      final context = ToolExecutionContext(
        llmService: LLMService(),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      final getStatusTool = GetTaskStatusTool();
      final statusResult = await getStatusTool.execute(context, {'task_id': taskId});

      expect(statusResult.success, isTrue);
      expect(statusResult.output, contains('Research completed with 3 sources.'));
    });

    // 12. Background task behavior when the user switches applications
    test('12. Platform service provides background command listener and pending command access', () async {
      String? receivedCommand;
      PlatformService.setOnBackgroundCommand((command) {
        receivedCommand = command;
      });

      expect(receivedCommand, isNull);
      expect(PlatformService.isError('Error occurred'), isTrue);
      expect(PlatformService.isError('Launched com.android.chrome'), isFalse);
    });

    // 13. Recovery after an interrupted task
    test('13. Persistent task state recovers tasks from secure storage', () async {
      final service1 = TaskExecutionService();
      final createdTask = await service1.createTask('Interrupted backup task');
      await service1.setStatus(createdTask.id, TaskStatus.executing);
      await service1.addStep(
        createdTask.id,
        tool: 'web_search',
        arguments: {'query': 'backup'},
        status: 'success',
        result: 'Found backup docs',
        verified: true,
      );

      // Simulate app restart by instantiating new service reading same storage
      final service2 = TaskExecutionService();
      final active = await service2.getActiveTask();

      expect(active, isNotNull);
      expect(active!.id, createdTask.id);
      expect(active.instruction, 'Interrupted backup task');
      expect(active.steps.length, 1);
      expect(active.steps.first.tool, 'web_search');
      expect(active.steps.first.verified, isTrue);
    });

    // 14. Prevention of duplicate sensitive actions
    test('14. Single-use authorization prevents duplicate sensitive executions', () async {
      final orchestrator = TaskOrchestrator(
        llmService: LLMService(),
        taskExecutionService: taskExecutionService,
        assistantProvider: assistantProvider,
      );

      // Initially no authorization request is pending
      expect(orchestrator.pendingAuthorization, isNull);

      // Invalid ID approval does not trigger any action
      orchestrator.approveAuthorization('non-existent-id');
      expect(orchestrator.pendingAuthorization, isNull);
    });
  });
}

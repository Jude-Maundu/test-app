import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/services/llm_service.dart';
import 'package:test_app/services/offline_intent_service.dart';
import 'package:test_app/services/permission_manager.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/services/task_execution_service.dart';
import 'package:test_app/services/tool_registry.dart';

class AuthorizationRequest {
  const AuthorizationRequest({
    required this.id,
    required this.taskId,
    required this.toolName,
    required this.targetApp,
    required this.destination,
    required this.content,
    required this.consequences,
    required this.arguments,
  });

  final String id;
  final String taskId;
  final String toolName;
  final String targetApp;
  final String destination;
  final String content;
  final String consequences;
  final Map<String, dynamic> arguments;

  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'toolName': toolName,
    'targetApp': targetApp,
    'destination': destination,
    'content': content,
    'consequences': consequences,
    'arguments': arguments,
  };
}

class TaskProgressEvent {
  const TaskProgressEvent({
    required this.taskId,
    required this.status,
    required this.message,
    this.currentStep,
    this.totalSteps,
    this.authorizationRequest,
  });

  final String taskId;
  final TaskStatus status;
  final String message;
  final int? currentStep;
  final int? totalSteps;
  final AuthorizationRequest? authorizationRequest;
}

class TaskOrchestrator extends ChangeNotifier {
  TaskOrchestrator({
    required this.llmService,
    required this.taskExecutionService,
    required this.assistantProvider,
    ToolRegistry? toolRegistry,
    PermissionManager? permissionManager,
    OfflineIntentService? offlineIntentService,
    this.onNavigate,
    this.httpClient,
  })  : toolRegistry = toolRegistry ?? ToolRegistry(),
        permissionManager = permissionManager ?? PermissionManager(),
        offlineIntentService = offlineIntentService ?? OfflineIntentService();

  final LLMService llmService;
  final TaskExecutionService taskExecutionService;
  final AssistantProvider assistantProvider;
  final ToolRegistry toolRegistry;
  final PermissionManager permissionManager;
  final OfflineIntentService offlineIntentService;
  final void Function(String routeName)? onNavigate;
  final http.Client? httpClient;

  TaskRecord? _currentTask;
  TaskStatus _status = TaskStatus.idle;
  String _statusMessage = '';
  AuthorizationRequest? _pendingAuthorization;
  Completer<bool>? _authorizationCompleter;
  bool _isCancelled = false;

  TaskRecord? get currentTask => _currentTask;
  TaskStatus get status => _status;
  String get statusMessage => _statusMessage;
  AuthorizationRequest? get pendingAuthorization => _pendingAuthorization;

  static const int maxTurns = 7;

  void _setStatus(TaskStatus newStatus, String message, {AuthorizationRequest? authReq}) {
    _status = newStatus;
    _statusMessage = message;
    _pendingAuthorization = authReq;
    notifyListeners();
  }

  Future<TaskRecord> executeInstruction(
    String instruction, {
    List<Map<String, String>> conversationHistory = const [],
  }) async {
    final trimmed = instruction.trim();
    if (trimmed.isEmpty) throw ArgumentError('Instruction cannot be empty');

    _isCancelled = false;
    _pendingAuthorization = null;
    _authorizationCompleter = null;

    // Check if the user is asking who created the assistant
    if (OfflineIntentService.isCreatorQuery(trimmed)) {
      final task = await taskExecutionService.createTask(trimmed);
      _currentTask = task;
      _setStatus(TaskStatus.completed, 'Task completed.');
      final completed = await taskExecutionService.finish(
        task.id,
        status: TaskStatus.completed,
        result: OfflineIntentService.creatorAnswer,
      );
      _currentTask = completed;
      return completed;
    }

    // Check if the user is answering a pending multi-turn conversation
    final resolvedAction = offlineIntentService.resolveWithContext(trimmed);

    final task = await taskExecutionService.createTask(trimmed);
    _currentTask = task;
    _setStatus(TaskStatus.planning, 'Analyzing instruction and planning steps...');

    try {
      final finalTask = await _runExecutionLoop(
        task,
        conversationHistory: conversationHistory,
        resolvedAction: resolvedAction,
      );
      _currentTask = finalTask;
      await _notifyTaskResult(finalTask);
      return finalTask;
    } catch (e, stack) {
      debugPrint('Task execution error: $e\n$stack');
      final failedTask = await taskExecutionService.finish(
        task.id,
        status: TaskStatus.failed,
        error: e.toString(),
      );
      _currentTask = failedTask;
      _setStatus(TaskStatus.failed, 'Task failed: $e');
      await _notifyTaskResult(failedTask);
      return failedTask;
    }
  }

  Future<void> _notifyTaskResult(TaskRecord task) async {
    try {
      if (await permissionManager.shouldNotifyOnTaskCompletion()) {
        final title = task.status == TaskStatus.completed
            ? 'Jarvis: Task Completed'
            : 'Jarvis: Task ${task.status.name}';
        final body = task.result ?? task.error ?? task.instruction;
        await PlatformService.showNotification(title, body);
      }
    } catch (_) {}
  }

  Future<TaskRecord> _runExecutionLoop(
    TaskRecord initialTask, {
    List<Map<String, String>> conversationHistory = const [],
    Map<String, dynamic>? resolvedAction,
  }) async {
    var task = initialTask;
    final contextHistory = <Map<String, String>>[];
    final executionContext = ToolExecutionContext(
      llmService: llmService,
      taskExecutionService: taskExecutionService,
      assistantProvider: assistantProvider,
      onNavigate: onNavigate,
      httpClient: httpClient ?? llmService.client,
    );

    // Initial system prompt with full tool schemas & strict execution instructions
    final systemPrompt = _buildAgentSystemPrompt();

    // Seed context history with previous turns for conversational memory retention
    if (conversationHistory.isNotEmpty) {
      contextHistory.addAll(conversationHistory.take(8));
    }

    // Add user instruction
    contextHistory.add({'role': 'user', 'content': task.instruction});

    int turnCount = 0;
    while (turnCount < maxTurns) {
      if (_isCancelled) {
        task = await taskExecutionService.finish(
          task.id,
          status: TaskStatus.cancelled,
          result: 'Task was cancelled by user.',
        );
        _setStatus(TaskStatus.cancelled, 'Task cancelled by user.');
        return task;
      }

      turnCount++;
      _setStatus(TaskStatus.planning, 'Reasoning on next step (Step $turnCount)...');

      // Request next agent action from LLM or pre-resolved conversational action
      Map<String, dynamic> llmResponse;
      if (turnCount == 1 && resolvedAction != null) {
        llmResponse = resolvedAction;
      } else {
        llmResponse = await _queryAgentLlm(contextHistory, systemPrompt, task.instruction);
      }
      if (_isCancelled) break;

      final thought = llmResponse['thought'] as String? ?? '';
      final finalAnswer = llmResponse['final_answer'] as String?;
      final toolName = llmResponse['tool'] as String?;
      final toolArgs = llmResponse['arguments'] as Map<String, dynamic>? ?? {};

      // If the LLM has concluded the task with a final answer and no more tool calls
      if (finalAnswer != null && finalAnswer.trim().isNotEmpty && (toolName == null || toolName == 'none' || toolName.isEmpty)) {
        _setStatus(TaskStatus.completed, 'Task completed.');
        task = await taskExecutionService.finish(
          task.id,
          status: TaskStatus.completed,
          result: finalAnswer.trim(),
        );
        return task;
      }

      // If no tool was selected and no final answer, check fallback response text
      if (toolName == null || toolName.isEmpty || toolName == 'none') {
        final text = llmResponse['response'] as String? ?? 'Task finished.';
        _setStatus(TaskStatus.completed, 'Task completed.');
        task = await taskExecutionService.finish(
          task.id,
          status: TaskStatus.completed,
          result: text.trim(),
        );
        return task;
      }

      // Validate tool
      final tool = toolRegistry.get(toolName);
      if (tool == null) {
        contextHistory.add({
          'role': 'assistant',
          'content': jsonEncode({'thought': thought, 'tool': toolName, 'arguments': toolArgs}),
        });
        contextHistory.add({
          'role': 'user',
          'content': 'Tool "$toolName" does not exist in registry. Available tools: ${toolRegistry.allTools.map((t) => t.name).join(", ")}. Choose a valid tool or provide final_answer.',
        });
        continue;
      }

      final validationError = tool.validate(toolArgs);
      if (validationError != null) {
        contextHistory.add({
          'role': 'assistant',
          'content': jsonEncode({'thought': thought, 'tool': toolName, 'arguments': toolArgs}),
        });
        contextHistory.add({
          'role': 'user',
          'content': 'Tool argument validation failed for $toolName: $validationError. Correct the arguments.',
        });
        continue;
      }

      // Check Risk Classification & Explicit Authorization
      // Respects: "once i have given it permission once it should always go ahead"
      if (tool.risk == ToolRisk.sensitive) {
        final isAlreadyAuthorized = await permissionManager.isToolAuthorized(tool.name);
        if (!isAlreadyAuthorized) {
          final authReq = _buildAuthorizationRequest(task.id, tool, toolArgs);
          _setStatus(
            TaskStatus.waitingForAuthorization,
            'Awaiting authorization to ${tool.name}...',
            authReq: authReq,
          );

          final approved = await _requestAuthorization(authReq);
          if (!approved) {
            final cancelMsg = 'Action ${tool.name} was cancelled by the user.';
            contextHistory.add({
              'role': 'assistant',
              'content': jsonEncode({'thought': thought, 'tool': toolName, 'arguments': toolArgs}),
            });
            contextHistory.add({
              'role': 'user',
              'content': 'User rejected authorization for ${tool.name}. Stop or report that the action was cancelled as requested.',
            });
            task = await taskExecutionService.addStep(
              task.id,
              tool: tool.name,
              arguments: toolArgs,
              status: 'authorization_rejected',
              result: cancelMsg,
              verified: false,
            );
            continue;
          }

          // Permanently save permission so future commands go ahead automatically!
          await permissionManager.grantToolAuthorization(tool.name);
        }
      }

      // Check required Android permissions (after authorization is approved)
      if (!PlatformService.isLinux && tool.requiredPermissions.isNotEmpty) {
        _setStatus(TaskStatus.waitingForPermission, 'Checking permissions for ${tool.name}...');
        bool permissionDenied = false;
        for (final perm in tool.requiredPermissions) {
          try {
            final status = await perm.status;
            if (!status.isGranted) {
              final requested = await perm.request();
              if (!requested.isGranted) {
                permissionDenied = true;
                final permError = 'Permission ${perm.toString()} was denied by the user. Explain this limitation to the user.';
                contextHistory.add({
                  'role': 'assistant',
                  'content': jsonEncode({'thought': thought, 'tool': toolName, 'arguments': toolArgs}),
                });
                contextHistory.add({'role': 'user', 'content': permError});
                task = await taskExecutionService.addStep(
                  task.id,
                  tool: tool.name,
                  arguments: toolArgs,
                  status: 'permission_denied',
                  result: permError,
                  error: permError,
                  verified: false,
                );
                break;
              }
            }
          } on MissingPluginException {
            // Native platform channel unavailable in current environment (e.g. unit tests)
          } catch (e) {
            debugPrint('Permission check error for ${perm.toString()}: $e');
          }
        }
        if (permissionDenied) {
          continue;
        }
      }

      // Execute tool
      _setStatus(TaskStatus.executing, 'Executing ${tool.name}...');
      ToolResult result;
      try {
        result = await tool.execute(executionContext, toolArgs);
      } catch (execError) {
        result = ToolResult.error('Execution exception: $execError', recoverable: true);
      }

      // Verification phase
      _setStatus(TaskStatus.verifying, 'Verifying result of ${tool.name}...');
      final verified = await tool.verify(executionContext, toolArgs, result);

      // Record step into TaskRecord
      task = await taskExecutionService.addStep(
        task.id,
        tool: tool.name,
        arguments: toolArgs,
        status: result.success ? 'success' : 'failed',
        result: result.output,
        error: result.errorMessage,
        verified: verified,
      );

      // Record to history so LLM can reason on actual result
      contextHistory.add({
        'role': 'assistant',
        'content': jsonEncode({'thought': thought, 'tool': tool.name, 'arguments': toolArgs}),
      });
      contextHistory.add({
        'role': 'user',
        'content': 'Observation from ${tool.name}: ${result.output}\nVerified: $verified.\nWhat is the next step or final outcome?',
      });
    }

    // If max turns reached
    final summary = await _synthesizeOutcome(task, contextHistory);
    task = await taskExecutionService.finish(
      task.id,
      status: TaskStatus.completed,
      result: summary,
    );
    _setStatus(TaskStatus.completed, 'Task completed.');
    return task;
  }

  AuthorizationRequest _buildAuthorizationRequest(
    String taskId,
    AssistantTool tool,
    Map<String, dynamic> args,
  ) {
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final targetApp =
        tool.targetApp ?? (PlatformService.isLinux ? 'Linux System' : 'Android System');

    String destination = 'Device';
    String content = '';
    String consequences = 'Executing this operation will perform an external action.';

    if (tool.name == 'send_sms') {
      destination = args['phone_number']?.toString() ?? 'Phone';
      content = args['message']?.toString() ?? '';
      consequences = 'This will send an SMS to $destination. Standard carrier charges may apply.';
    } else if (tool.name == 'send_whatsapp_message') {
      destination = args['phone_number']?.toString() ?? 'Selected contact';
      content = args['message']?.toString() ?? '';
      consequences = 'This will open WhatsApp and prepare a message to $destination.';
    } else if (tool.name == 'make_call') {
      destination = args['phone_number']?.toString() ?? 'Phone number';
      content = 'Place direct call to $destination';
      consequences = 'This will start a phone call to $destination immediately.';
    } else if (tool.name == 'send_email') {
      destination = args['to']?.toString() ?? 'Recipient';
      content = 'Subject: ${args['subject'] ?? ''}\nBody: ${args['body'] ?? ''}';
      consequences = 'This will draft and send an email to $destination.';
    }

    return AuthorizationRequest(
      id: id,
      taskId: taskId,
      toolName: tool.name,
      targetApp: targetApp,
      destination: destination,
      content: content,
      consequences: consequences,
      arguments: args,
    );
  }

  Future<bool> _requestAuthorization(AuthorizationRequest request) async {
    _authorizationCompleter = Completer<bool>();
    // Inform the user via audio/TTS if hands-free
    try {
      await assistantProvider.speak(
        'Authorization needed: Do you want me to ${request.toolName.replaceAll("_", " ")} for ${request.destination}?',
      );
    } catch (_) {}

    return _authorizationCompleter!.future;
  }

  Future<void> approveAuthorization(String requestId) async {
    if (_pendingAuthorization != null && _pendingAuthorization!.id == requestId) {
      final toolName = _pendingAuthorization!.toolName;
      await permissionManager.grantToolAuthorization(toolName);
      _authorizationCompleter?.complete(true);
      _pendingAuthorization = null;
      notifyListeners();
    }
  }

  void rejectAuthorization(String requestId) {
    if (_pendingAuthorization != null && _pendingAuthorization!.id == requestId) {
      _authorizationCompleter?.complete(false);
      _pendingAuthorization = null;
      notifyListeners();
    }
  }

  void cancelActiveTask() {
    _isCancelled = true;
    _authorizationCompleter?.complete(false);
    _pendingAuthorization = null;
    taskExecutionService.cancelActiveTask();
    _setStatus(TaskStatus.cancelled, 'Task cancelled by user.');
  }

  String _buildAgentSystemPrompt() {
    final toolsJson = jsonEncode(toolRegistry.toToolSchemas());
    final platform = PlatformService.isLinux ? 'Linux' : 'Android';
    return '''
You are Jarvis, an autonomous $platform AI assistant execution agent created by Jude.
When asked who created you, who made you, who your developer is, or who built you, you must always state clearly that you were created by Jude.
Your primary role is to EXECUTE tasks using available tools, NOT just talk about them.

CRITICAL INSTRUCTIONS:
1. Break user instructions into small, logical steps.
2. For each step, respond ONLY with a JSON object in this exact format:
{
  "thought": "<brief reasoning for this step>",
  "tool": "<exact tool name to invoke>",
  "arguments": { <tool input parameters> }
}
3. If no further action is required and the task has been fully executed, respond with:
{
  "thought": "<brief conclusion>",
  "final_answer": "<factual summary of the actual outcome>"
}
4. NEVER claim an action was done before observing the result from the tool.
5. If a sensitive tool is used (e.g. sending messages, placing calls), prepare the draft first, and the system will pause for user authorization before execution.
6. Available tools:
$toolsJson
''';
  }

  Future<Map<String, dynamic>> _queryAgentLlm(
    List<Map<String, String>> contextHistory,
    String systemPrompt, [
    String currentInstruction = '',
  ]) async {
    try {
      final lastUserTurn = contextHistory.last['content'] ?? currentInstruction;
      final priorTurns = contextHistory.sublist(0, contextHistory.length - 1);

      final result = await llmService.processCommand(
        lastUserTurn,
        history: priorTurns,
        allowTools: true,
      );

      final rawResponse = result['response'] as String? ?? '';
      final toolCall = result['tool_call'];

      // If Ollama or cloud connection failed, fallback to offline pattern parsing!
      final lowerResp = rawResponse.toLowerCase();
      if (lowerResp.contains('connection error') ||
          lowerResp.contains('refused') ||
          lowerResp.contains('network request failed') ||
          lowerResp.contains('failed host lookup')) {
        final offlineFallback = offlineIntentService.parseOfflineCommand(currentInstruction.isNotEmpty ? currentInstruction : lastUserTurn);
        if (offlineFallback != null) {
          return offlineFallback;
        }
      }

      // If native tool call was returned by provider
      if (toolCall != null && toolCall is Map) {
        return {
          'thought': rawResponse,
          'tool': toolCall['name'],
          'arguments': toolCall['arguments'] ?? {},
        };
      }

      // Otherwise parse structured output from text response (for Ollama/Gemma)
      final parsed = _extractJsonBlock(rawResponse);
      if (parsed != null) {
        return parsed;
      }

      // If the model asks for more information (e.g. "What to text Jude on WhatsApp?"),
      // capture it in pending context so conversational memory doesn't forget!
      _detectPendingContextFromResponse(rawResponse, currentInstruction.isNotEmpty ? currentInstruction : lastUserTurn);

      // Check if text indicates a final answer or conversational response
      return {
        'thought': 'Direct response',
        'final_answer': rawResponse,
        'response': rawResponse,
      };
    } catch (e) {
      final offlineFallback = offlineIntentService.parseOfflineCommand(currentInstruction.isNotEmpty ? currentInstruction : contextHistory.last['content'] ?? '');
      if (offlineFallback != null) {
        return offlineFallback;
      }
      return {
        'thought': 'Error during reasoning: $e',
        'final_answer': 'Encountered an issue: $e',
      };
    }
  }

  void _detectPendingContextFromResponse(String response, String instruction) {
    final lowerResp = response.toLowerCase();
    final lowerInst = instruction.toLowerCase();

    // Check if the user mentioned WhatsApp and assistant asked what to text
    if (lowerInst.contains('whatsapp') || lowerResp.contains('whatsapp')) {
      final match = RegExp(r'(?:text|message|to)\s+([a-zA-Z0-9_]+)', caseSensitive: false).firstMatch(instruction);
      final recipient = match?.group(1) ?? 'the contact';
      if (lowerResp.contains('what') || lowerResp.contains('message') || lowerResp.contains('say')) {
        offlineIntentService.setPendingContext(
          PendingConversationContext(
            toolName: 'send_whatsapp_message',
            arguments: {'phone_number': recipient},
            missingField: 'message',
            promptQuestion: response,
            recipient: recipient,
          ),
        );
      }
    } else if (lowerInst.contains('sms') || lowerInst.startsWith('text ')) {
      final match = RegExp(r'(?:text|sms|to)\s+([a-zA-Z0-9_]+)', caseSensitive: false).firstMatch(instruction);
      final recipient = match?.group(1) ?? 'the contact';
      if (lowerResp.contains('what') || lowerResp.contains('message') || lowerResp.contains('say')) {
        offlineIntentService.setPendingContext(
          PendingConversationContext(
            toolName: 'send_sms',
            arguments: {'phone_number': recipient},
            missingField: 'message',
            promptQuestion: response,
            recipient: recipient,
          ),
        );
      }
    }
  }

  Map<String, dynamic>? _extractJsonBlock(String text) {
    try {
      // Check for ```json ... ``` blocks
      final match = RegExp(r'```(?:json)?\s*(\{.*?\})\s*```', dotAll: true).firstMatch(text);
      if (match != null) {
        final jsonStr = match.group(1);
        if (jsonStr != null) {
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic>) return decoded;
        }
      }

      // Check if the whole text is a JSON object
      final trimmed = text.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) return decoded;
      }

      // Find first { and last }
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        final sub = text.substring(start, end + 1);
        final decoded = jsonDecode(sub);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {}
    return null;
  }

  Future<String> _synthesizeOutcome(
    TaskRecord task,
    List<Map<String, String>> history,
  ) async {
    final completedSteps = task.steps.map((s) => '${s.tool}: ${s.status} (${s.result})').join('; ');
    if (completedSteps.isEmpty) return 'No actions performed.';

    try {
      final res = await llmService.processCommand(
        'The task "${task.instruction}" performed these steps: $completedSteps. '
        'Provide a concise 1-sentence summary of the actual outcome for the user.',
        allowTools: false,
      );
      final summary = res['response'] as String? ?? '';
      return summary.trim().isEmpty ? completedSteps : summary.trim();
    } catch (_) {
      return completedSteps;
    }
  }
}

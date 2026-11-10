import 'dart:convert';
import 'dart:io' show File, Process;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:test_app/services/offline_intent_service.dart';
import 'package:test_app/services/tool_registry.dart';

enum LLMProvider { anthropic, ollama, openAi, gemini, groq, openRouter }

extension LLMProviderDetails on LLMProvider {
  String get displayName => switch (this) {
    LLMProvider.anthropic => 'Anthropic',
    LLMProvider.ollama => 'Ollama (Local)',
    LLMProvider.openAi => 'OpenAI',
    LLMProvider.gemini => 'Google Gemini',
    LLMProvider.groq => 'Groq',
    LLMProvider.openRouter => 'OpenRouter',
  };

  String get keyUrl => switch (this) {
    LLMProvider.anthropic => 'https://console.anthropic.com/settings/keys',
    LLMProvider.ollama => 'https://ollama.com/download',
    LLMProvider.openAi => 'https://platform.openai.com/api-keys',
    LLMProvider.gemini => 'https://aistudio.google.com/app/apikey',
    LLMProvider.groq => 'https://console.groq.com/keys',
    LLMProvider.openRouter => 'https://openrouter.ai/keys',
  };
}

class OllamaPullProgress {
  const OllamaPullProgress({required this.status, this.completed, this.total});

  final String status;
  final int? completed;
  final int? total;

  double? get fraction {
    if (completed == null || total == null || total == 0) return null;
    return completed! / total!;
  }
}

class LLMService {
  LLMService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  http.Client get client => _client;
  final _storage = const FlutterSecureStorage();
  static const String _legacyApiKeyKey = 'llm_api_key';
  static const String _providerKey = 'llm_provider';
  static const String _ollamaUrlKey = 'ollama_base_url';
  static const String _ollamaModelKey = 'ollama_model';
  static const String _userNameKey = 'jarvis_user_name';
  static const String _notesKey = 'jarvis_local_notes';
  static const String _activityKey = 'jarvis_activity_log';
  static const String _buildTimeApiKey = String.fromEnvironment('LLM_API_KEY');
  static const String _anthropicUrl = 'https://api.anthropic.com/v1/messages';
  static const String _anthropicModel = 'claude-sonnet-4-5';
  static const String androidEmulatorOllamaUrl = 'http://10.0.2.2:11434';
  static String get defaultOllamaUrl =>
      defaultTargetPlatform == TargetPlatform.android
      ? androidEmulatorOllamaUrl
      : 'http://localhost:11434';
  static const String defaultOllamaModel = 'llama3.2';
  static const String gemmaFourBModel = 'gemma3:4b';

  static const String _systemPrompt =
      'You are Jarvis, a calm, witty, polite, and concise AI voice assistant created by Jude. Emulate the persona of Jarvis from Iron Man: calm, sophisticated, witty, and polite. When asked who created you, who made you, who your developer is, or who built you, you must always state clearly that Jude created you. Use a tool when the user '
      'asks to play music, launch an app, set an alarm, make a call, send a text message, '
      'read notifications, find a contact, save a dictated note, search the '
      'web, check weather, navigate somewhere, set a timer, add a calendar '
      'event, or control media. For calling or texting a person, use their '
      'contact name and never guess a phone number. Otherwise answer '
      'naturally, calm and witty, and keep replies concise because they are spoken aloud.';

  Future<void> setApiKey(String key) async {
    await setProviderApiKey(await getProvider(), key);
  }

  Future<String> getUserName() async =>
      await _storage.read(key: _userNameKey) ?? 'Jude';

  Future<void> setUserName(String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Enter the name Jarvis should use.');
    }
    if (cleaned.length > 40) {
      throw ArgumentError.value(name, 'name', 'Name must be 40 characters or fewer.');
    }
    await _storage.write(key: _userNameKey, value: cleaned);
  }

  Future<String> _personalizedSystemPrompt() async {
    final name = (await getUserName()).trim();
    if (name.isEmpty) return _systemPrompt;
    return '$_systemPrompt Address the user as $name naturally from time to '
        'time, especially in greetings, but do not repeat their name in every '
        'reply.';
  }

  Future<List<Map<String, String>>> getConversationHistory() async {
    final raw = await _storage.read(key: 'jarvis_conversation_history');
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .where(
          (turn) =>
              (turn['role'] == 'user' || turn['role'] == 'assistant') &&
              turn['content'] is String,
        )
        .map(
          (turn) => {
            'role': turn['role'] as String,
            'content': turn['content'] as String,
          },
        )
        .toList();
  }

  Future<void> saveConversationHistory(
    List<Map<String, String>> history,
  ) async {
    await _storage.write(
      key: 'jarvis_conversation_history',
      value: jsonEncode(history.take(20).toList()),
    );
  }

  Future<List<String>> getNotes() async {
    final raw = await _storage.read(key: _notesKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List<dynamic>).whereType<String>().toList();
  }

  Future<void> saveNote(String note) async {
    final value = note.trim();
    if (value.isEmpty) throw ArgumentError('Note cannot be empty.');
    final notes = await getNotes();
    notes.insert(0, value);
    await _storage.write(
      key: _notesKey,
      value: jsonEncode(notes.take(100).toList()),
    );
  }

  Future<List<Map<String, String>>> getActivityLog() async {
    final raw = await _storage.read(key: _activityKey);
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .where((entry) => entry['time'] is String && entry['summary'] is String)
        .map(
          (entry) => {
            'time': entry['time'] as String,
            'summary': entry['summary'] as String,
          },
        )
        .toList();
  }

  Future<void> recordActivity(String summary) async {
    final entries = await getActivityLog();
    entries.insert(0, {
      'time': DateTime.now().toIso8601String(),
      'summary': summary,
    });
    await _storage.write(
      key: _activityKey,
      value: jsonEncode(entries.take(100).toList()),
    );
  }

  Future<void> setProviderApiKey(LLMProvider provider, String key) async {
    await _storage.write(key: _keyFor(provider), value: key.trim());
  }

  Future<String?> getApiKey({LLMProvider? provider}) async {
    final selectedProvider = provider ?? await getProvider();
    final storedKey = await _storage.read(key: _keyFor(selectedProvider));
    if (storedKey != null && storedKey.isNotEmpty) return storedKey;
    if (selectedProvider == LLMProvider.anthropic) {
      return await _storage.read(key: _legacyApiKeyKey) ??
          (_buildTimeApiKey.isEmpty ? null : _buildTimeApiKey);
    }
    return null;
  }

  String _keyFor(LLMProvider provider) => 'llm_api_key_${provider.name}';

  Future<void> setModel(String model, {LLMProvider? provider}) async {
    final selected = provider ?? await getProvider();
    final name = model.trim();
    if (name.isEmpty) throw ArgumentError('Model name cannot be empty.');
    await _storage.write(key: 'llm_model_${selected.name}', value: name);
  }

  Future<void> clearConfiguredModel({LLMProvider? provider}) async {
    final selected = provider ?? await getProvider();
    await _storage.delete(key: 'llm_model_${selected.name}');
  }

  Future<String?> getConfiguredModel({LLMProvider? provider}) async {
    final selected = provider ?? await getProvider();
    final model = await _storage.read(key: 'llm_model_${selected.name}');
    return model?.trim().isEmpty == true ? null : model;
  }

  Future<String> _resolveModel(LLMProvider provider) async {
    final configured = await getConfiguredModel(provider: provider);
    if (configured != null) return configured;
    return getModel(provider: provider);
  }

  Future<String> getModel({LLMProvider? provider}) async {
    final selected = provider ?? await getProvider();
    final defaultModel = switch (selected) {
      LLMProvider.anthropic => _anthropicModel,
      LLMProvider.ollama => defaultOllamaModel,
      LLMProvider.openAi => 'gpt-4o-mini',
      LLMProvider.gemini => 'gemini-2.5-flash',
      LLMProvider.groq => 'llama-3.3-70b-versatile',
      LLMProvider.openRouter => 'openai/gpt-4o-mini',
    };
    return await _storage.read(key: 'llm_model_${selected.name}') ??
        defaultModel;
  }

  Future<String> discoverAndSaveModel(LLMProvider provider) async {
    final apiKey = await getApiKey(provider: provider);
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw StateError(
        'Enter and save the ${provider.displayName} API key first.',
      );
    }

    final models = await _fetchProviderModels(provider, apiKey.trim());
    if (models.isEmpty) {
      throw StateError(
        'The key is valid, but ${provider.displayName} did not return a '
        'compatible chat model. Check that your account has model access.',
      );
    }
    final selected = _recommendedModel(provider, models);
    await setModel(selected, provider: provider);
    return selected;
  }

  Future<List<String>> _fetchProviderModels(
    LLMProvider provider,
    String apiKey,
  ) async {
    final Uri uri;
    final headers = <String, String>{};
    switch (provider) {
      case LLMProvider.anthropic:
        uri = Uri.https('api.anthropic.com', '/v1/models', {'limit': '1000'});
        headers
          ..['x-api-key'] = apiKey
          ..['anthropic-version'] = '2023-06-01'
          ..['anthropic-dangerous-direct-browser-access'] = 'true';
      case LLMProvider.openAi:
        uri = Uri.https('api.openai.com', '/v1/models');
        headers['Authorization'] = 'Bearer $apiKey';
      case LLMProvider.groq:
        uri = Uri.https('api.groq.com', '/openai/v1/models');
        headers['Authorization'] = 'Bearer $apiKey';
      case LLMProvider.openRouter:
        uri = Uri.https('openrouter.ai', '/api/v1/models');
        headers
          ..['Authorization'] = 'Bearer $apiKey'
          ..['X-Title'] = 'Jarvis Assistant';
      case LLMProvider.gemini:
        uri = Uri.https('generativelanguage.googleapis.com', '/v1beta/models', {
          'key': apiKey,
          'pageSize': '1000',
        });
      case LLMProvider.ollama:
        throw ArgumentError('Ollama models are listed by the Ollama server.');
    }

    if (provider != LLMProvider.anthropic && provider != LLMProvider.gemini) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    final response = await _client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        '${provider.displayName} rejected the key or model-list request '
        '(${response.statusCode}): ${_safeErrorBody(response.body)}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final entries =
        (decoded['data'] ?? decoded['models']) as List<dynamic>? ?? [];
    return entries
        .whereType<Map<String, dynamic>>()
        .where((entry) {
          if (provider != LLMProvider.gemini) return true;
          final methods =
              entry['supportedGenerationMethods'] as List<dynamic>? ?? [];
          return methods.contains('generateContent');
        })
        .map((entry) => (entry['id'] ?? entry['name']) as String?)
        .whereType<String>()
        .map(
          (name) => provider == LLMProvider.gemini
              ? name.replaceFirst('models/', '')
              : name,
        )
        .where((name) => _isChatModel(provider, name))
        .toList();
  }

  bool _isChatModel(LLMProvider provider, String name) {
    final lower = name.toLowerCase();
    if (provider == LLMProvider.anthropic) return lower.contains('claude');
    if (provider == LLMProvider.gemini) {
      return lower.contains('gemini') &&
          !lower.contains('embedding') &&
          !lower.contains('aqa');
    }
    if (provider == LLMProvider.openRouter) {
      return !lower.contains('embed') &&
          !lower.contains('moderation') &&
          !lower.contains('whisper') &&
          !lower.contains('tts');
    }
    return (lower.startsWith('gpt-') ||
            lower.contains('llama') ||
            lower.contains('qwen') ||
            lower.contains('deepseek') ||
            lower.contains('gemma') ||
            lower.contains('mixtral') ||
            lower.contains('command-r')) &&
        !lower.contains('embedding') &&
        !lower.contains('moderation') &&
        !lower.contains('whisper') &&
        !lower.contains('tts') &&
        !lower.contains('realtime');
  }

  String _recommendedModel(LLMProvider provider, List<String> models) {
    final lowerNames = models.map((name) => name.toLowerCase()).toList();
    final preferences = switch (provider) {
      LLMProvider.anthropic => ['sonnet', 'haiku', 'opus'],
      LLMProvider.gemini => ['flash', 'pro'],
      LLMProvider.openAi => ['gpt-4o-mini', 'gpt-4.1-mini', 'gpt-4o'],
      LLMProvider.groq => ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant'],
      LLMProvider.openRouter => ['openai/gpt-4o-mini', 'google/gemini-flash'],
      LLMProvider.ollama => const [],
    };
    for (final preferred in preferences) {
      final index = lowerNames.indexWhere((name) => name.contains(preferred));
      if (index >= 0) return models[index];
    }
    models.sort((a, b) {
      final aPreview = RegExp(r'preview|experimental|latest').hasMatch(a);
      final bPreview = RegExp(r'preview|experimental|latest').hasMatch(b);
      if (aPreview != bPreview) return aPreview ? 1 : -1;
      return b.compareTo(a);
    });
    return models.first;
  }

  String _safeErrorBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          return error['message']?.toString() ?? body;
        }
        if (error is String) return error;
        return decoded['message']?.toString() ?? body;
      }
    } on FormatException {
      return body;
    }
    return body;
  }

  Future<LLMProvider> getProvider() async {
    final provider = await _storage.read(key: _providerKey);
    return LLMProvider.values.firstWhere(
      (value) => value.name == provider,
      orElse: () => LLMProvider.anthropic,
    );
  }

  Future<void> setProvider(LLMProvider provider) async {
    await _storage.write(key: _providerKey, value: provider.name);
  }

  Future<String> getOllamaBaseUrl() async {
    final storedUrl = await _storage.read(key: _ollamaUrlKey);
    if (storedUrl == null) return defaultOllamaUrl;

    final uri = Uri.tryParse(storedUrl);
    if (defaultTargetPlatform == TargetPlatform.android &&
        (uri?.host == 'localhost' || uri?.host == '127.0.0.1')) {
      return uri!.replace(host: '10.0.2.2').toString();
    }
    return storedUrl;
  }

  Future<void> setOllamaBaseUrl(String url) async {
    await _storage.write(key: _ollamaUrlKey, value: _normalizeBaseUrl(url));
  }

  Future<String> getOllamaModel() async {
    final configured = await _storage.read(key: _ollamaModelKey);
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim();
    }
    // Auto-detect installed models from Ollama server
    try {
      final models = await listOllamaModels();
      if (models.isNotEmpty) {
        for (final cand in [
          'llama3.2:latest',
          'llama3.2',
          'qwen3.5:4b',
          'qwen2.5:3b',
          'qwen2.5-coder:1.5b',
        ]) {
          if (models.contains(cand)) return cand;
        }
        return models.first;
      }
    } catch (_) {}
    return defaultOllamaModel;
  }

  Future<String> _resolveOllamaModel(String model, {String? baseUrl}) async {
    try {
      final models = await listOllamaModels(baseUrl: baseUrl);
      if (models.isEmpty) return model;
      if (models.contains(model)) return model;
      final withLatest = '$model:latest';
      if (models.contains(withLatest)) return withLatest;
      final stripped = model.split(':').first;
      final match = models.firstWhere((m) => m.startsWith(stripped), orElse: () => '');
      if (match.isNotEmpty) return match;
      return models.first;
    } catch (_) {
      return model;
    }
  }

  Future<void> setOllamaModel(String model) async {
    final trimmedModel = model.trim();
    if (trimmedModel.isEmpty) {
      throw ArgumentError.value(model, 'model', 'Model name cannot be empty.');
    }
    await _storage.write(key: _ollamaModelKey, value: trimmedModel);
  }

  Future<List<String>> listOllamaModels({String? baseUrl}) async {
    final response = await _client
        .get(_ollamaUri(baseUrl ?? await getOllamaBaseUrl(), '/api/tags'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception(
        'Ollama returned ${response.statusCode}: ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final models = data['models'] as List<dynamic>? ?? [];
    return models
        .map((model) => (model as Map<String, dynamic>)['name'] as String)
        .toList();
  }

  Future<void> pullOllamaModel({
    required String model,
    String? baseUrl,
    void Function(OllamaPullProgress progress)? onProgress,
  }) async {
    final trimmedModel = model.trim();
    if (trimmedModel.isEmpty) {
      throw ArgumentError.value(model, 'model', 'Model name cannot be empty.');
    }

    final request =
        http.Request(
            'POST',
            _ollamaUri(baseUrl ?? await getOllamaBaseUrl(), '/api/pull'),
          )
          ..headers['content-type'] = 'application/json'
          ..body = jsonEncode({'name': trimmedModel, 'stream': true});
    final response = await _client
        .send(request)
        .timeout(const Duration(minutes: 30));
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception('Ollama returned ${response.statusCode}: $body');
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      final event = jsonDecode(line) as Map<String, dynamic>;
      if (event['error'] != null) {
        throw Exception('Ollama could not pull the model: ${event['error']}');
      }
      onProgress?.call(
        OllamaPullProgress(
          status: event['status'] as String? ?? 'Downloading model',
          completed: (event['completed'] as num?)?.toInt(),
          total: (event['total'] as num?)?.toInt(),
        ),
      );
    }
  }

  Future<Map<String, dynamic>> processCommand(
    String text, {
    List<Map<String, String>> history = const [],
    bool allowTools = true,
  }) async {
    if (OfflineIntentService.isCreatorQuery(text)) {
      return {'response': OfflineIntentService.creatorAnswer};
    }
    final provider = await getProvider();
    final systemPrompt = await _personalizedSystemPrompt();
    return switch (provider) {
      LLMProvider.ollama =>
        _processWithOllama(text, history, allowTools, systemPrompt),
      LLMProvider.anthropic =>
        _processWithAnthropic(text, history, allowTools, systemPrompt),
      LLMProvider.openAi || LLMProvider.groq || LLMProvider.openRouter =>
        _processWithOpenAiCompatible(
          text,
          provider,
          history,
          allowTools,
          systemPrompt,
        ),
      LLMProvider.gemini =>
        _processWithGemini(text, history, allowTools, systemPrompt),
    };
  }

  List<Map<String, String>> _turns(
    String text,
    List<Map<String, String>> history,
  ) => [
    ...history.take(10),
    {'role': 'user', 'content': text},
  ];

  Future<Map<String, dynamic>> _processWithOllama(
    String text,
    List<Map<String, String>> history,
    bool allowTools,
    String systemPrompt,
  ) async {
    try {
      final baseUrl = await getOllamaBaseUrl();
      final configuredModel = await getOllamaModel();
      final model = await _resolveOllamaModel(configuredModel, baseUrl: baseUrl);

      http.Response? response;

      // 1. First attempt: call with native tools if allowed
      if (allowTools) {
        try {
          response = await _client
              .post(
                _ollamaUri(baseUrl, '/api/chat'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({
                  'model': model,
                  'stream': false,
                  'messages': [
                    {'role': 'system', 'content': systemPrompt},
                    ..._turns(text, history),
                  ],
                  'tools': _tools,
                }),
              )
              .timeout(const Duration(minutes: 2));
        } catch (_) {
          response = null;
        }
      }

      // 2. Fallback attempt: if tools were rejected or status != 200, retry with prompt instructions
      if (response == null || response.statusCode != 200) {
        final toolsSchema = allowTools
            ? '\nAvailable tools:\n${jsonEncode(_tools)}\n'
                'To invoke a tool, respond ONLY with a JSON object: {"tool": "<tool_name>", "arguments": {<args>}}.'
            : '';
        response = await _client
            .post(
              _ollamaUri(baseUrl, '/api/chat'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'model': model,
                'stream': false,
                'messages': [
                  {'role': 'system', 'content': '$systemPrompt$toolsSchema'},
                  ..._turns(text, history),
                ],
              }),
            )
            .timeout(const Duration(minutes: 2));
      }

      if (response.statusCode != 200) {
        return {
          'response': 'Ollama Error: ${response.statusCode} ${response.body}'
              .trim(),
          'tool_call': null,
        };
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final message = data['message'] as Map<String, dynamic>? ?? {};
      final toolCalls = message['tool_calls'] as List<dynamic>? ?? [];
      final content = message['content'] as String? ?? '';

      if (toolCalls.isNotEmpty) {
        final function =
            (toolCalls.first as Map<String, dynamic>)['function']
                as Map<String, dynamic>;
        return {
          'response': content,
          'tool_call': {
            'name': function['name'],
            'arguments': function['arguments'],
          },
        };
      }

      // Fallback for Gemma and Ollama models returning structured tool calls in content
      final extracted = _extractToolCallFromContent(content);
      if (extracted != null) {
        return {
          'response': content,
          'tool_call': extracted,
        };
      }

      return {
        'response': content,
        'tool_call': null,
      };
    } catch (error) {
      final browserHelp = kIsWeb
          ? ' If running in Chrome, allow the web origin in Ollama with '
                'OLLAMA_ORIGINS, or use the native app.'
          : '';
      return {
        'response':
            'Ollama connection error: $error.$browserHelp '
            'If using Android, ensure OLLAMA_HOST=0.0.0.0 is set on your PC '
            'and use the PC LAN IP on a physical phone, or '
            'http://10.0.2.2:11434 on the emulator.',
        'tool_call': null,
      };
    }
  }

  Future<Map<String, dynamic>> _processWithAnthropic(
    String text,
    List<Map<String, String>> history,
    bool allowTools,
    String systemPrompt,
  ) async {
    final apiKey = await getApiKey(provider: LLMProvider.anthropic);
    if (apiKey == null || apiKey.isEmpty) {
      return {
        'response': 'Please configure your API key in settings.',
        'tool_call': null,
      };
    }

    try {
      final response = await _client
          .post(
            Uri.parse(_anthropicUrl),
            headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'model': await _resolveModel(LLMProvider.anthropic),
              'max_tokens': 1024,
              'system': systemPrompt,
              'messages': _turns(text, history),
              if (allowTools)
                'tools': _tools
                    .map(
                      (tool) => {
                        'name': tool['function']['name'],
                        'description': tool['function']['description'],
                        'input_schema': tool['function']['parameters'],
                      },
                    )
                    .toList(),
            }),
          )
          .timeout(const Duration(minutes: 2));

      if (response.statusCode != 200) {
        return {
          'response':
              'Anthropic error ${response.statusCode}: '
              '${_safeErrorBody(response.body)}',
          'tool_call': null,
        };
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final content = data['content'] as List<dynamic>? ?? [];
      final toolUse = content.whereType<Map<String, dynamic>>().where(
        (item) => item['type'] == 'tool_use',
      );
      if (toolUse.isNotEmpty) {
        final call = toolUse.first;
        return {
          'response': content
              .whereType<Map<String, dynamic>>()
              .where((item) => item['type'] == 'text')
              .map((item) => item['text'] as String? ?? '')
              .join(),
          'tool_call': {'name': call['name'], 'arguments': call['input']},
        };
      }
      return {
        'response': content
            .whereType<Map<String, dynamic>>()
            .where((item) => item['type'] == 'text')
            .map((item) => item['text'] as String? ?? '')
            .join(),
        'tool_call': null,
      };
    } catch (error) {
      return {'response': 'Connection error: $error', 'tool_call': null};
    }
  }

  Future<Map<String, dynamic>> _processWithOpenAiCompatible(
    String text,
    LLMProvider provider,
    List<Map<String, String>> history,
    bool allowTools,
    String systemPrompt,
  ) async {
    final apiKey = await getApiKey(provider: provider);
    if (apiKey == null || apiKey.isEmpty) {
      return {
        'response': 'Add a ${provider.displayName} API key in Settings.',
        'tool_call': null,
      };
    }
    final baseUrl = switch (provider) {
      LLMProvider.openAi => 'https://api.openai.com/v1',
      LLMProvider.groq => 'https://api.groq.com/openai/v1',
      LLMProvider.openRouter => 'https://openrouter.ai/api/v1',
      _ => throw ArgumentError.value(provider, 'provider'),
    };
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    if (provider == LLMProvider.openRouter) {
      headers['HTTP-Referer'] = 'https://jarvis.local';
      headers['X-Title'] = 'Jarvis Assistant';
    }
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: headers,
            body: jsonEncode({
              'model': await _resolveModel(provider),
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                ..._turns(text, history),
              ],
              if (allowTools) 'tools': _openAiTools,
              if (allowTools) 'tool_choice': 'auto',
            }),
          )
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) {
        return {
          'response': _providerError(
            provider,
            response.statusCode,
            response.body,
          ),
          'tool_call': null,
        };
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final message =
          ((data['choices'] as List<dynamic>).first
                  as Map<String, dynamic>)['message']
              as Map<String, dynamic>;
      final toolCalls = message['tool_calls'] as List<dynamic>? ?? [];
      if (toolCalls.isNotEmpty) {
        final call =
            (toolCalls.first as Map<String, dynamic>)['function']
                as Map<String, dynamic>;
        return {
          'response': message['content'] as String? ?? '',
          'tool_call': {
            'name': call['name'],
            'arguments': jsonDecode(call['arguments'] as String),
          },
        };
      }
      return {
        'response': message['content'] as String? ?? '',
        'tool_call': null,
      };
    } catch (error) {
      return {'response': _connectionError(provider, error), 'tool_call': null};
    }
  }

  Future<Map<String, dynamic>> _processWithGemini(
    String text,
    List<Map<String, String>> history,
    bool allowTools,
    String systemPrompt,
  ) async {
    final apiKey = await getApiKey(provider: LLMProvider.gemini);
    if (apiKey == null || apiKey.isEmpty) {
      return {
        'response': 'Add a Google Gemini API key in Settings.',
        'tool_call': null,
      };
    }
    try {
      var model = await _resolveModel(LLMProvider.gemini);
      var response = await _sendGeminiRequest(
        model: model,
        apiKey: apiKey,
        text: text,
        history: history,
        allowTools: allowTools,
        systemPrompt: systemPrompt,
      );
      final errorBody = response.body.toLowerCase();
      if (response.statusCode == 404 &&
          errorBody.contains('model') &&
          (errorBody.contains('not found') ||
              errorBody.contains('no longer available'))) {
        model = await discoverAndSaveModel(LLMProvider.gemini);
        response = await _sendGeminiRequest(
          model: model,
          apiKey: apiKey,
          text: text,
          history: history,
          allowTools: allowTools,
          systemPrompt: systemPrompt,
        );
      }
      if (response.statusCode != 200) {
        return {
          'response': _providerError(
            LLMProvider.gemini,
            response.statusCode,
            response.body,
          ),
          'tool_call': null,
        };
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final parts =
          (((data['candidates'] as List<dynamic>).first
                      as Map<String, dynamic>)['content']
                  as Map<String, dynamic>)['parts']
              as List<dynamic>;
      for (final item in parts) {
        final part = item as Map<String, dynamic>;
        final call = part['functionCall'] as Map<String, dynamic>?;
        if (call != null) {
          return {
            'response': '',
            'tool_call': {
              'name': call['name'],
              'arguments': call['args'] as Map<String, dynamic>? ?? {},
            },
          };
        }
      }
      return {
        'response': parts
            .map(
              (part) => (part as Map<String, dynamic>)['text'] as String? ?? '',
            )
            .join(),
        'tool_call': null,
      };
    } catch (error) {
      return {
        'response': _connectionError(LLMProvider.gemini, error),
        'tool_call': null,
      };
    }
  }

  Future<http.Response> _sendGeminiRequest({
    required String model,
    required String apiKey,
    required String text,
    required List<Map<String, String>> history,
    required bool allowTools,
    required String systemPrompt,
  }) => _client
      .post(
        Uri.https(
          'generativelanguage.googleapis.com',
          '/v1beta/models/$model:generateContent',
          {'key': apiKey},
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': systemPrompt},
            ],
          },
          'contents': _turns(text, history)
              .map(
                (turn) => {
                  'role': turn['role'] == 'assistant' ? 'model' : 'user',
                  'parts': [
                    {'text': turn['content']},
                  ],
                },
              )
              .toList(),
          if (allowTools)
            'tools': [
              {'functionDeclarations': _geminiTools},
            ],
        }),
      )
      .timeout(const Duration(minutes: 2));

  String _connectionError(LLMProvider provider, Object error) {
    final message = error.toString();
    if (message.contains('Failed host lookup') ||
        message.contains('No address associated with hostname')) {
      return '${provider.displayName} could not resolve its server address. '
          'Check the phone internet connection, disable VPN/private DNS '
          'temporarily, and try again.';
    }
    return '${provider.displayName} network request failed: $message';
  }

  String _providerError(LLMProvider provider, int statusCode, String body) {
    final detail = _safeErrorBody(body);
    final normalized = detail.toLowerCase();
    if (statusCode == 429 &&
        (normalized.contains('insufficient_quota') ||
            normalized.contains('credit') ||
            normalized.contains('billing'))) {
      final billingUrl = switch (provider) {
        LLMProvider.openAi =>
          'https://platform.openai.com/settings/organization/billing',
        LLMProvider.anthropic =>
          'https://console.anthropic.com/settings/billing',
        LLMProvider.gemini => 'https://aistudio.google.com/',
        LLMProvider.groq => 'https://console.groq.com/settings/billing',
        LLMProvider.openRouter => 'https://openrouter.ai/settings/credits',
        LLMProvider.ollama => '',
      };
      return '${provider.displayName} has no API credits/quota available. '
          'Add billing or credits in that provider account, then retry. '
          'This is an account quota issue, not a model-name issue. Details: '
          '$detail${billingUrl.isEmpty ? '' : ' Billing: $billingUrl'}';
    }
    if (provider == LLMProvider.gemini &&
        statusCode == 404 &&
        (normalized.contains('not found') ||
            normalized.contains('no longer available'))) {
      return 'Google Gemini rejected the selected model ($detail). Jarvis '
          'tried refreshing the retired model automatically. Use “Check key '
          '& choose model” in Settings if the issue continues.';
    }
    return '${provider.displayName} error $statusCode: $detail';
  }

  Uri _ollamaUri(String baseUrl, String path) {
    final normalized = _normalizeBaseUrl(baseUrl);
    final uri = Uri.parse(normalized);
    return uri.replace(path: '${uri.path}$path');
  }

  String _normalizeBaseUrl(String url) {
    final trimmed = url.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw FormatException(
        'Enter a valid Ollama URL beginning with http:// or https://.',
      );
    }
    return trimmed;
  }

  static List<Map<String, dynamic>> get _tools => ToolRegistry().toToolSchemas();

  static Map<String, dynamic>? _extractToolCallFromContent(String content) {
    if (content.trim().isEmpty) return null;
    try {
      final match = RegExp(r'```(?:json)?\s*(\{.*?\})\s*```', dotAll: true).firstMatch(content);
      Map<String, dynamic>? candidate;
      if (match != null) {
        final raw = match.group(1);
        if (raw != null) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) candidate = decoded;
        }
      }

      if (candidate == null) {
        final start = content.indexOf('{');
        final end = content.lastIndexOf('}');
        if (start >= 0 && end > start) {
          final raw = content.substring(start, end + 1);
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) candidate = decoded;
        }
      }

      if (candidate != null) {
        final toolName = candidate['tool'] ?? candidate['name'] ?? candidate['action'];
        final args = candidate['arguments'] ?? candidate['parameters'] ?? candidate['args'];
        if (toolName is String && toolName.isNotEmpty && toolName != 'none') {
          return {
            'name': toolName,
            'arguments': args is Map ? Map<String, dynamic>.from(args) : <String, dynamic>{},
          };
        }
      }
    } catch (_) {}
    return null;
  }

  static List<Map<String, dynamic>> get _openAiTools => _tools
      .map(
        (tool) => {
          'type': 'function',
          'function': {
            'name': tool['function']['name'],
            'description': tool['function']['description'],
            'parameters': tool['function']['parameters'],
          },
        },
      )
      .toList();

  static List<Map<String, dynamic>> get _geminiTools => _tools
      .map(
        (tool) => {
          'name': tool['function']['name'],
          'description': tool['function']['description'],
          'parameters': tool['function']['parameters'],
        },
      )
      .toList();

  /// Transcribes a local WAV audio file using the configured provider's
  /// audio model (Groq Whisper, OpenAI Whisper, or Google Gemini).
  Future<String> transcribeAudioFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      return '';
    }

    final provider = await getProvider();
    final apiKey = await getApiKey(provider: provider);

    // 1. If Groq: use Groq Whisper API
    if (provider == LLMProvider.groq && apiKey != null && apiKey.isNotEmpty) {
      return await _transcribeGroq(file, apiKey);
    }

    // 2. If OpenAI: use OpenAI Whisper API
    if (provider == LLMProvider.openAi && apiKey != null && apiKey.isNotEmpty) {
      return await _transcribeOpenAi(file, apiKey);
    }

    // 3. If Gemini: use Gemini multimodal inline audio
    if (provider == LLMProvider.gemini && apiKey != null && apiKey.isNotEmpty) {
      return await _transcribeGemini(file, apiKey);
    }

    // 4. Try any configured provider with Whisper / audio capability
    for (final p in [LLMProvider.groq, LLMProvider.openAi, LLMProvider.gemini]) {
      final key = await getApiKey(provider: p);
      if (key != null && key.isNotEmpty) {
        if (p == LLMProvider.groq) return await _transcribeGroq(file, key);
        if (p == LLMProvider.openAi) return await _transcribeOpenAi(file, key);
        if (p == LLMProvider.gemini) return await _transcribeGemini(file, key);
      }
    }

    // 5. Try build-time key fallback
    if (_buildTimeApiKey.isNotEmpty) {
      if (_buildTimeApiKey.startsWith('gsk_')) {
        return await _transcribeGroq(file, _buildTimeApiKey);
      }
      if (_buildTimeApiKey.startsWith('sk-')) {
        return await _transcribeOpenAi(file, _buildTimeApiKey);
      }
      if (_buildTimeApiKey.startsWith('AIza')) {
        return await _transcribeGemini(file, _buildTimeApiKey);
      }
    }

    // 6. Local Python SpeechRecognition fallback if installed
    try {
      final pyRes = await Process.run('python3', [
        '-c',
        '''
try:
    import speech_recognition as sr
    r = sr.Recognizer()
    with sr.AudioFile('$filePath') as source:
        audio = r.record(source)
        text = r.recognize_google(audio)
        print(text)
except Exception:
    pass
''',
      ]);
      final out = pyRes.stdout.toString().trim();
      if (out.isNotEmpty) return out;
    } catch (_) {}

    throw Exception(
      'To use voice input on Linux, add an API key for Google Gemini, Groq, or OpenAI in Settings, or use text input.',
    );
  }

  Future<String> _transcribeGroq(File file, String apiKey) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'),
    );
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = 'whisper-large-v3-turbo';
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamed =
        await _client.send(request).timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['text'] as String? ?? '').trim();
    }
    throw Exception('Groq transcription error: ${response.statusCode}');
  }

  Future<String> _transcribeOpenAi(File file, String apiKey) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
    );
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = 'whisper-1';
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamed =
        await _client.send(request).timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['text'] as String? ?? '').trim();
    }
    throw Exception('OpenAI transcription error: ${response.statusCode}');
  }

  Future<String> _transcribeGemini(File file, String apiKey) async {
    final bytes = await file.readAsBytes();
    final base64Audio = base64Encode(bytes);
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey',
    );
    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text':
                  'Transcribe the following speech audio into plain text. Only output the transcribed text, without explanation, timestamps, or quotes.',
            },
            {
              'inline_data': {
                'mime_type': 'audio/wav',
                'data': base64Audio,
              },
            },
          ],
        },
      ],
    };

    final response = await _client
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;
      if (candidates != null && candidates.isNotEmpty) {
        final content = candidates[0]['content'] as Map<String, dynamic>?;
        final parts = content?['parts'] as List?;
        if (parts != null && parts.isNotEmpty) {
          return (parts[0]['text'] as String? ?? '').trim();
        }
      }
      return '';
    }
    throw Exception('Gemini transcription error: ${response.statusCode}');
  }

  /// Processes and analyzes an image or media file using multimodal capabilities.
  /// Works offline with Ollama (e.g. qwen3.5:4b, llama3.2-vision, llava) or via cloud vision providers.
  Future<String> processMedia({
    required String prompt,
    required String mediaPath,
    String? mimeType,
  }) async {
    final file = File(mediaPath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw ArgumentError('Media file does not exist at: $mediaPath');
    }

    final bytes = await file.readAsBytes();
    final base64Media = base64Encode(bytes);
    final effectiveMime = mimeType ?? _guessMimeType(mediaPath);

    final provider = await getProvider();
    final apiKey = await getApiKey(provider: provider);

    // 1. Ollama local offline
    if (provider == LLMProvider.ollama) {
      return await _processMediaOllama(prompt, base64Media);
    }

    // 2. Google Gemini
    if (provider == LLMProvider.gemini && apiKey != null && apiKey.isNotEmpty) {
      return await _processMediaGemini(prompt, base64Media, effectiveMime, apiKey);
    }

    // 3. OpenAI / OpenRouter
    if ((provider == LLMProvider.openAi || provider == LLMProvider.openRouter) &&
        apiKey != null &&
        apiKey.isNotEmpty) {
      return await _processMediaOpenAi(prompt, base64Media, effectiveMime, apiKey, provider);
    }

    // 4. Anthropic
    if (provider == LLMProvider.anthropic && apiKey != null && apiKey.isNotEmpty) {
      return await _processMediaAnthropic(prompt, base64Media, effectiveMime, apiKey);
    }

    // Fallback: try Ollama if accessible, then Gemini
    try {
      return await _processMediaOllama(prompt, base64Media);
    } catch (_) {}

    final geminiKey = await getApiKey(provider: LLMProvider.gemini);
    if (geminiKey != null && geminiKey.isNotEmpty) {
      return await _processMediaGemini(prompt, base64Media, effectiveMime, geminiKey);
    }

    throw StateError(
      'To process media, use Ollama with a local vision model (such as qwen3.5:4b or llama3.2-vision) or configure Google Gemini in Settings.',
    );
  }

  Future<String> _processMediaOllama(String prompt, String base64Image) async {
    final baseUrl = await getOllamaBaseUrl();
    String model = await getOllamaModel();
    try {
      final models = await listOllamaModels(baseUrl: baseUrl);
      for (final v in ['qwen3.5:4b', 'llama3.2-vision', 'llava', 'minicpm-v', 'bakllava']) {
        final match = models.firstWhere((m) => m.toLowerCase().contains(v), orElse: () => '');
        if (match.isNotEmpty) {
          model = match;
          break;
        }
      }
    } catch (_) {}

    final response = await _client.post(
      _ollamaUri(baseUrl, '/api/chat'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'stream': false,
        'messages': [
          {
            'role': 'user',
            'content': prompt.trim().isEmpty
                ? 'Describe this image in detail and extract any visible text.'
                : prompt,
            'images': [base64Image],
          },
        ],
      }),
    ).timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw Exception('Ollama media processing error (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final message = data['message'] as Map<String, dynamic>? ?? {};
    return (message['content'] as String? ?? '').trim();
  }

  Future<String> _processMediaGemini(
    String prompt,
    String base64Image,
    String mimeType,
    String apiKey,
  ) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
    );
    final response = await _client.post(
      url,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'text': prompt.trim().isEmpty
                    ? 'Describe this media in detail and extract all key information.'
                    : prompt,
              },
              {
                'inline_data': {
                  'mime_type': mimeType,
                  'data': base64Image,
                },
              },
            ],
          },
        ],
      }),
    ).timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw Exception('Gemini media processing error: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List<dynamic>? ?? [];
    if (candidates.isNotEmpty) {
      final content = candidates.first['content'] as Map<String, dynamic>? ?? {};
      final parts = content['parts'] as List<dynamic>? ?? [];
      return parts.map((p) => p['text'] as String? ?? '').join().trim();
    }
    return '';
  }

  Future<String> _processMediaOpenAi(
    String prompt,
    String base64Image,
    String mimeType,
    String apiKey,
    LLMProvider provider,
  ) async {
    final baseUrl = provider == LLMProvider.openRouter
        ? 'https://openrouter.ai/api/v1/chat/completions'
        : 'https://api.openai.com/v1/chat/completions';
    final model = provider == LLMProvider.openRouter ? 'openai/gpt-4o-mini' : 'gpt-4o-mini';

    final response = await _client.post(
      Uri.parse(baseUrl),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': prompt.trim().isEmpty ? 'Describe this image in detail.' : prompt,
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'data:$mimeType;base64,$base64Image'},
              },
            ],
          },
        ],
      }),
    ).timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw Exception('OpenAI media processing error: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>? ?? [];
    if (choices.isNotEmpty) {
      final msg = choices.first['message'] as Map<String, dynamic>? ?? {};
      return (msg['content'] as String? ?? '').trim();
    }
    return '';
  }

  Future<String> _processMediaAnthropic(
    String prompt,
    String base64Image,
    String mimeType,
    String apiKey,
  ) async {
    final response = await _client.post(
      Uri.parse(_anthropicUrl),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': 'claude-3-5-sonnet-20241022',
        'max_tokens': 1024,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': mimeType,
                  'data': base64Image,
                },
              },
              {
                'type': 'text',
                'text': prompt.trim().isEmpty ? 'Describe this image in detail.' : prompt,
              },
            ],
          },
        ],
      }),
    ).timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw Exception('Anthropic media processing error: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = data['content'] as List<dynamic>? ?? [];
    return content
        .whereType<Map<String, dynamic>>()
        .where((i) => i['type'] == 'text')
        .map((i) => i['text'] as String? ?? '')
        .join()
        .trim();
  }

  String _guessMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mp3';
    return 'image/jpeg';
  }
}

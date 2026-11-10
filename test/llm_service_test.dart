import 'dart:convert';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test_app/services/llm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  test(
    'personalizes the local model prompt with the saved user name',
    () async {
      late http.Request request;
      final service = LLMService(
        client: MockClient((value) async {
          request = value;
          return http.Response(
            jsonEncode({
              'message': {'content': 'Hello Sam.', 'role': 'assistant'},
            }),
            200,
          );
        }),
      );
      await service.setProvider(LLMProvider.ollama);
      await service.setUserName('Sam');

      await service.processCommand('Hello', allowTools: false);

      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      final messages = payload['messages'] as List<dynamic>;
      expect(messages.first['content'], contains('Address the user as Sam'));
      expect(await service.getUserName(), 'Sam');
    },
  );

  test(
    'discovers an accessible chat model using the saved provider key',
    () async {
      late http.Request receivedRequest;
      final service = LLMService(
        client: MockClient((request) async {
          receivedRequest = request;
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'text-embedding-3-small'},
                {'id': 'gpt-4o-mini'},
                {'id': 'gpt-4o'},
              ],
            }),
            200,
          );
        }),
      );
      await service.setProviderApiKey(LLMProvider.openAi, 'test-key');

      final selected = await service.discoverAndSaveModel(LLMProvider.openAi);

      expect(receivedRequest.url.path, '/v1/models');
      expect(receivedRequest.headers['authorization'], 'Bearer test-key');
      expect(selected, 'gpt-4o-mini');
      expect(
        await service.getConfiguredModel(provider: LLMProvider.openAi),
        'gpt-4o-mini',
      );
    },
  );

  test(
    'uses a provider default model without requiring model-list access',
    () async {
      late http.Request receivedRequest;
      final service = LLMService(
        client: MockClient((request) async {
          receivedRequest = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Ready.', 'role': 'assistant'},
                },
              ],
            }),
            200,
          );
        }),
      );
      await service.setProvider(LLMProvider.openAi);
      await service.setProviderApiKey(LLMProvider.openAi, 'test-key');

      final result = await service.processCommand('Hello');
      final payload = jsonDecode(receivedRequest.body) as Map<String, dynamic>;

      expect(receivedRequest.url.path, '/v1/chat/completions');
      expect(payload['model'], 'gpt-4o-mini');
      expect(receivedRequest.headers['authorization'], 'Bearer test-key');
      expect(result['response'], 'Ready.');
    },
  );

  test(
    'streams Ollama model-pull progress and reports server errors',
    () async {
      final progress = <OllamaPullProgress>[];
      final service = LLMService(
        client: MockClient((request) async {
          expect(request.url.path, '/api/pull');
          return http.Response(
            '{"status":"downloading","completed":5,"total":10}\n'
            '{"status":"success"}\n',
            200,
          );
        }),
      );

      await service.pullOllamaModel(
        model: 'llama3.2',
        baseUrl: 'http://localhost:11434',
        onProgress: progress.add,
      );

      expect(progress, hasLength(2));
      expect(progress.first.fraction, 0.5);
      expect(progress.last.status, 'success');

      final failingService = LLMService(
        client: MockClient(
          (_) async => http.Response('{"error":"model not found"}', 404),
        ),
      );
      await expectLater(
        failingService.pullOllamaModel(
          model: 'not-a-model',
          baseUrl: 'http://localhost:11434',
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('model not found'),
          ),
        ),
      );
    },
  );

  test('replaces a retired saved Gemini model and retries once', () async {
    final requestedModels = <String>[];
    final service = LLMService(
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'name': 'models/gemini-3.8-flash',
                  'supportedGenerationMethods': ['generateContent'],
                },
              ],
            }),
            200,
          );
        }
        final model = request.url.path
            .split('/v1beta/models/')
            .last
            .split(':')
            .first;
        requestedModels.add(model);
        if (model == 'gemini-2.0-flash') {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 404,
                'message': 'This model is no longer available.',
              },
            }),
            404,
          );
        }
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Ready.'},
                  ],
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    await service.setProvider(LLMProvider.gemini);
    await service.setProviderApiKey(LLMProvider.gemini, 'test-key');
    await service.setModel('gemini-2.0-flash', provider: LLMProvider.gemini);

    final result = await service.processCommand('Hello');

    expect(requestedModels, ['gemini-2.0-flash', 'gemini-3.8-flash']);
    expect(result['response'], 'Ready.');
    expect(
      await service.getConfiguredModel(provider: LLMProvider.gemini),
      'gemini-3.8-flash',
    );
  });

  test(
    'explains OpenAI exhausted credits as billing rather than model error',
    () async {
      final service = LLMService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'message': 'You have no credits remaining.',
                'type': 'insufficient_quota',
                'code': 'credit_balance_exhausted',
              },
            }),
            429,
          ),
        ),
      );
      await service.setProvider(LLMProvider.openAi);
      await service.setProviderApiKey(LLMProvider.openAi, 'test-key');

      final result = await service.processCommand('Hello');

      expect(
        result['response'],
        contains('account quota issue, not a model-name issue'),
      );
      expect(result['response'], contains('Add billing or credits'));
    },
  );
}

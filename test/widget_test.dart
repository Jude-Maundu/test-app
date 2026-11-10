import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/ui/pages/assistant_home.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  testWidgets('Jarvis home provides voice and text controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AssistantProvider(),
        child: const MaterialApp(home: AssistantHomePage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Jarvis'), findsOneWidget);
    expect(find.text('Hello, Jude. I’m ready when you are.'), findsOneWidget);
    expect(find.bySemanticsLabel('Start listening'), findsOneWidget);
    expect(find.byTooltip('Send message'), findsOneWidget);
    expect(find.byTooltip('Chat history'), findsOneWidget);
  });
}

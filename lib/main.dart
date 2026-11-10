import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/ui/pages/assistant_home.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The UI is dark everywhere, so keep the status and navigation bars
  // transparent with light icons.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Jv.space,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final assistantProvider = AssistantProvider();
  await assistantProvider.init();

  runApp(
    MultiProvider(
      providers: [
        // `create` (rather than `.value`) lets Provider call dispose() on it.
        ChangeNotifierProvider<AssistantProvider>(
          create: (_) => assistantProvider,
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis',
      debugShowCheckedModeBanner: false,
      theme: Jv.theme,
      darkTheme: Jv.theme,
      themeMode: ThemeMode.dark,
      home: const AssistantHomePage(),
    );
  }
}
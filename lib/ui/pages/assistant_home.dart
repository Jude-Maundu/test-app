import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/services/llm_service.dart';
import 'package:test_app/services/permission_manager.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/services/task_execution_service.dart';
import 'package:test_app/services/task_orchestrator.dart';
import 'package:test_app/skills/command_router.dart';
import 'package:test_app/skills/skill_base.dart';
import 'package:test_app/ui/pages/onboarding_page.dart';
import 'package:url_launcher/url_launcher.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens
// ─────────────────────────────────────────────────────────────────────────────

class Jv {
  Jv._();

  static const Color space = Color(0xFF05070F);
  static const Color deep = Color(0xFF0A1022);
  static const Color panel = Color(0xFF0F1730);

  static const Color ice = Color(0xFF5CE1E6); // listening / primary
  static const Color violet = Color(0xFF8B7BFF); // thinking
  static const Color amber = Color(0xFFFFB86B); // speaking
  static const Color slate = Color(0xFF5B6784); // idle

  static const Color text = Color(0xFFE8EEFF);
  static const Color textMuted = Color(0xFF8E9BBD);

  static Color hairline([double a = 0.10]) => Colors.white.withValues(alpha: a);

  static ThemeData get theme => ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: space,
    colorScheme: const ColorScheme.dark(
      primary: ice,
      onPrimary: space,
      secondary: violet,
      surface: deep,
      onSurface: text,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: ice,
        foregroundColor: space,
        disabledBackgroundColor: Colors.white.withValues(alpha: 0.07),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.3),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        disabledForegroundColor: Colors.white.withValues(alpha: 0.3),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}

InputDecoration _fieldDecoration({
  required String label,
  String? hint,
  IconData? icon,
}) {
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: const TextStyle(color: Jv.textMuted),
    hintStyle: TextStyle(color: Jv.textMuted.withValues(alpha: 0.5)),
    prefixIcon: icon == null ? null : Icon(icon, size: 20, color: Jv.textMuted),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.04),
    border: border(Jv.hairline(0.14)),
    enabledBorder: border(Jv.hairline(0.14)),
    focusedBorder: border(Jv.ice, 1.5),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Home page
// ─────────────────────────────────────────────────────────────────────────────

class AssistantHomePage extends StatefulWidget {
  const AssistantHomePage({super.key});

  @override
  State<AssistantHomePage> createState() => _AssistantHomePageState();
}

class _AssistantHomePageState extends State<AssistantHomePage>
    with SingleTickerProviderStateMixin {
  final LLMService _llm = LLMService();
  final PermissionManager _permissionManager = PermissionManager();
  final TextEditingController _textInputController = TextEditingController();
  final List<Map<String, String>> _conversationHistory = [];
  String _userName = 'Jude';
  String? _attachedMediaPath;

  late final TaskExecutionService _taskExecutionService = TaskExecutionService();
  late final TaskOrchestrator _orchestrator;
  late final CommandRouter _commandRouter;

  // Orb animation: a manually advanced phase lets the speed ease between
  // states instead of jumping when the assistant changes state.
  late final Ticker _ticker;
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);
  Duration _lastTick = Duration.zero;
  double _speed = 1;
  double _targetSpeed = 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _loadConversation();
    _loadUserName();

    final assistant = Provider.of<AssistantProvider>(context, listen: false);
    _orchestrator = TaskOrchestrator(
      llmService: _llm,
      taskExecutionService: _taskExecutionService,
      assistantProvider: assistant,
      permissionManager: _permissionManager,
      onNavigate: _handleInternalNavigation,
    )..addListener(_onOrchestratorUpdate);

    _commandRouter = CommandRouter(
      context: SkillContext(
        userName: _userName,
        conversationHistory: _conversationHistory,
      ),
      llmService: _llm,
    );

    PlatformService.setOnBackgroundCommand((command) {
      if (mounted) {
        final currentAssistant = Provider.of<AssistantProvider>(context, listen: false);
        _processUserCommand(command, currentAssistant);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 1. Check first-time onboarding customization
      final completed = await _permissionManager.hasCompletedOnboarding();
      if (!completed && mounted) {
        await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => OnboardingWizardPage(
              assistantProvider: Provider.of<AssistantProvider>(context, listen: false),
            ),
          ),
        );
        _loadUserName();
      }

      // 2. Check pending background command
      final pending = await PlatformService.getPendingCommand();
      if (pending != null && pending.trim().isNotEmpty && mounted) {
        final currentAssistant = Provider.of<AssistantProvider>(context, listen: false);
        _processUserCommand(pending.trim(), currentAssistant);
      }
    });
  }

  Future<void> _loadUserName() async {
    final userName = await _llm.getUserName();
    if (mounted) setState(() => _userName = userName);
    _commandRouter.context.userName = userName;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final assistant = Provider.of<AssistantProvider>(context, listen: false);
      try {
        await assistant.speak('Hello, $userName. Jarvis is ready.');
      } on MissingPluginException {
        // Flutter test hosts may not include a text-to-speech plugin.
      }
    });
  }

  void _showMediaAttachmentDialog() {
    final controller = TextEditingController(text: _attachedMediaPath ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Jv.panel,
        title: const Row(
          children: [
            Icon(Icons.attachment_rounded, color: Jv.ice),
            SizedBox(width: 8),
            Text('Attach Media / Image'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the path to an image or media file on this device for Jarvis to inspect and process:',
              style: TextStyle(fontSize: 13, color: Jv.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: _fieldDecoration(
                label: 'File Path',
                hint: '/path/to/media.jpg',
                icon: Icons.insert_drive_file_outlined,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final path = controller.text.trim();
              if (path.isNotEmpty) {
                setState(() => _attachedMediaPath = path);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Attach'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final savedName = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (savedName != null && mounted) {
      setState(() => _userName = savedName.isEmpty ? 'Jude' : savedName);
    }
  }

  Future<void> _loadConversation() async {
    final history = await _llm.getConversationHistory();
    if (mounted) setState(() => _conversationHistory.addAll(history));
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _speed += (_targetSpeed - _speed) * math.min(1.0, dt * 3);
    _phase.value += dt * _speed;
  }

  void _onOrchestratorUpdate() {
    if (mounted) setState(() {});
  }

  void _handleInternalNavigation(String screen) {
    if (!mounted) return;
    switch (screen.toLowerCase()) {
      case 'settings':
        _openSettings();
        break;
      case 'notes':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NotesPage()),
        );
        break;
      case 'history':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ConversationHistoryPage(
              history: List.unmodifiable(_conversationHistory),
            ),
          ),
        );
        break;
      case 'activity_log':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ActivityLogPage(service: _llm),
          ),
        );
        break;
      case 'tasks':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TasksHistoryPage(service: _taskExecutionService),
          ),
        );
        break;
    }
  }

  @override
  void dispose() {
    _orchestrator.removeListener(_onOrchestratorUpdate);
    _orchestrator.dispose();
    _ticker.dispose();
    _phase.dispose();
    _textInputController.dispose();
    super.dispose();
  }

  Color _colorFor(AssistantState s) => switch (s) {
    AssistantState.idle => Jv.slate,
    AssistantState.listening => Jv.ice,
    AssistantState.thinking => Jv.violet,
    AssistantState.speaking => Jv.amber,
  };

  String _labelFor(AssistantState s) => switch (s) {
    AssistantState.idle => 'Idle',
    AssistantState.listening => 'Listening…',
    AssistantState.thinking => 'Thinking…',
    AssistantState.speaking => 'Speaking…',
  };

  double _speedFor(AssistantState s) => switch (s) {
    AssistantState.idle => 0.45,
    AssistantState.listening => 1.0,
    AssistantState.thinking => 3.2,
    AssistantState.speaking => 1.4,
  };

  Future<void> _toggleListening(AssistantProvider assistant) async {
    if (assistant.isListening) {
      HapticFeedback.selectionClick();
      assistant.stopListening();
      return;
    }
    HapticFeedback.mediumImpact();
    await assistant.startListening((command) async {
      await _processUserCommand(command, assistant);
    });
  }

  Future<void> _processUserCommand(
    String command,
    AssistantProvider assistant,
  ) async {
    final text = command.trim();
    if (text.isEmpty && _attachedMediaPath == null) return;
    assistant.setState(AssistantState.thinking);

    final mediaPath = _attachedMediaPath;
    setState(() => _attachedMediaPath = null);

    try {
      final String outcome;
      if (mediaPath != null) {
        outcome = await _llm.processMedia(
          prompt: text.isEmpty
              ? 'Analyze and describe this media in detail and extract all text.'
              : text,
          mediaPath: mediaPath,
        );
      } else {
        // Fast-path through the modular CommandRouter:
        // Handles wake words, short-term memory (e.g. "play it again"), and direct skills
        // (music, time, weather, open apps, calls, reminders).
        // If no skill matches, falls back to the autonomous TaskOrchestrator and LLM API.
        _commandRouter.context.userName = _userName;
        final skillResult = await _commandRouter.route(
          text,
          customLlmFallback: (instruction) async {
            final task = await _orchestrator.executeInstruction(
              instruction,
              conversationHistory: List.unmodifiable(_conversationHistory),
            );
            return task.result ?? task.error ?? 'Task completed, $_userName.';
          },
        );
        outcome = skillResult.speechResponse;
      }

      final displayTurn = mediaPath != null ? '[Media: ${mediaPath.split("/").last}] $text' : text;
      _conversationHistory
        ..add({'role': 'user', 'content': displayTurn})
        ..add({'role': 'assistant', 'content': outcome});
      if (_conversationHistory.length > 20) {
        _conversationHistory.removeRange(0, _conversationHistory.length - 20);
      }
      await _llm.saveConversationHistory(_conversationHistory);
      await _llm.recordActivity('$displayTurn — $outcome');

      await assistant.speak(outcome);
    } catch (error) {
      final errorMsg = "Could not complete task: $error";
      _conversationHistory
        ..add({'role': 'user', 'content': text})
        ..add({'role': 'assistant', 'content': errorMsg});
      await assistant.speak(errorMsg);
    }
  }



  @override
  Widget build(BuildContext context) {
    final assistant = Provider.of<AssistantProvider>(context);
    final target = _colorFor(assistant.state);
    _targetSpeed = _speedFor(assistant.state);

    return Theme(
      data: Jv.theme,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: target),
        duration: const Duration(milliseconds: 600),
        builder: (context, animated, _) {
          final color = animated ?? target;
          return Scaffold(
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              centerTitle: true,
              title: const Text(
                'Jarvis',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 6,
                  color: Jv.text,
                ),
              ),
              actions: [
                IconButton(
                  tooltip: 'Tasks',
                  icon: const Icon(Icons.task_alt_rounded, color: Jv.textMuted),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TasksHistoryPage(service: _taskExecutionService),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Chat history',
                  icon: const Icon(Icons.history_rounded, color: Jv.textMuted),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ConversationHistoryPage(
                        history: List.unmodifiable(_conversationHistory),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Saved notes',
                  icon: const Icon(
                    Icons.note_alt_outlined,
                    color: Jv.textMuted,
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NotesPage()),
                  ),
                ),
                IconButton(
                  tooltip: 'Activity log',
                  icon: const Icon(
                    Icons.history_toggle_off_rounded,
                    color: Jv.textMuted,
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ActivityLogPage(service: _llm),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.tune_rounded, color: Jv.textMuted),
                  onPressed: _openSettings,
                ),
              ],
            ),
            body: Stack(
              fit: StackFit.expand,
              children: [
                _Backdrop(color: color),
                SafeArea(
                  child: Column(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final size = math
                                .min(
                                  math.min(
                                    box.maxWidth * 0.82,
                                    box.maxHeight - 112,
                                  ),
                                  340.0,
                                )
                                .clamp(160.0, 340.0)
                                .toDouble();
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Hello, $_userName. I’m ready when you are.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Jv.textMuted,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox.square(
                                    dimension: size,
                                    child: RepaintBoundary(
                                      child: CustomPaint(
                                        painter: _CorePainter(
                                          phase: _phase,
                                          color: color,
                                          state: assistant.state,
                                          soundLevel: assistant.soundLevel,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      _labelFor(assistant.state),
                                      style: TextStyle(
                                        color: color,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 1.6,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      if (_orchestrator.status != TaskStatus.idle && _orchestrator.currentTask != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                          child: _ActiveTaskCard(
                            orchestrator: _orchestrator,
                            accent: color,
                            onApprove: (id) => _orchestrator.approveAuthorization(id),
                            onReject: (id) => _orchestrator.rejectAuthorization(id),
                            onCancel: () => _orchestrator.cancelActiveTask(),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _TranscriptPanel(
                          command: assistant.lastCommand,
                          response: assistant.lastResponse,
                          accent: color,
                        ),
                      ),
                      const SizedBox(height: 28),
                      _MicButton(
                        isListening: assistant.isListening,
                        color: color,
                        onPressed: () => _toggleListening(assistant),
                      ),
                      if (_attachedMediaPath != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Jv.ice.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Jv.ice.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.perm_media_rounded, size: 18, color: Jv.ice),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Media Attached: ${_attachedMediaPath!.split("/").last}',
                                    style: const TextStyle(fontSize: 12, color: Jv.text, fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close_rounded, size: 16, color: Jv.textMuted),
                                  onPressed: () => setState(() => _attachedMediaPath = null),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: 'Attach media / image',
                              icon: const Icon(Icons.attach_file_rounded, color: Jv.textMuted),
                              onPressed: _showMediaAttachmentDialog,
                            ),
                            Expanded(
                              child: TextField(
                                controller: _textInputController,
                                textInputAction: TextInputAction.send,
                                decoration: _fieldDecoration(
                                  label: 'Message Jarvis',
                                  icon: Icons.chat_bubble_outline_rounded,
                                ),
                                onSubmitted: (text) async {
                                  _textInputController.clear();
                                  await _processUserCommand(text, assistant);
                                },
                              ),
                            ),
                            IconButton(
                              tooltip: 'Send message',
                              onPressed: () async {
                                final text = _textInputController.text;
                                _textInputController.clear();
                                await _processUserCommand(text, assistant);
                              },
                              icon: const Icon(Icons.send_rounded),
                            ),
                            IconButton(
                              tooltip: 'Stop speaking',
                              onPressed: assistant.stopSpeaking,
                              icon: const Icon(Icons.volume_off_rounded),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home page widgets
// ─────────────────────────────────────────────────────────────────────────────

class ConversationHistoryPage extends StatelessWidget {
  const ConversationHistoryPage({super.key, required this.history});

  final List<Map<String, String>> history;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Jv.theme,
      child: Scaffold(
        appBar: AppBar(title: const Text('Chat history')),
        body: history.isEmpty
            ? const Center(child: Text('No conversations yet.'))
            : ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final turn = history[index];
                  final isUser = turn['role'] == 'user';
                  return Align(
                    alignment: isUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 420),
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: (isUser ? Jv.ice : Jv.violet).withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Jv.hairline(0.12)),
                      ),
                      child: Text(
                        turn['content'] ?? '',
                        style: const TextStyle(color: Jv.text, height: 1.4),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class ActivityLogPage extends StatelessWidget {
  const ActivityLogPage({super.key, required this.service});

  final LLMService service;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Jv.theme,
      child: Scaffold(
        appBar: AppBar(title: const Text('Activity log')),
        body: FutureBuilder<List<Map<String, String>>>(
          future: service.getActivityLog(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('Could not load activity: ${snapshot.error}'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final entries = snapshot.data!;
            if (entries.isEmpty) {
              return const Center(child: Text('No activity yet.'));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final time = DateTime.tryParse(entry['time'] ?? '')?.toLocal();
                final timestamp = time == null
                    ? entry['time'] ?? ''
                    : '${time.year}-${time.month.toString().padLeft(2, '0')}-'
                          '${time.day.toString().padLeft(2, '0')} '
                          '${time.hour.toString().padLeft(2, '0')}:'
                          '${time.minute.toString().padLeft(2, '0')}';
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Jv.panel,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Jv.hairline(0.12)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        timestamp,
                        style: const TextStyle(
                          color: Jv.ice,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(entry['summary'] ?? ''),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class NotesPage extends StatelessWidget {
  const NotesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Jv.theme,
      child: Scaffold(
        appBar: AppBar(title: const Text('Saved notes')),
        body: FutureBuilder<List<String>>(
          future: LLMService().getNotes(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('Could not load notes: ${snapshot.error}'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final notes = snapshot.data!;
            if (notes.isEmpty) {
              return const Center(child: Text('No saved notes yet.'));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: notes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: Text(notes[index]),
                tileColor: Jv.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class TasksHistoryPage extends StatefulWidget {
  const TasksHistoryPage({super.key, required this.service});

  final TaskExecutionService service;

  @override
  State<TasksHistoryPage> createState() => _TasksHistoryPageState();
}

class _TasksHistoryPageState extends State<TasksHistoryPage> {
  late Future<List<TaskRecord>> _tasksFuture;

  @override
  void initState() {
    super.initState();
    _tasksFuture = widget.service.listRecentTasks();
  }

  Color _statusColor(TaskStatus status) => switch (status) {
    TaskStatus.completed => Colors.greenAccent,
    TaskStatus.failed => Colors.redAccent,
    TaskStatus.cancelled => Jv.slate,
    TaskStatus.waitingForAuthorization || TaskStatus.waitingForPermission => Jv.amber,
    TaskStatus.executing || TaskStatus.planning || TaskStatus.verifying => Jv.ice,
    _ => Jv.textMuted,
  };

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Jv.theme,
      child: Scaffold(
        appBar: AppBar(title: const Text('Task History')),
        body: FutureBuilder<List<TaskRecord>>(
          future: _tasksFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('Error loading tasks: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final tasks = snapshot.data!;
            if (tasks.isEmpty) {
              return const Center(child: Text('No tasks executed yet.'));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final task = tasks[index];
                final color = _statusColor(task.status);
                return _Glass(
                  accent: color,
                  child: ExpansionTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    leading: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: color.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        task.status.name.toUpperCase(),
                        style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      task.instruction,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    subtitle: Text(
                      'ID: ${task.id} · ${task.steps.length} steps · ${task.createdAt.toLocal().toString().split(".")[0]}',
                      style: const TextStyle(color: Jv.textMuted, fontSize: 12),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Divider(color: Colors.white12),
                            if (task.result != null) ...[
                              const Text('Outcome:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Jv.ice)),
                              const SizedBox(height: 4),
                              Text(task.result!, style: const TextStyle(fontSize: 13)),
                              const SizedBox(height: 12),
                            ],
                            if (task.error != null) ...[
                              const Text('Error:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.redAccent)),
                              const SizedBox(height: 4),
                              Text(task.error!, style: const TextStyle(fontSize: 13, color: Colors.redAccent)),
                              const SizedBox(height: 12),
                            ],
                            const Text('Executed Steps:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Jv.textMuted)),
                            const SizedBox(height: 8),
                            if (task.steps.isEmpty)
                              const Text('No individual tool steps recorded.', style: TextStyle(color: Jv.textMuted, fontSize: 12))
                            else
                              ...task.steps.asMap().entries.map((e) {
                                final i = e.key + 1;
                                final step = e.value;
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.03),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: Colors.white10),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            '$i. Tool: ${step.tool}',
                                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Jv.ice),
                                          ),
                                          const Spacer(),
                                          Text(
                                            step.status.toUpperCase(),
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: step.status == 'success' ? Colors.greenAccent : Colors.orangeAccent,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Arguments: ${jsonEncode(step.arguments)}',
                                        style: const TextStyle(color: Jv.textMuted, fontSize: 11),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Result: ${step.result}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ActiveTaskCard extends StatelessWidget {
  const _ActiveTaskCard({
    required this.orchestrator,
    required this.accent,
    required this.onApprove,
    required this.onReject,
    required this.onCancel,
  });

  final TaskOrchestrator orchestrator;
  final Color accent;
  final void Function(String id) onApprove;
  final void Function(String id) onReject;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final task = orchestrator.currentTask;
    if (task == null) return const SizedBox.shrink();

    final status = orchestrator.status;
    final isWaitingAuth = status == TaskStatus.waitingForAuthorization;
    final auth = orchestrator.pendingAuthorization;

    return _Glass(
      accent: isWaitingAuth ? Jv.amber : accent,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (isWaitingAuth ? Jv.amber : accent).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: isWaitingAuth ? Jv.amber : accent, width: 0.8),
                  ),
                  child: Text(
                    status.name.toUpperCase(),
                    style: TextStyle(
                      color: isWaitingAuth ? Jv.amber : accent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Task ${task.id}',
                    style: const TextStyle(color: Jv.textMuted, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Cancel task',
                  icon: const Icon(Icons.close_rounded, size: 18, color: Jv.textMuted),
                  onPressed: onCancel,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              task.instruction,
              style: const TextStyle(color: Jv.text, fontSize: 14, fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (status == TaskStatus.planning || status == TaskStatus.executing || status == TaskStatus.verifying)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                    ),
                  ),
                Expanded(
                  child: Text(
                    orchestrator.statusMessage,
                    style: TextStyle(
                      color: isWaitingAuth ? Jv.amber : Jv.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            if (isWaitingAuth && auth != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Jv.amber.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Jv.amber.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.security_rounded, size: 16, color: Jv.amber),
                        SizedBox(width: 6),
                        Text(
                          'Explicit Authorization Required',
                          style: TextStyle(color: Jv.amber, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'Target App: ', style: TextStyle(color: Jv.textMuted, fontSize: 12)),
                          TextSpan(text: '${auth.targetApp}\n', style: const TextStyle(color: Jv.text, fontWeight: FontWeight.w500, fontSize: 12)),
                          const TextSpan(text: 'Destination: ', style: TextStyle(color: Jv.textMuted, fontSize: 12)),
                          TextSpan(text: '${auth.destination}\n', style: const TextStyle(color: Jv.text, fontWeight: FontWeight.w500, fontSize: 12)),
                          const TextSpan(text: 'Content: ', style: TextStyle(color: Jv.textMuted, fontSize: 12)),
                          TextSpan(text: '${auth.content}\n', style: const TextStyle(color: Jv.text, fontWeight: FontWeight.w500, fontSize: 12)),
                          const TextSpan(text: 'Consequences: ', style: TextStyle(color: Jv.textMuted, fontSize: 12)),
                          TextSpan(text: auth.consequences, style: const TextStyle(color: Jv.amber, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                          onPressed: () => onReject(auth.id),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Jv.amber,
                            foregroundColor: Jv.space,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                          onPressed: () => onApprove(auth.id),
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text('Approve'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TranscriptPanel extends StatelessWidget {
  const _TranscriptPanel({
    required this.command,
    required this.response,
    required this.accent,
  });

  final String command;
  final String response;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final isEmpty = command.isEmpty && response.isEmpty;

    return _Glass(
      accent: accent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220, minHeight: 72),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: SizedBox(
            width: double.infinity,
            child: isEmpty
                ? const Text(
                    "Say 'Hey Jarvis' while hands-free mode is on, or tap the mic",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Jv.textMuted,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (command.isNotEmpty)
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: 'You  ',
                                style: TextStyle(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(text: command),
                            ],
                          ),
                          style: const TextStyle(
                            color: Jv.textMuted,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                      if (response.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            response,
                            key: ValueKey(response),
                            style: const TextStyle(
                              color: Jv.text,
                              fontSize: 24,
                              fontWeight: FontWeight.w300,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.isListening,
    required this.color,
    required this.onPressed,
  });

  final bool isListening;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: isListening ? 'Stop listening' : 'Start listening',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withValues(alpha: 0.28), Jv.deep],
          ),
          border: Border.all(color: color.withValues(alpha: 0.8), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: isListening ? 0.55 : 0.25),
              blurRadius: isListening ? 38 : 22,
              spreadRadius: isListening ? 4 : 0,
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  isListening ? Icons.stop_rounded : Icons.mic_rounded,
                  key: ValueKey(isListening),
                  size: 38,
                  color: color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted panel with a hairline border and a faint accent glow along the top.
class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.accent = Jv.ice});

  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                accent.withValues(alpha: 0.09),
                Colors.white.withValues(alpha: 0.025),
              ],
            ),
            border: Border.all(color: Jv.hairline(0.10)),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Backdrop + painters
// ─────────────────────────────────────────────────────────────────────────────

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF080D1E), Jv.space],
            ),
          ),
        ),
        CustomPaint(painter: _GridPainter()),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.3),
              radius: 0.95,
              colors: [color.withValues(alpha: 0.16), Colors.transparent],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 1.15,
              colors: [Colors.transparent, Jv.space.withValues(alpha: 0.9)],
              stops: const [0.55, 1],
            ),
          ),
        ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const step = 44.0;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The assistant's "core": a glowing sphere inside rotating segmented rings.
/// Each state adds its own behaviour on top of the shared structure:
///  - listening: ripples expand outward
///  - thinking:  a bright dot orbits the rings, rotation speeds up
///  - speaking:  a waveform ring wobbles around the core
class _CorePainter extends CustomPainter {
  _CorePainter({
    required this.phase,
    required this.color,
    required this.state,
    required this.soundLevel,
  }) : super(repaint: phase);

  final ValueNotifier<double> phase;
  final Color color;
  final AssistantState state;
  final double soundLevel;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final p = phase.value;
    final pulse = 0.5 + 0.5 * math.sin(p * 2.2);

    // Ambient glow
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.30 + 0.12 * pulse),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Outer hairline
    canvas.drawCircle(
      c,
      r * 0.97,
      line
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.18),
    );

    // Tick ring
    const ticks = 90;
    final tickRot = p * 0.12;
    for (var i = 0; i < ticks; i++) {
      final a = tickRot + i * 2 * math.pi / ticks;
      final major = i % 6 == 0;
      line
        ..strokeWidth = major ? 1.6 : 1
        ..color = color.withValues(alpha: major ? 0.5 : 0.22);
      canvas.drawLine(
        c + Offset.fromDirection(a, r * 0.90),
        c + Offset.fromDirection(a, r * (major ? 0.84 : 0.87)),
        line,
      );
    }

    // Segmented rings, alternating direction
    _ring(canvas, c, r * 0.76, 3, 0.62, p * 0.5, 2.2, 0.75, line);
    _ring(canvas, c, r * 0.66, 5, 0.50, -p * 0.8, 1.6, 0.50, line);
    _ring(canvas, c, r * 0.56, 12, 0.55, p * 1.3, 1.2, 0.35, line);

    // State-specific layer
    switch (state) {
      case AssistantState.listening:
        for (var i = 0; i < 3; i++) {
          final t = (p * 0.35 + i / 3) % 1.0;
          canvas.drawCircle(
            c,
            r * (0.30 + 0.55 * t),
            line
              ..strokeWidth = 1.4
              ..color = color.withValues(alpha: (1 - t) * 0.4),
          );
        }
      case AssistantState.speaking:
        final wave = Path();
        const steps = 120;
        for (var k = 0; k <= steps; k++) {
          final a = k / steps * 2 * math.pi;
          final amp = r * 0.035 * (0.6 + 0.4 * math.sin(p * 3));
          final rad =
              r * 0.42 +
              amp * math.sin(a * 8 + p * 7) +
              amp * 0.5 * math.sin(a * 13 - p * 5);
          final pt = c + Offset.fromDirection(a, rad);
          if (k == 0) {
            wave.moveTo(pt.dx, pt.dy);
          } else {
            wave.lineTo(pt.dx, pt.dy);
          }
        }
        wave.close();
        canvas.drawPath(
          wave,
          line
            ..strokeWidth = 2
            ..color = color.withValues(alpha: 0.8),
        );
      case AssistantState.thinking:
        final orbitR = r * 0.66;
        final a = p * 2;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: orbitR),
          a - 1.2,
          1.2,
          false,
          line
            ..strokeWidth = 2
            ..color = color.withValues(alpha: 0.5),
        );
        final dot = c + Offset.fromDirection(a, orbitR);
        canvas.drawCircle(
          dot,
          5,
          Paint()
            ..color = color
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        canvas.drawCircle(dot, 2.5, Paint()..color = Colors.white);
      case AssistantState.idle:
        break;
    }

    // Core sphere
    final inputPulse = state == AssistantState.listening
        ? (soundLevel.clamp(0.0, 10.0) / 10.0)
        : 0.0;
    final coreR = r * (0.26 + 0.035 * inputPulse + 0.02 * pulse);
    final coreRect = Rect.fromCircle(center: c, radius: coreR);
    canvas.drawCircle(
      c,
      coreR * 1.5,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.12),
    );
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: [
            Color.lerp(Colors.white, color, 0.35)!,
            color,
            Color.lerp(color, Colors.black, 0.75)!,
          ],
          stops: const [0, 0.45, 1],
        ).createShader(coreRect),
    );
    canvas.drawCircle(
      c,
      coreR,
      line
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.35),
    );
  }

  void _ring(
    Canvas canvas,
    Offset c,
    double radius,
    int segments,
    double fill,
    double rotation,
    double width,
    double alpha,
    Paint paint,
  ) {
    paint
      ..strokeWidth = width
      ..color = color.withValues(alpha: alpha);
    final step = 2 * math.pi / segments;
    for (var i = 0; i < segments; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: radius),
        rotation + i * step,
        step * fill,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CorePainter old) =>
      old.color != color || old.state != state || old.soundLevel != soundLevel;
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings page
// ─────────────────────────────────────────────────────────────────────────────

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const MethodChannel _wakeWordChannel = MethodChannel(
    'com.assistant.app/wakeword',
  );

  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _ollamaUrlController = TextEditingController();
  final TextEditingController _ollamaModelController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _userNameController = TextEditingController();
  final LLMService _llmService = LLMService();
  final PermissionManager _permissionManager = PermissionManager();
  LLMProvider _provider = LLMProvider.anthropic;
  bool _isPullingModel = false;
  bool _isDiscoveringModel = false;
  bool _isWakeWordActive = false;
  double? _pullProgress;
  String _pullStatus = '';

  bool _alwaysAllowPermissions = true;
  bool _notifyOnTask = true;
  List<String> _authorizedTools = [];
  String _defaultMusic = 'spotify';
  String _defaultEmail = 'gmail';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadWakeWordState();
  }

  Future<void> _loadSettings() async {
    final provider = await _llmService.getProvider();
    final values = await Future.wait([
      _llmService.getApiKey(provider: provider),
      _llmService.getOllamaBaseUrl(),
      _llmService.getOllamaModel(),
      _llmService.getConfiguredModel(provider: provider),
      _llmService.getUserName(),
      _permissionManager.isAlwaysAllowEnabled(),
      _permissionManager.getAuthorizedTools(),
      _permissionManager.shouldNotifyOnTaskCompletion(),
      _permissionManager.getDefaultMusicApp(),
      _permissionManager.getDefaultEmailApp(),
    ]);
    if (mounted) {
      setState(() {
        _provider = provider;
        _keyController.text = values[0] as String? ?? '';
        _ollamaUrlController.text = values[1] as String;
        _ollamaModelController.text = values[2] as String;
        _modelController.text = values[3] as String? ?? '';
        _userNameController.text = values[4] as String;
        _alwaysAllowPermissions = values[5] as bool;
        _authorizedTools = values[6] as List<String>;
        _notifyOnTask = values[7] as bool;
        _defaultMusic = values[8] as String;
        _defaultEmail = values[9] as String;
      });
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _ollamaUrlController.dispose();
    _ollamaModelController.dispose();
    _modelController.dispose();
    _userNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final assistant = Provider.of<AssistantProvider>(context);
    return Theme(
      data: Jv.theme,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: Jv.text,
          title: const Text(
            'Settings',
            style: TextStyle(fontWeight: FontWeight.w300, letterSpacing: 2),
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            const _Backdrop(color: Jv.ice),
            SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  _buildPersonalizationSection(),
                  const SizedBox(height: 16),
                  _buildCustomizationAndPermissionsSection(assistant),
                  const SizedBox(height: 16),
                  _buildProviderSection(),
                  const SizedBox(height: 16),
                  _buildVoiceSection(assistant),
                  const SizedBox(height: 16),
                  _buildAndroidIntegrationSection(),
                  const SizedBox(height: 16),
                  if (_provider == LLMProvider.ollama) ...[
                    _buildOllamaSection(),
                    _buildApiKeySection(includeModel: false),
                  ] else
                    _buildApiKeySection(includeModel: true),
                  const SizedBox(height: 16),
                  _buildHandsFreeSection(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomizationAndPermissionsSection(AssistantProvider assistant) {
    return _Section(
      icon: Icons.tune_rounded,
      title: 'App Customization & Permissions',
      subtitle:
          'Configure default apps, persistent permissions, and task alerts.',
      children: [
        ElevatedButton.icon(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OnboardingWizardPage(
                  assistantProvider: assistant,
                  isRevisit: true,
                ),
              ),
            );
            _loadSettings();
          },
          icon: const Icon(Icons.auto_fix_high_rounded),
          label: const Text('Open First-Time Setup Wizard'),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Remember Permissions Always'),
          subtitle: const Text(
            'Once granted, always go ahead without asking repeatedly.',
            style: TextStyle(fontSize: 12, color: Jv.textMuted),
          ),
          value: _alwaysAllowPermissions,
          activeThumbColor: Jv.ice,
          onChanged: (val) async {
            await _permissionManager.setAlwaysAllowEnabled(val);
            setState(() => _alwaysAllowPermissions = val);
          },
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Task Completion Notifications'),
          subtitle: const Text(
            'Receive system notifications when Jarvis finishes an action.',
            style: TextStyle(fontSize: 12, color: Jv.textMuted),
          ),
          value: _notifyOnTask,
          activeThumbColor: Jv.ice,
          onChanged: (val) async {
            await _permissionManager.setNotifyOnTaskCompletion(val);
            setState(() => _notifyOnTask = val);
          },
        ),
        const SizedBox(height: 12),
        const Text(
          'Authorized Sensitive Operations:',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Jv.text,
          ),
        ),
        const SizedBox(height: 6),
        if (_authorizedTools.isEmpty)
          const Text(
            'No tools permanently authorized yet. Once you grant permission, they will appear here.',
            style: TextStyle(fontSize: 12, color: Jv.textMuted),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ..._authorizedTools.map(
                (t) => Chip(
                  backgroundColor: Jv.panel,
                  label: Text(t.replaceAll('_', ' ')),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: () async {
                    await _permissionManager.revokeToolAuthorization(t);
                    _loadSettings();
                  },
                ),
              ),
            ],
          ),
        if (_authorizedTools.isNotEmpty) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () async {
              await _permissionManager.resetAllAuthorizations();
              _loadSettings();
            },
            child: const Text(
              'Revoke All Tool Authorizations',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _defaultMusic,
          decoration: _fieldDecoration(
            label: 'Default Music Player',
            icon: Icons.music_note_rounded,
          ),
          items: const [
            DropdownMenuItem(value: 'spotify', child: Text('Spotify')),
            DropdownMenuItem(
              value: 'youtube_music',
              child: Text('YouTube Music'),
            ),
            DropdownMenuItem(value: 'apple_music', child: Text('Apple Music')),
            DropdownMenuItem(value: 'system', child: Text('System Player')),
          ],
          onChanged: (val) async {
            if (val != null) {
              await _permissionManager.setDefaultMusicApp(val);
              setState(() => _defaultMusic = val);
            }
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _defaultEmail,
          decoration: _fieldDecoration(
            label: 'Default Email Service',
            icon: Icons.mail_outline_rounded,
          ),
          items: const [
            DropdownMenuItem(value: 'gmail', child: Text('Google Gmail')),
            DropdownMenuItem(
              value: 'system',
              child: Text('System Email Client'),
            ),
          ],
          onChanged: (val) async {
            if (val != null) {
              await _permissionManager.setDefaultEmailApp(val);
              setState(() => _defaultEmail = val);
            }
          },
        ),
      ],
    );
  }

  Widget _buildVoiceSection(AssistantProvider assistant) {
    String voiceId(Map<String, String> voice) =>
        '${voice['name']}|${voice['locale']}';
    return _Section(
      icon: Icons.record_voice_over_rounded,
      title: 'Voice',
      subtitle: 'Choose how Jarvis speaks.',
      children: [
        DropdownButtonFormField<String>(
          initialValue: assistant.selectedVoice,
          decoration: _fieldDecoration(
            label: 'Text-to-speech voice',
            icon: Icons.graphic_eq_rounded,
          ),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('System default'),
            ),
            ...assistant.voices.map(
              (voice) => DropdownMenuItem<String>(
                value: voiceId(voice),
                child: Text('${voice['name']} (${voice['locale']})'),
              ),
            ),
          ],
          onChanged: assistant.setVoice,
        ),
        const SizedBox(height: 16),
        Text('Speech rate · ${assistant.speechRate.toStringAsFixed(2)}'),
        Slider(
          value: assistant.speechRate,
          min: 0.25,
          max: 1.0,
          onChanged: assistant.setSpeechRate,
        ),
      ],
    );
  }

  Widget _buildPersonalizationSection() {
    return _Section(
      icon: Icons.person_outline_rounded,
      title: 'Personalization',
      subtitle: 'Jarvis will use your name in its greetings and replies.',
      children: [
        TextField(
          controller: _userNameController,
          textCapitalization: TextCapitalization.words,
          maxLength: 40,
          decoration: _fieldDecoration(
            label: 'What should Jarvis call you?',
            icon: Icons.badge_outlined,
          ),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () async {
            try {
              await _llmService.setUserName(_userNameController.text);
              if (mounted) {
                final savedName = _userNameController.text.trim();
                Navigator.pop(context, savedName);
              }
            } catch (error) {
              if (mounted) _showMessage('Could not save your name: $error');
            }
          },
          child: const Text('Save name'),
        ),
      ],
    );
  }

  Widget _buildAndroidIntegrationSection() {
    final isLinux = PlatformService.isLinux;
    return _Section(
      icon: isLinux ? Icons.desktop_windows_rounded : Icons.phone_android_rounded,
      title: isLinux ? 'System integration' : 'Android integration',
      subtitle: isLinux
          ? 'Desktop media controls, notifications, and application integration.'
          : 'Optional system access for assistant and media features.',
      children: [
        Text(
          isLinux
              ? 'Jarvis integrates with Linux desktop media players (MPRIS/DBus) '
                'and system notifications.'
              : 'Setting Jarvis as the default assistant lets Android open it from '
                'the assistant gesture. Media controls require notification access '
                'so Jarvis can see the currently active media session.',
          style: const TextStyle(color: Jv.textMuted, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton(
              onPressed: () async {
                final result = await PlatformService.requestDefaultAssistant();
                if (mounted) _showMessage(result);
              },
              child: Text(isLinux ? 'Check system status' : 'Set as default assistant'),
            ),
            OutlinedButton(
              onPressed: () async {
                final result =
                    await PlatformService.requestNotificationAccess();
                if (mounted) _showMessage(result);
              },
              child: Text(isLinux ? 'Test notifications' : 'Enable media access'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            IconButton(
              tooltip: 'Play media',
              onPressed: () async =>
                  _showMessage(await PlatformService.mediaControl('play')),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
            IconButton(
              tooltip: 'Pause media',
              onPressed: () async =>
                  _showMessage(await PlatformService.mediaControl('pause')),
              icon: const Icon(Icons.pause_rounded),
            ),
            IconButton(
              tooltip: 'Previous track',
              onPressed: () async =>
                  _showMessage(await PlatformService.mediaControl('previous')),
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            IconButton(
              tooltip: 'Next track',
              onPressed: () async =>
                  _showMessage(await PlatformService.mediaControl('next')),
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProviderSection() {
    return _Section(
      icon: Icons.psychology_alt_rounded,
      title: 'Language model',
      subtitle: 'Choose where Jarvis thinks.',
      children: [
        SizedBox(
          width: double.infinity,
          child: DropdownButtonFormField<LLMProvider>(
            initialValue: _provider,
            decoration: _fieldDecoration(
              label: 'Provider',
              icon: Icons.cloud_outlined,
            ),
            items: LLMProvider.values
                .map(
                  (provider) => DropdownMenuItem(
                    value: provider,
                    child: Text(provider.displayName),
                  ),
                )
                .toList(),
            onChanged: (provider) async {
              if (provider == null) return;
              await _llmService.setProvider(provider);
              final values = await Future.wait([
                _llmService.getApiKey(provider: provider),
                _llmService.getConfiguredModel(provider: provider),
              ]);
              if (mounted) {
                setState(() {
                  _provider = provider;
                  _keyController.text = values[0] ?? '';
                  _modelController.text = values[1] ?? '';
                });
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOllamaSection() {
    return _Section(
      icon: Icons.dns_rounded,
      title: 'Ollama server',
      children: [
        TextField(
          controller: _ollamaUrlController,
          keyboardType: TextInputType.url,
          decoration: _fieldDecoration(
            label: 'Ollama server URL',
            hint: 'http://10.0.2.2:11434 (Android emulator)',
            icon: Icons.link_rounded,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Ollama must be running on the computer hosting the model. '
          'Use http://10.0.2.2:11434 for an Android emulator (not localhost). '
          'On a physical device, enter your computer’s LAN IP and configure '
          'Ollama to accept LAN connections. In Chrome, Ollama must also allow '
          'the web origin (set OLLAMA_ORIGINS=* on a trusted local network).',
          style: TextStyle(color: Jv.textMuted, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 8),
        const Text(
          'Gemma 3 4B is an approximately 3 GB download. Ollama runs it on '
          'the computer hosting Ollama; the phone needs to reach that computer '
          'over Wi-Fi. Once downloaded, model inference does not need internet.',
          style: TextStyle(color: Jv.textMuted, fontSize: 12, height: 1.45),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _ollamaModelController,
          decoration: _fieldDecoration(
            label: 'Model name',
            hint: 'llama3.2',
            icon: Icons.auto_awesome_rounded,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            ElevatedButton(
              onPressed: _isPullingModel ? null : _saveOllamaSettings,
              child: const Text('Save Ollama Settings'),
            ),
            OutlinedButton(
              onPressed: _isPullingModel ? null : _pullModel,
              child: const Text('Pull Model'),
            ),
            OutlinedButton.icon(
              onPressed: _isPullingModel ? null : _pullGemmaFourB,
              icon: const Icon(Icons.offline_bolt_outlined),
              label: const Text('Pull Gemma 3 4B'),
            ),
            OutlinedButton(
              onPressed: _isPullingModel ? null : _checkOllama,
              child: const Text('Check Connection'),
            ),
          ],
        ),
        if (_isPullingModel) ...[
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _pullProgress,
              minHeight: 4,
              color: Jv.ice,
              backgroundColor: Jv.hairline(0.08),
            ),
          ),
        ],
        if (_pullStatus.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _pullStatus,
            style: const TextStyle(color: Jv.textMuted, fontSize: 13),
          ),
        ],
      ],
    );
  }

  Widget _buildHandsFreeSection() {
    return _Section(
      icon: Icons.hearing_rounded,
      title: 'Hands-free mode',
      children: [
        const Text(
          'Keep Jarvis listening for “Hey Jarvis” when this app is not '
          'open. Android shows an ongoing microphone notification while '
          'listening. Speech recognition availability depends on your device.',
          style: TextStyle(color: Jv.textMuted, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isWakeWordActive
                    ? Jv.ice
                    : Jv.textMuted.withValues(alpha: 0.5),
                boxShadow: _isWakeWordActive
                    ? [
                        BoxShadow(
                          color: Jv.ice.withValues(alpha: 0.8),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _isWakeWordActive
                    ? 'Jarvis is listening. Say “Hey Jarvis” followed by your request.'
                    : 'Wake phrase is off.',
                style: const TextStyle(color: Jv.text, fontSize: 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            ElevatedButton(
              onPressed: _isWakeWordActive ? null : _startWakeWord,
              child: const Text('Start listening'),
            ),
            OutlinedButton(
              onPressed: _isWakeWordActive ? _stopWakeWord : null,
              child: const Text('Stop listening'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildApiKeySection({required bool includeModel}) {
    return _Section(
      icon: Icons.key_rounded,
      title: '${_provider.displayName} settings',
      subtitle: 'Stored on this device and used for cloud requests.',
      children: [
        if (includeModel) ...[
          TextField(
            controller: _modelController,
            decoration: _fieldDecoration(
              label: 'Model (optional)',
              icon: Icons.auto_awesome_rounded,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Leave blank and Jarvis will find a model available to your API key.',
            style: TextStyle(color: Jv.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
        ],
        if (_provider != LLMProvider.ollama)
          TextField(
            controller: _keyController,
            obscureText: true,
            decoration: _fieldDecoration(
              label: '${_provider.displayName} API key',
              icon: Icons.lock_outline_rounded,
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ElevatedButton(
              onPressed: _isDiscoveringModel
                  ? null
                  : () => _saveProviderSettings(includeModel: includeModel),
              child: Text(
                includeModel ? 'Save key and model' : 'Save settings',
              ),
            ),
            if (includeModel)
              OutlinedButton(
                onPressed: _isDiscoveringModel ? null : _discoverProviderModel,
                child: Text(
                  _isDiscoveringModel
                      ? 'Checking key…'
                      : 'Check key & choose model',
                ),
              ),
            if (_provider != LLMProvider.ollama)
              OutlinedButton.icon(
                onPressed: _openKeySignup,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Get an API key'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'API providers may charge for usage. Keys are stored securely on this device.',
          style: TextStyle(color: Jv.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _saveProviderSettings({required bool includeModel}) async {
    try {
      if (_provider != LLMProvider.ollama) {
        if (_keyController.text.trim().isEmpty) {
          throw StateError('Enter an API key before saving.');
        }
        await _llmService.setProviderApiKey(_provider, _keyController.text);
      }
      final requestedModel = _modelController.text.trim();
      if (includeModel && requestedModel.isNotEmpty) {
        await _llmService.setModel(requestedModel, provider: _provider);
      } else if (includeModel) {
        await _llmService.clearConfiguredModel(provider: _provider);
      }
      if (mounted) {
        final modelMessage = includeModel
            ? ' Default model: ${await _llmService.getModel(provider: _provider)}.'
            : '';
        _showMessage('${_provider.displayName} settings saved.$modelMessage');
      }
    } catch (error) {
      if (mounted) _showMessage('Could not save settings: $error');
    }
  }

  Future<void> _discoverProviderModel() async {
    setState(() => _isDiscoveringModel = true);
    try {
      await _llmService.setProviderApiKey(_provider, _keyController.text);
      final model = await _llmService.discoverAndSaveModel(_provider);
      if (mounted) {
        setState(() => _modelController.text = model);
        _showMessage('API key works. Jarvis selected $model.');
      }
    } catch (error) {
      if (mounted) {
        final browserHelp = kIsWeb
            ? ' Browser requests can be blocked by provider CORS rules; you '
                  'can still save the key and use the default model.'
            : '';
        _showMessage('Could not list models: $error.$browserHelp');
      }
    } finally {
      if (mounted) setState(() => _isDiscoveringModel = false);
    }
  }

  Future<void> _openKeySignup() async {
    final uri = Uri.parse(_provider.keyUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      _showMessage('Could not open ${_provider.displayName} key page.');
    }
  }

  Future<void> _loadWakeWordState() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final isRunning =
          await _wakeWordChannel.invokeMethod<bool>('isRunning') ?? false;
      if (mounted) setState(() => _isWakeWordActive = isRunning);
    } on PlatformException {
      if (mounted) setState(() => _isWakeWordActive = false);
    }
  }

  Future<void> _startWakeWord() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      _showMessage('Hands-free listening is currently supported on Android.');
      return;
    }
    try {
      final microphone = await Permission.microphone.request();
      if (!microphone.isGranted) {
        _showMessage(
          'Microphone permission is required for wake-word listening.',
        );
        return;
      }
      final notifications = await Permission.notification.request();
      if (!notifications.isGranted) {
        _showMessage(
          'Allow notifications so Android can show the listening indicator.',
        );
        return;
      }

      var model = _provider == LLMProvider.ollama
          ? _ollamaModelController.text.trim()
          : _modelController.text.trim();
      if (_provider == LLMProvider.ollama) {
        await _llmService.setOllamaBaseUrl(_ollamaUrlController.text);
        await _llmService.setOllamaModel(model);
      } else {
        if (model.isEmpty) {
          model = await _llmService.getModel(provider: _provider);
          await _llmService.setModel(model, provider: _provider);
          if (mounted) setState(() => _modelController.text = model);
        } else {
          await _llmService.setModel(model, provider: _provider);
        }
      }
      final apiKey = await _llmService.getApiKey(provider: _provider);
      if (_provider != LLMProvider.ollama &&
          (apiKey == null || apiKey.isEmpty)) {
        _showMessage('Save a ${_provider.displayName} API key first.');
        return;
      }
      await _wakeWordChannel.invokeMethod<void>('start', {
        'baseUrl': await _llmService.getOllamaBaseUrl(),
        'model': model,
        'provider': _provider.name,
        'apiKey': apiKey ?? '',
        'userName': await _llmService.getUserName(),
      });
      if (mounted) {
        setState(() => _isWakeWordActive = true);
        _showMessage('Jarvis is listening for “Hey Jarvis”.');
      }
    } on PlatformException catch (error) {
      if (mounted) _showMessage('Could not start Jarvis: ${error.message}');
    } catch (error) {
      if (mounted) _showMessage('Could not start Jarvis: $error');
    }
  }

  Future<void> _stopWakeWord() async {
    try {
      await _wakeWordChannel.invokeMethod<void>('stop');
      if (mounted) {
        setState(() => _isWakeWordActive = false);
        _showMessage('Wake-word listening stopped.');
      }
    } on PlatformException catch (error) {
      if (mounted) _showMessage('Could not stop Jarvis: ${error.message}');
    }
  }

  Future<void> _saveOllamaSettings() async {
    try {
      await _llmService.setOllamaBaseUrl(_ollamaUrlController.text);
      await _llmService.setOllamaModel(_ollamaModelController.text);
      await _llmService.setProvider(LLMProvider.ollama);
      if (mounted) {
        setState(() {
          _provider = LLMProvider.ollama;
          _modelController.text = '';
        });
        _showMessage('Ollama settings saved.');
      }
    } catch (error) {
      if (mounted) _showMessage('Could not save settings: $error');
    }
  }

  Future<void> _checkOllama() async {
    try {
      await _llmService.setOllamaBaseUrl(_ollamaUrlController.text);
      final models = await _llmService.listOllamaModels(
        baseUrl: _ollamaUrlController.text,
      );
      if (mounted) {
        _showMessage(
          models.isEmpty
              ? 'Connected to Ollama. No models are installed yet.'
              : 'Connected. Installed models: ${models.join(', ')}',
        );
      }
    } catch (error) {
      if (mounted) {
        _showMessage('Could not connect to Ollama: ${_ollamaErrorHelp(error)}');
      }
    }
  }

  Future<void> _pullModel() async {
    try {
      await _llmService.setOllamaBaseUrl(_ollamaUrlController.text);
      final model = _ollamaModelController.text.trim();
      await _llmService.setOllamaModel(model);
      await _llmService.setProvider(LLMProvider.ollama);
      if (!mounted) return;
      setState(() {
        _provider = LLMProvider.ollama;
        _isPullingModel = true;
        _pullProgress = null;
        _pullStatus = 'Starting model download...';
      });
      await _llmService.pullOllamaModel(
        model: model,
        baseUrl: _ollamaUrlController.text,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _pullStatus = progress.status;
              _pullProgress = progress.fraction;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _isPullingModel = false;
          _pullProgress = 1;
          _pullStatus = 'Model $model is ready to use.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isPullingModel = false;
          _pullStatus = 'Model download failed: ${_ollamaErrorHelp(error)}';
        });
      }
    }
  }

  Future<void> _pullGemmaFourB() async {
    _ollamaModelController.text = LLMService.gemmaFourBModel;
    await _pullModel();
  }

  String _ollamaErrorHelp(Object error) {
    if (kIsWeb) {
      return '$error. If this is a browser CORS error, restart Ollama with '
          'OLLAMA_ORIGINS=* and retry. Only allow trusted local origins; use '
          'the Android app to avoid browser CORS restrictions.';
    }
    return '$error. Confirm Ollama is running, the URL is reachable, and the '
        'model name exists. For a physical Android phone, Ollama on the PC '
        'must listen on 0.0.0.0:11434; the phone and PC must be on the same '
        'non-guest Wi-Fi, with VPN/client isolation off and port 11434 allowed.';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Jv.text)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Jv.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Jv.ice.withValues(alpha: 0.35)),
        ),
      ),
    );
  }
}

/// A titled glass card used to group related settings.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Jv.ice),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Jv.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: const TextStyle(color: Jv.textMuted, fontSize: 13),
              ),
            ],
            const SizedBox(height: 18),
            ...children,
          ],
        ),
      ),
    );
  }
}

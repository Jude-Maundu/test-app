import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/services/llm_service.dart';
import 'package:test_app/services/permission_manager.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/ui/pages/assistant_home.dart';

class OnboardingWizardPage extends StatefulWidget {
  const OnboardingWizardPage({
    super.key,
    required this.assistantProvider,
    this.isRevisit = false,
  });

  final AssistantProvider assistantProvider;
  final bool isRevisit;

  @override
  State<OnboardingWizardPage> createState() => _OnboardingWizardPageState();
}

class _OnboardingWizardPageState extends State<OnboardingWizardPage> {
  final PageController _pageController = PageController();
  final PermissionManager _permissionManager = PermissionManager();
  final LLMService _llmService = LLMService();

  int _currentPage = 0;
  final int _totalPages = 4;

  // Step 1: User name & Voice
  final TextEditingController _nameController = TextEditingController(text: 'Jude');
  double _speechRate = 0.5;
  String? _selectedVoice;

  // Step 2: Defaults
  String _defaultMusic = 'spotify';
  String _defaultEmail = 'gmail';
  String _defaultClock = 'google_clock';
  String _defaultCalendar = 'google_calendar';

  // Step 3: Permissions ("Grant once, always go ahead")
  bool _alwaysAllow = true;
  bool _gmailAccess = true;
  bool _musicAccess = true;
  bool _alarmAccess = true;
  bool _calendarAccess = true;
  bool _messagingAccess = true;
  bool _callAccess = true;
  bool _notificationsAccess = true;

  // Step 4: LLM & Offline
  LLMProvider _selectedProvider = LLMProvider.ollama;
  final TextEditingController _ollamaUrlController =
      TextEditingController(text: LLMService.defaultOllamaUrl);
  final TextEditingController _ollamaModelController =
      TextEditingController(text: LLMService.defaultOllamaModel);

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final name = await _llmService.getUserName();
    final music = await _permissionManager.getDefaultMusicApp();
    final email = await _permissionManager.getDefaultEmailApp();
    final clock = await _permissionManager.getDefaultClockApp();
    final calendar = await _permissionManager.getDefaultCalendarApp();
    final alwaysAllow = await _permissionManager.isAlwaysAllowEnabled();
    final provider = await _llmService.getProvider();
    final ollamaUrl = await _llmService.getOllamaBaseUrl();
    final ollamaModel = await _llmService.getOllamaModel();

    if (mounted) {
      setState(() {
        _nameController.text = name;
        _defaultMusic = music;
        _defaultEmail = email;
        _defaultClock = clock;
        _defaultCalendar = calendar;
        _alwaysAllow = alwaysAllow;
        _speechRate = widget.assistantProvider.speechRate;
        _selectedVoice = widget.assistantProvider.selectedVoice;
        _selectedProvider = provider;
        _ollamaUrlController.text = ollamaUrl;
        _ollamaModelController.text = ollamaModel;
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _ollamaUrlController.dispose();
    _ollamaModelController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      _finishSetup();
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _finishSetup() async {
    // 1. Save personalization
    final name = _nameController.text.trim();
    if (name.isNotEmpty) {
      await _llmService.setUserName(name);
    }
    await widget.assistantProvider.setSpeechRate(_speechRate);
    if (_selectedVoice != null) {
      await widget.assistantProvider.setVoice(_selectedVoice);
    }

    // 2. Save default apps
    await _permissionManager.setDefaultMusicApp(_defaultMusic);
    await _permissionManager.setDefaultEmailApp(_defaultEmail);
    await _permissionManager.setDefaultClockApp(_defaultClock);
    await _permissionManager.setDefaultCalendarApp(_defaultCalendar);

    // 3. Save persistent permissions
    await _permissionManager.setAlwaysAllowEnabled(_alwaysAllow);
    if (_alwaysAllow) {
      if (_messagingAccess) {
        await _permissionManager.grantToolAuthorization('send_sms');
        await _permissionManager.grantToolAuthorization('send_whatsapp_message');
      }
      if (_callAccess) {
        await _permissionManager.grantToolAuthorization('make_call');
      }
      if (_gmailAccess) {
        await _permissionManager.grantToolAuthorization('send_email');
        await _permissionManager.grantToolAuthorization('open_gmail');
      }
    }
    await _permissionManager.setNotifyOnTaskCompletion(_notificationsAccess);

    // Request system runtime permissions if on mobile
    if (!PlatformService.isLinux) {
      try {
        if (_notificationsAccess) await Permission.notification.request();
        if (_messagingAccess) await Permission.sms.request();
        if (_callAccess) {
          await Permission.phone.request();
          await Permission.contacts.request();
        }
      } catch (_) {}
    }

    // 4. Save AI provider settings
    await _llmService.setProvider(_selectedProvider);
    if (_selectedProvider == LLMProvider.ollama) {
      await _llmService.setOllamaBaseUrl(_ollamaUrlController.text);
      await _llmService.setOllamaModel(_ollamaModelController.text);
    }

    // 5. Mark onboarding complete
    await _permissionManager.setCompletedOnboarding(true);

    if (mounted) {
      final greeting =
          'Welcome, ${name.isEmpty ? "Jude" : name}. Jarvis is personalized with your default apps and permissions.';
      widget.assistantProvider.speak(greeting);
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Jv.theme,
      child: Scaffold(
        backgroundColor: Jv.space,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            widget.isRevisit ? 'Assistant Customization' : 'Jarvis Setup Wizard',
            style: const TextStyle(fontWeight: FontWeight.w300, letterSpacing: 2),
          ),
          actions: [
            if (!widget.isRevisit)
              TextButton(
                onPressed: _finishSetup,
                child: const Text('Skip', style: TextStyle(color: Jv.ice)),
              ),
          ],
        ),
        body: Column(
          children: [
            // Progress Indicator Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Row(
                children: List.generate(_totalPages, (index) {
                  final active = index <= _currentPage;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: active ? Jv.ice : Jv.hairline(0.12),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _buildStep1Personalization(),
                  _buildStep2DefaultApps(),
                  _buildStep3Permissions(),
                  _buildStep4AiBrain(),
                ],
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildStep1Personalization() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.auto_awesome_rounded, size: 48, color: Jv.ice),
        const SizedBox(height: 16),
        const Text(
          'Personalize Your Assistant',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Jv.text),
        ),
        const SizedBox(height: 8),
        const Text(
          'Customize how Jarvis addresses you and speaks.',
          style: TextStyle(fontSize: 14, color: Jv.textMuted),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _nameController,
          decoration: InputDecoration(
            labelText: 'What should Jarvis call you?',
            prefixIcon: const Icon(Icons.person_rounded, color: Jv.ice),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 24),
        Text('Speech Rate (${_speechRate.toStringAsFixed(2)})'),
        Slider(
          value: _speechRate,
          min: 0.25,
          max: 1.0,
          activeColor: Jv.ice,
          onChanged: (v) => setState(() => _speechRate = v),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: () {
            widget.assistantProvider.speak(
              'Hello, ${_nameController.text.trim().isEmpty ? "Jude" : _nameController.text}. I am Jarvis.',
            );
          },
          icon: const Icon(Icons.volume_up_rounded),
          label: const Text('Test Voice Sample'),
        ),
      ],
    );
  }

  Widget _buildStep2DefaultApps() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.apps_rounded, size: 48, color: Jv.ice),
        const SizedBox(height: 16),
        const Text(
          'Default Apps Customization',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Jv.text),
        ),
        const SizedBox(height: 8),
        const Text(
          'Choose your default music player, Gmail, alarm, and calendar apps.',
          style: TextStyle(fontSize: 14, color: Jv.textMuted),
        ),
        const SizedBox(height: 24),
        _buildAppChoiceCard(
          title: 'Default Music App',
          subtitle: 'Jarvis will play tracks and control media with this app',
          icon: Icons.music_note_rounded,
          value: _defaultMusic,
          options: const [
            {'id': 'spotify', 'label': 'Spotify'},
            {'id': 'youtube_music', 'label': 'YouTube Music'},
            {'id': 'apple_music', 'label': 'Apple Music'},
            {'id': 'system', 'label': 'System Player'},
          ],
          onChanged: (val) => setState(() => _defaultMusic = val!),
        ),
        const SizedBox(height: 16),
        _buildAppChoiceCard(
          title: 'Default Email Service',
          subtitle: 'Used when drafting and searching emails',
          icon: Icons.email_rounded,
          value: _defaultEmail,
          options: const [
            {'id': 'gmail', 'label': 'Google Gmail'},
            {'id': 'system', 'label': 'System Email Client'},
          ],
          onChanged: (val) => setState(() => _defaultEmail = val!),
        ),
        const SizedBox(height: 16),
        _buildAppChoiceCard(
          title: 'Default Clock & Alarms',
          subtitle: 'Used for alarms and countdown timers',
          icon: Icons.alarm_rounded,
          value: _defaultClock,
          options: const [
            {'id': 'google_clock', 'label': 'Google Clock'},
            {'id': 'system', 'label': 'Device Clock'},
          ],
          onChanged: (val) => setState(() => _defaultClock = val!),
        ),
        const SizedBox(height: 16),
        _buildAppChoiceCard(
          title: 'Default Calendar',
          subtitle: 'Used for adding and checking schedule events',
          icon: Icons.calendar_month_rounded,
          value: _defaultCalendar,
          options: const [
            {'id': 'google_calendar', 'label': 'Google Calendar'},
            {'id': 'system', 'label': 'Device Calendar'},
          ],
          onChanged: (val) => setState(() => _defaultCalendar = val!),
        ),
      ],
    );
  }

  Widget _buildStep3Permissions() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.security_rounded, size: 48, color: Jv.ice),
        const SizedBox(height: 16),
        const Text(
          'Permissions & Access',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Jv.text),
        ),
        const SizedBox(height: 8),
        const Text(
          'Once you give permission once, Jarvis will remember and always go ahead without interrupting you.',
          style: TextStyle(fontSize: 14, color: Jv.textMuted),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Jv.ice.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Jv.ice.withValues(alpha: 0.4)),
          ),
          child: SwitchListTile(
            title: const Text(
              'Remember Permissions Always',
              style: TextStyle(fontWeight: FontWeight.bold, color: Jv.ice),
            ),
            subtitle: const Text(
              'Once authorized, always execute tasks immediately without repeated confirmation dialogs.',
              style: TextStyle(fontSize: 12, color: Jv.textMuted),
            ),
            value: _alwaysAllow,
            activeThumbColor: Jv.ice,
            onChanged: (v) => setState(() => _alwaysAllow = v),
          ),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          secondary: const Icon(Icons.mail_outline_rounded, color: Jv.ice),
          title: const Text('Gmail & Email Access'),
          subtitle: const Text('Draft and open emails directly in Gmail'),
          value: _gmailAccess,
          activeThumbColor: Jv.ice,
          onChanged: (v) => setState(() => _gmailAccess = v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.play_circle_outline_rounded, color: Jv.ice),
          title: const Text('Music & Media Playback'),
          subtitle: const Text('Play, pause, next track, and volume control'),
          value: _musicAccess,
          activeThumbColor: Jv.ice,
          onChanged: (v) => setState(() => _musicAccess = v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.alarm_on_rounded, color: Jv.ice),
          title: const Text('Alarms & Timers'),
          subtitle: const Text('Set wake-up alarms and countdown timers'),
          value: _alarmAccess,
          activeThumbColor: Jv.ice,
          onChanged: (v) => setState(() => _alarmAccess = v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.calendar_today_rounded, color: Jv.ice),
          title: const Text('Calendar Events'),
          subtitle: const Text('Create calendar meetings and schedule items'),
          value: _calendarAccess,
          activeThumbColor: Jv.ice,
          onChanged: (v) => setState(() => _calendarAccess = v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.chat_rounded, color: Jv.ice),
          title: const Text('SMS & WhatsApp Messaging'),
          subtitle: const Text('Send SMS and WhatsApp messages without repeated prompts'),
          value: _messagingAccess,
          activeThumbColor: Jv.ice,
          onChanged: (v) => setState(() => _messagingAccess = v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.phone_rounded, color: Jv.ice),
          title: const Text('Phone Calls & Contacts'),
          subtitle: const Text('Place phone calls and look up contacts'),
          value: _callAccess,
          activeThumbColor: Jv.ice,
          onChanged: (v) => setState(() => _callAccess = v),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_active_rounded, color: Jv.ice),
          title: const Text('System Notifications'),
          subtitle: const Text('Post status bar notifications when tasks complete'),
          value: _notificationsAccess,
          activeThumbColor: Jv.ice,
          onChanged: (v) => setState(() => _notificationsAccess = v),
        ),
      ],
    );
  }

  Widget _buildStep4AiBrain() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.psychology_rounded, size: 48, color: Jv.ice),
        const SizedBox(height: 16),
        const Text(
          'AI Engine & Offline Mode',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Jv.text),
        ),
        const SizedBox(height: 8),
        const Text(
          'Choose whether Jarvis thinks locally with Ollama (completely offline) or uses a cloud provider.',
          style: TextStyle(fontSize: 14, color: Jv.textMuted),
        ),
        const SizedBox(height: 24),
        DropdownButtonFormField<LLMProvider>(
          initialValue: _selectedProvider,
          decoration: InputDecoration(
            labelText: 'Intelligence Provider',
            prefixIcon: const Icon(Icons.dns_rounded, color: Jv.ice),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
          items: LLMProvider.values.map((p) {
            return DropdownMenuItem(
              value: p,
              child: Text(
                p == LLMProvider.ollama
                    ? 'Ollama (Local & Offline)'
                    : p.displayName,
              ),
            );
          }).toList(),
          onChanged: (p) {
            if (p != null) setState(() => _selectedProvider = p);
          },
        ),
        const SizedBox(height: 20),
        if (_selectedProvider == LLMProvider.ollama) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Jv.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Jv.hairline(0.12)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.offline_bolt_rounded, color: Colors.greenAccent, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Offline Local Execution',
                      style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Jarvis will run directly on your machine or local network without sending data to external servers.',
                  style: TextStyle(fontSize: 12, color: Jv.textMuted),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _ollamaUrlController,
                  decoration: InputDecoration(
                    labelText: 'Ollama Base URL',
                    hintText: 'http://localhost:11434',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _ollamaModelController,
                  decoration: InputDecoration(
                    labelText: 'Model Name',
                    hintText: 'llama3.2:latest or qwen3.5:4b',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Jv.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Jv.hairline(0.12)),
            ),
            child: Text(
              'You can configure the ${_selectedProvider.displayName} API key right after setup in Settings.',
              style: const TextStyle(fontSize: 13, color: Jv.textMuted),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAppChoiceCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required String value,
    required List<Map<String, String>> options,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Jv.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Jv.hairline(0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Jv.ice, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: Jv.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: value,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            items: options.map((opt) {
              return DropdownMenuItem(value: opt['id'], child: Text(opt['label']!));
            }).toList(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final isLast = _currentPage == _totalPages - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      decoration: BoxDecoration(
        color: Jv.deep,
        border: Border(top: BorderSide(color: Jv.hairline(0.08))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_currentPage > 0)
            OutlinedButton(
              onPressed: _prevPage,
              child: const Text('Back'),
            )
          else
            const SizedBox.shrink(),
          ElevatedButton.icon(
            onPressed: _nextPage,
            icon: Icon(isLast ? Icons.check_circle_outline_rounded : Icons.arrow_forward_rounded),
            label: Text(isLast ? 'Complete Setup' : 'Continue'),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// App skill for opening and launching applications installed on the system.
class AppSkill extends JarvisSkill {
  @override
  String get name => 'open_apps';

  @override
  String get description => 'Launches device applications by name.';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();
    // Exclude music/timer commands that start with "open" or "start"
    if (lower.startsWith('open ') ||
        lower.startsWith('launch ') ||
        lower.startsWith('start app ')) {
      return true;
    }
    return false;
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final sir = context.userName;
    final match = RegExp(
      r'^(?:open|launch|start\s+app|start)\s+([a-zA-Z0-9_\s]+)$',
      caseSensitive: false,
    ).firstMatch(rawInput.trim());

    if (match == null) {
      return SkillResult.success('Which application would you like me to open, $sir?');
    }

    final appName = match.group(1)!.trim();
    await PlatformService.launchApp(appName);
    return SkillResult.success('Opening $appName, $sir.');
  }
}

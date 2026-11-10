import 'dart:async';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Reminder and alarm skill for setting wake-up calls and alarms.
class ReminderSkill extends JarvisSkill {
  @override
  String get name => 'reminders';

  @override
  String get description => 'Sets alarms and reminders.';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();
    return lower.contains('alarm') ||
        lower.contains('wake me up') ||
        lower.contains('remind me');
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final sir = context.userName;

    // e.g. "set alarm for 7:30", "alarm 08:00", "wake me up at 6:45"
    final alarmMatch = RegExp(
      r'(?:set\s+an?\s+alarm\s+(?:for|at)|alarm\s+(?:for|at)?|wake\s+me\s+up\s+at)\s+(\d{1,2}:\d{2})(?:\s*(am|pm))?',
      caseSensitive: false,
    ).firstMatch(rawInput.trim());

    if (alarmMatch != null) {
      final time = alarmMatch.group(1)!;
      final amPm = alarmMatch.group(2) != null ? ' ${alarmMatch.group(2)!.toUpperCase()}' : '';
      await PlatformService.setAlarm(time, 'Jarvis Alarm');
      return SkillResult.success('Alarm set for $time$amPm, $sir.');
    }

    // Generic note/reminder
    final reminderMatch = RegExp(
      r'^(?:remind\s+me\s+to|remind\s+me)\s+(.*)$',
      caseSensitive: false,
    ).firstMatch(rawInput.trim());
    if (reminderMatch != null) {
      final task = reminderMatch.group(1)!.trim();
      await PlatformService.showNotification('Jarvis Reminder', task);
      return SkillResult.success('I have set a reminder for "$task", $sir.');
    }

    return SkillResult.success('What time should I set the alarm for, $sir?');
  }
}

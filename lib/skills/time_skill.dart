import 'dart:async';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Time skill handling queries about current time, date, day, and timers.
class TimeSkill extends JarvisSkill {
  @override
  String get name => 'time';

  @override
  String get description => 'Answers time, date, day of week, and sets countdown timers.';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();
    if (lower.contains('what time') ||
        lower.contains('current time') ||
        lower == 'time' ||
        lower.contains('what day') ||
        lower.contains("today's date") ||
        lower.contains('what is the date') ||
        lower.contains('what date')) {
      return true;
    }
    if (lower.startsWith('timer ') ||
        lower.startsWith('set timer') ||
        lower.startsWith('set a timer')) {
      return true;
    }
    return false;
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final lower = rawInput.trim().toLowerCase();
    final sir = context.userName;
    final now = DateTime.now();

    // Timers: e.g. "set a timer for 5 minutes", "timer 30 seconds"
    final timerMatch = RegExp(
      r'(?:set\s+a?\s*timer\s+(?:for\s+)?|timer\s+(?:for\s+)?)(\d+)\s*(minute|second|min|sec)s?',
      caseSensitive: false,
    ).firstMatch(rawInput);
    if (timerMatch != null) {
      final count = int.tryParse(timerMatch.group(1)!) ?? 60;
      final unit = timerMatch.group(2)!.toLowerCase();
      final seconds = unit.startsWith('min') ? count * 60 : count;
      final unitName = unit.startsWith('min') ? 'minute' : 'second';
      final plural = count == 1 ? unitName : '${unitName}s';

      await PlatformService.performDeviceAction(
        'set_timer',
        arguments: {'seconds': seconds, 'label': 'Jarvis Timer'},
      );
      return SkillResult.success('Timer set for $count $plural, $sir.');
    }

    // Date / day
    if (lower.contains('what day') ||
        lower.contains("today's date") ||
        lower.contains('what is the date') ||
        lower.contains('what date')) {
      final weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      final months = [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ];
      final weekday = weekdays[now.weekday - 1];
      final month = months[now.month - 1];
      return SkillResult.success('Today is $weekday, $month ${now.day}, $sir.');
    }

    // Time
    final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final minute = now.minute.toString().padLeft(2, '0');
    final amPm = now.hour >= 12 ? 'PM' : 'AM';
    return SkillResult.success('The time is $hour:$minute $amPm, $sir.');
  }
}

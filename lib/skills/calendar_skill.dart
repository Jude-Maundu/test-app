import 'dart:async';
import 'package:test_app/services/calendar_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Calendar skill interfacing with the Google Calendar API v3.
/// Fetches and synthesizes schedule summaries with times, titles, locations,
/// and day gaps, and supports event creation with mandatory user confirmation.
class CalendarSkill extends JarvisSkill {
  CalendarSkill({GoogleCalendarService? calendarService})
      : _calendar = calendarService ?? GoogleCalendarService();

  final GoogleCalendarService _calendar;

  @override
  String get name => 'calendar';

  @override
  String get description =>
      'Interacts with Google Calendar to retrieve daily/weekly schedules and schedule new events.';

  static const String keyPendingEvent = 'pending_calendar_event';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();

    // 1. Pending event confirmation
    if (context.recall(keyPendingEvent) != null) {
      return true;
    }

    // 2. Schedule queries
    if (lower.contains('schedule') ||
        lower.contains('my calendar') ||
        lower.contains('what do i have today') ||
        lower.contains('what do i have tomorrow') ||
        lower.contains('what am i doing today') ||
        lower.contains('what am i doing tomorrow') ||
        lower.contains('upcoming events')) {
      return true;
    }

    // 3. Adding calendar events
    if (lower.startsWith('add ') && lower.contains('calendar') ||
        lower.startsWith('schedule ') ||
        lower.startsWith('create an event') ||
        lower.startsWith('create event')) {
      return true;
    }

    return false;
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final lower = rawInput.trim().toLowerCase();
    final sir = context.userName;

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Pending event confirmation
    // ─────────────────────────────────────────────────────────────────────────
    final pendingEvent = context.recallAs<Map<String, dynamic>>(keyPendingEvent);
    if (pendingEvent != null) {
      if (_isAffirmative(lower) || lower.contains('add it') || lower.contains('confirm')) {
        context.forget(keyPendingEvent);
        final title = pendingEvent['title'] as String;
        final startTime = pendingEvent['startTime'] as DateTime;
        final endTime = pendingEvent['endTime'] as DateTime;

        final createRes = await _calendar.createEvent(
          title: title,
          startTime: startTime,
          endTime: endTime,
        );

        if (createRes.startsWith('Error:')) {
          return SkillResult.success(
            'I encountered an issue adding the event, $sir: $createRes',
          );
        }
        return SkillResult.success('I have added "$title" to your calendar, $sir.');
      }

      if (lower == 'cancel' || lower == 'no' || lower == 'nevermind' || lower == 'discard') {
        context.forget(keyPendingEvent);
        return SkillResult.success('Calendar event cancelled, $sir.');
      }

      return SkillResult.followUp(
        'Shall I add this event to your calendar, $sir?',
      );
    }

    final now = DateTime.now();

    // ─────────────────────────────────────────────────────────────────────────
    // 2. "what's my schedule today / tomorrow / this week"
    // ─────────────────────────────────────────────────────────────────────────
    if (lower.contains('today') ||
        lower.contains('tomorrow') ||
        lower.contains('this week') ||
        lower.contains('schedule')) {
      final DateTime timeMin;
      final DateTime timeMax;
      final String dayLabel;

      if (lower.contains('tomorrow')) {
        final tomorrow = now.add(const Duration(days: 1));
        timeMin = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 0, 0, 0);
        timeMax = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 23, 59, 59);
        dayLabel = 'tomorrow';
      } else if (lower.contains('this week') || lower.contains('week')) {
        timeMin = DateTime(now.year, now.month, now.day, 0, 0, 0);
        final endOfWeek = now.add(Duration(days: 7 - now.weekday));
        timeMax = DateTime(endOfWeek.year, endOfWeek.month, endOfWeek.day, 23, 59, 59);
        dayLabel = 'this week';
      } else {
        // Default to today
        timeMin = DateTime(now.year, now.month, now.day, 0, 0, 0);
        timeMax = DateTime(now.year, now.month, now.day, 23, 59, 59);
        dayLabel = 'today';
      }

      final events = await _calendar.getEvents(timeMin: timeMin, timeMax: timeMax);
      final summary = GoogleCalendarService.formatNaturalScheduleSummary(
        events,
        dayLabel: dayLabel,
        userName: sir,
      );
      return SkillResult.success(summary);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. "add [event] to my calendar at [time]"
    // ─────────────────────────────────────────────────────────────────────────
    // e.g. "add Team Standup to my calendar at 3pm", "schedule Meeting with Dave at 10:00"
    final eventMatch = RegExp(
      r'^(?:add|schedule|create(?:\s+an?)?\s+event\s+for)\s+(.*?)\s+(?:to\s+(?:my\s+)?calendar\s+)?(?:at|for)\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)$',
      caseSensitive: false,
    ).firstMatch(rawInput.trim());

    if (eventMatch != null) {
      final title = eventMatch.group(1)!.trim().replaceAll(RegExp(r'\s+to\s+(?:my\s+)?calendar', caseSensitive: false), '');
      final timeStr = eventMatch.group(2)!.trim();
      final startTime = _parseDateTime(timeStr, now);
      final endTime = startTime.add(const Duration(hours: 1));

      context.remember(keyPendingEvent, {
        'title': title,
        'startTime': startTime,
        'endTime': endTime,
      });

      return SkillResult.followUp(
        'I have prepared the event "$title" for ${_formatTime(startTime)}. Shall I add it to your calendar, $sir?',
      );
    }

    return SkillResult.success(
      'What event would you like me to schedule, and at what time, $sir?',
    );
  }

  DateTime _parseDateTime(String timeStr, DateTime base) {
    final lower = timeStr.toLowerCase();
    int hour = 9;
    int minute = 0;

    final match = RegExp(r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)?').firstMatch(lower);
    if (match != null) {
      hour = int.tryParse(match.group(1)!) ?? 9;
      minute = int.tryParse(match.group(2) ?? '0') ?? 0;
      final amPm = match.group(3);
      if (amPm == 'pm' && hour < 12) hour += 12;
      if (amPm == 'am' && hour == 12) hour = 0;
    }

    return DateTime(base.year, base.month, base.day, hour, minute);
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    return minute == '00' ? '$hour $amPm' : '$hour:$minute $amPm';
  }

  bool _isAffirmative(String input) {
    final lower = input.trim().toLowerCase();
    return lower.startsWith('yes') ||
        lower.startsWith('yeah') ||
        lower.startsWith('sure') ||
        lower.startsWith('add') ||
        lower.startsWith('confirm') ||
        lower.startsWith('please') ||
        lower.startsWith('do it') ||
        lower.startsWith('okay') ||
        lower.startsWith('ok');
  }
}

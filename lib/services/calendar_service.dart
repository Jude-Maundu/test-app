import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:test_app/services/google_oauth_service.dart';

/// Service interfacing directly with the Google Calendar API v3
/// using OAuth 2.0 Bearer tokens.
class GoogleCalendarService {
  GoogleCalendarService({
    GoogleOAuthService? oauthService,
    http.Client? httpClient,
  })  : _oauthService = oauthService ?? GoogleOAuthService(),
        _client = httpClient ?? http.Client();

  final GoogleOAuthService _oauthService;
  final http.Client _client;

  static const String _calendarApiBase = 'https://www.googleapis.com/calendar/v3/calendars/primary';

  /// Fetches scheduled events within a time window.
  Future<List<Map<String, dynamic>>> getEvents({
    required DateTime timeMin,
    required DateTime timeMax,
  }) async {
    final token = await _oauthService.getValidAccessToken();
    if (token == null || token.isEmpty) {
      return [];
    }

    try {
      final uri = Uri.parse(
        '$_calendarApiBase/events?singleEvents=true&orderBy=startTime'
        '&timeMin=${Uri.encodeComponent(timeMin.toUtc().toIso8601String())}'
        '&timeMax=${Uri.encodeComponent(timeMax.toUtc().toIso8601String())}',
      );

      final response = await _client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode != 200) {
        debugPrint('Google Calendar API error: ${response.statusCode} - ${response.body}');
        return [];
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>?) ?? [];
      final results = <Map<String, dynamic>>[];

      for (final item in items) {
        final summary = item['summary'] as String? ?? 'Untitled Event';
        final location = item['location'] as String? ?? '';
        final description = item['description'] as String? ?? '';

        final startObj = item['start'] as Map<String, dynamic>? ?? {};
        final endObj = item['end'] as Map<String, dynamic>? ?? {};

        final startStr = (startObj['dateTime'] ?? startObj['date']) as String?;
        final endStr = (endObj['dateTime'] ?? endObj['date']) as String?;

        DateTime? startTime;
        DateTime? endTime;
        if (startStr != null) startTime = DateTime.tryParse(startStr);
        if (endStr != null) endTime = DateTime.tryParse(endStr);

        results.add({
          'id': item['id'],
          'summary': summary,
          'location': location,
          'description': description,
          'startTime': startTime,
          'endTime': endTime,
        });
      }

      return results;
    } catch (e) {
      debugPrint('Calendar getEvents error: $e');
      return [];
    }
  }

  /// Creates a calendar event on the user's primary Google Calendar.
  Future<String> createEvent({
    required String title,
    required DateTime startTime,
    required DateTime endTime,
    String? location,
    String? description,
  }) async {
    final token = await _oauthService.getValidAccessToken();
    if (token == null || token.isEmpty) {
      return 'Error: Google OAuth is not configured. Please set your credentials in Settings.';
    }

    try {
      final body = {
        'summary': title,
        if (location != null && location.isNotEmpty) 'location': location,
        if (description != null && description.isNotEmpty) 'description': description,
        'start': {
          'dateTime': startTime.toUtc().toIso8601String(),
        },
        'end': {
          'dateTime': endTime.toUtc().toIso8601String(),
        },
      };

      final response = await _client.post(
        Uri.parse('$_calendarApiBase/events'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return 'Event created successfully.';
      } else {
        return 'Error creating event (${response.statusCode}): ${response.body}';
      }
    } catch (e) {
      return 'Error creating calendar event: $e';
    }
  }

  /// Synthesizes events into a natural, spoken Jarvis summary including
  /// event titles, times, locations, and any gaps in the user's schedule.
  static String formatNaturalScheduleSummary(
    List<Map<String, dynamic>> events, {
    required String dayLabel,
    required String userName,
  }) {
    if (events.isEmpty) {
      return 'You have no events scheduled for $dayLabel, $userName. Your day is completely clear.';
    }

    final buffer = StringBuffer();
    final count = events.length;
    final plural = count == 1 ? 'event' : 'events';
    buffer.write('You have $count $plural scheduled for $dayLabel, $userName. ');

    for (int i = 0; i < events.length; i++) {
      final ev = events[i];
      final title = ev['summary'] as String;
      final startTime = ev['startTime'] as DateTime?;
      final endTime = ev['endTime'] as DateTime?;
      final location = ev['location'] as String;

      final timeStr = startTime != null ? _formatTime(startTime) : 'all day';
      buffer.write('$title at $timeStr');
      if (location.isNotEmpty) {
        buffer.write(' at $location');
      }

      // Calculate gap to the next event
      if (i < events.length - 1 && endTime != null) {
        final nextStart = events[i + 1]['startTime'] as DateTime?;
        if (nextStart != null && nextStart.isAfter(endTime)) {
          final gapDuration = nextStart.difference(endTime);
          if (gapDuration.inMinutes >= 30) {
            final gapHours = gapDuration.inHours;
            final gapMins = gapDuration.inMinutes % 60;
            String gapText = '';
            if (gapHours > 0 && gapMins > 0) {
              gapText = '$gapHours hours and $gapMins minutes';
            } else if (gapHours > 0) {
              gapText = gapHours == 1 ? '1 hour' : '$gapHours hours';
            } else {
              gapText = '$gapMins minutes';
            }
            buffer.write(', followed by a free window of $gapText until ${_formatTime(nextStart)}');
          }
        }
      }

      if (i < events.length - 1) {
        buffer.write('. ');
      } else {
        buffer.write('.');
      }
    }

    return buffer.toString();
  }

  static String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final amPm = local.hour >= 12 ? 'PM' : 'AM';
    return minute == '00' ? '$hour $amPm' : '$hour:$minute $amPm';
  }
}

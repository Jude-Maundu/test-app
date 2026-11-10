import 'dart:async';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Weather skill handling weather forecasts and conditions.
class WeatherSkill extends JarvisSkill {
  @override
  String get name => 'weather';

  @override
  String get description => 'Checks current weather and forecast for any location.';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();
    return lower.contains('weather') ||
        lower.contains('temperature') ||
        lower.contains('is it raining') ||
        lower.contains('is it going to rain') ||
        lower.contains('forecast');
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final lower = rawInput.trim().toLowerCase();
    final sir = context.userName;

    // Extract location if present (e.g., "weather in Paris", "weather for London")
    String location = '';
    final locMatch = RegExp(
      r'(?:weather|temperature|forecast)\s+(?:in|for|at)\s+([a-zA-Z\s]+)',
      caseSensitive: false,
    ).firstMatch(rawInput);
    if (locMatch != null) {
      location = locMatch.group(1)!.trim();
    }

    await PlatformService.performDeviceAction(
      'weatherSearch',
      arguments: {'location': location},
    );

    if (location.isNotEmpty) {
      return SkillResult.success('Opening the weather forecast for $location, $sir.');
    } else {
      return SkillResult.success('Checking the current weather conditions, $sir.');
    }
  }
}

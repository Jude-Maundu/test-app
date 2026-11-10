import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:test_app/services/llm_service.dart';
import 'package:test_app/skills/app_skill.dart';
import 'package:test_app/skills/calendar_skill.dart';
import 'package:test_app/skills/call_skill.dart';
import 'package:test_app/skills/creator_skill.dart';
import 'package:test_app/skills/email_skill.dart';
import 'package:test_app/skills/music_skill.dart';
import 'package:test_app/skills/reminder_skill.dart';
import 'package:test_app/skills/skill_base.dart';
import 'package:test_app/skills/time_skill.dart';
import 'package:test_app/skills/weather_skill.dart';

/// Central intent-classifier and skill router implementing a dictionary-based
/// command routing architecture with wake-word detection, conversational short-term
/// memory retention, and automatic LLM fallback.
class CommandRouter {
  CommandRouter({
    SkillContext? context,
    LLMService? llmService,
  })  : context = context ?? SkillContext(),
        _llmService = llmService ?? LLMService() {
    _registerDefaultSkills();
  }

  /// Persistent conversational short-term memory context.
  final SkillContext context;
  final LLMService _llmService;

  /// Dictionary of registered skills keyed by skill identifier.
  final Map<String, JarvisSkill> _skills = {};

  /// Read-only view of registered skills.
  Map<String, JarvisSkill> get skills => Map.unmodifiable(_skills);

  void _registerDefaultSkills() {
    registerSkill(MusicSkill());
    registerSkill(TimeSkill());
    registerSkill(WeatherSkill());
    registerSkill(AppSkill());
    registerSkill(CallSkill());
    registerSkill(EmailSkill());
    registerSkill(CalendarSkill());
    registerSkill(ReminderSkill());
    registerSkill(CreatorSkill());
  }

  /// Registers a new skill into the command router dictionary.
  void registerSkill(JarvisSkill skill) {
    _skills[skill.name] = skill;
  }

  /// Removes a skill from the command router by name.
  void unregisterSkill(String name) {
    _skills.remove(name);
  }

  /// Extracts the command following any wake phrase ("Jarvis", "Hey Jarvis", "OK Jarvis").
  /// Returns a record with:
  /// - `hadWakeWord`: whether a wake word was detected
  /// - `command`: the command portion with the wake phrase stripped
  /// - `isWakeWordOnly`: true if the user spoke only the wake word
  static ({bool hadWakeWord, String command, bool isWakeWordOnly}) parseWakeWord(String input) {
    final trimmed = input.trim();
    final wakeRegex = RegExp(
      r'^\s*(?:hey|ok|okay)?\s*\bjarvis\b[\s,:]*',
      caseSensitive: false,
    );

    final match = wakeRegex.firstMatch(trimmed);
    if (match != null) {
      final rest = trimmed.substring(match.end).trim();
      final cleanRest = rest.replaceAll(RegExp(r'^[,\s:]+'), '').trim();
      return (
        hadWakeWord: true,
        command: cleanRest,
        isWakeWordOnly: cleanRest.isEmpty,
      );
    }

    return (
      hadWakeWord: false,
      command: trimmed,
      isWakeWordOnly: false,
    );
  }

  /// Main routing method.
  /// 1. Processes wake word.
  /// 2. Dispatches to matching skill in dictionary.
  /// 3. Falls back to LLM API if no skill matches.
  Future<SkillResult> route(
    String rawInput, {
    bool requireWakeWord = false,
    Future<String> Function(String instruction)? customLlmFallback,
  }) async {
    final parsed = parseWakeWord(rawInput);

    // If wake word is strictly required and missing
    if (requireWakeWord && !parsed.hadWakeWord) {
      return SkillResult.notHandled('Wake word "Jarvis" was not detected.');
    }

    final sir = context.userName;

    // If user only said "Jarvis" or "Hey Jarvis"
    if (parsed.isWakeWordOnly) {
      final response = 'At your service, $sir. How may I assist you?';
      _recordTurn(rawInput, response);
      return SkillResult.success(response);
    }

    final effectiveCommand = parsed.hadWakeWord ? parsed.command : rawInput.trim();
    if (effectiveCommand.isEmpty) {
      final response = 'Yes, $sir? What can I do for you?';
      _recordTurn(rawInput, response);
      return SkillResult.success(response);
    }

    final normalized = effectiveCommand.toLowerCase();

    // ─────────────────────────────────────────────────────────────────────────
    // Route through skill dictionary
    // ─────────────────────────────────────────────────────────────────────────
    for (final entry in _skills.entries) {
      final skill = entry.value;
      if (skill.canHandle(normalized, context)) {
        try {
          final result = await skill.execute(effectiveCommand, context);
          if (result.handled) {
            context.remember('last_skill', skill.name);
            _recordTurn(rawInput, result.speechResponse);
            return result;
          }
        } catch (e) {
          debugPrint('Error executing skill "${skill.name}": $e');
        }
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fallback: Query LLM API so Jarvis answers naturally
    // ─────────────────────────────────────────────────────────────────────────
    try {
      final String fallbackResponse;
      if (customLlmFallback != null) {
        fallbackResponse = await customLlmFallback(effectiveCommand);
      } else {
        final llmResult = await _llmService.processCommand(
          effectiveCommand,
          history: List.unmodifiable(context.conversationHistory),
          allowTools: true,
        );
        fallbackResponse = llmResult['response'] as String? ??
            'I have processed your request, $sir.';
      }

      _recordTurn(rawInput, fallbackResponse);
      return SkillResult.success(fallbackResponse);
    } catch (e) {
      final errorMsg = 'My apologies, $sir. I encountered an issue processing that: $e';
      _recordTurn(rawInput, errorMsg);
      return SkillResult.success(errorMsg);
    }
  }

  void _recordTurn(String userText, String assistantText) {
    context.remember('last_command', userText);
    context.remember('last_response', assistantText);
    context.conversationHistory.add({'role': 'user', 'content': userText});
    context.conversationHistory.add({'role': 'assistant', 'content': assistantText});
    if (context.conversationHistory.length > 20) {
      context.conversationHistory.removeRange(
        0,
        context.conversationHistory.length - 20,
      );
    }
  }
}

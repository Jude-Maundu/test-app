import 'dart:async';

/// Short-term memory and conversational context maintained across turns.
class SkillContext {
  SkillContext({
    this.userName = 'sir',
    Map<String, dynamic>? initialMemory,
    List<Map<String, String>>? conversationHistory,
  })  : memory = initialMemory ?? <String, dynamic>{},
        conversationHistory = conversationHistory ?? <Map<String, String>>[];

  /// How Jarvis addresses the user ('sir', 'boss', or their name).
  String userName;

  /// Dynamic key-value store for session short-term memory.
  final Map<String, dynamic> memory;

  /// Recent turns for multi-turn conversational context.
  final List<Map<String, String>> conversationHistory;

  void remember(String key, dynamic value) {
    memory[key] = value;
  }

  dynamic recall(String key) => memory[key];

  T? recallAs<T>(String key) {
    final val = memory[key];
    return val is T ? val : null;
  }

  void forget(String key) {
    memory.remove(key);
  }

  void clearMemory() {
    memory.clear();
  }
}

/// The result returned by a skill execution.
class SkillResult {
  const SkillResult({
    required this.handled,
    required this.speechResponse,
    this.data,
    this.pendingFollowUp,
    this.requiresLlm = false,
  });

  /// True if the skill recognized and handled the command.
  final bool handled;

  /// The calm, polite, concise Jarvis speech output.
  final String speechResponse;

  /// Optional structured data or arguments.
  final Map<String, dynamic>? data;

  /// Question asked out loud to the user expecting a follow-up answer.
  final String? pendingFollowUp;

  /// Whether execution should fall back to an LLM.
  final bool requiresLlm;

  factory SkillResult.success(String speech, {Map<String, dynamic>? data}) =>
      SkillResult(
        handled: true,
        speechResponse: speech,
        data: data,
      );

  factory SkillResult.followUp(String question, {Map<String, dynamic>? data}) =>
      SkillResult(
        handled: true,
        speechResponse: question,
        pendingFollowUp: question,
        data: data,
      );

  factory SkillResult.notHandled([String reason = '']) => SkillResult(
        handled: false,
        speechResponse: reason,
        requiresLlm: true,
      );
}

/// Base contract for all modular Jarvis skills.
abstract class JarvisSkill {
  /// Unique identifier of the skill (e.g. 'music', 'time', 'weather').
  String get name;

  /// Brief description of what this skill handles.
  String get description;

  /// Returns true if this skill can handle the given normalized input.
  bool canHandle(String normalizedInput, SkillContext context);

  /// Executes the skill and returns the Jarvis response.
  Future<SkillResult> execute(String rawInput, SkillContext context);
}

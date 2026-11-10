import 'dart:async';
import 'package:test_app/services/offline_intent_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Creator skill answering identity queries ("who created you").
class CreatorSkill extends JarvisSkill {
  @override
  String get name => 'creator';

  @override
  String get description => 'Answers questions about the creator of Jarvis.';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    return OfflineIntentService.isCreatorQuery(normalizedInput);
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    return SkillResult.success('I was created by Jude.');
  }
}

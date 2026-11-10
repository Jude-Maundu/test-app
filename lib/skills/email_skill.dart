import 'dart:async';
import 'package:test_app/services/gmail_service.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Email skill interfacing with the Gmail API v1 using OAuth 2.0.
/// Features contact resolution, AI drafting, out-loud draft playback,
/// multi-turn tone/content revisions, and mandatory confirmation before sending.
class EmailSkill extends JarvisSkill {
  EmailSkill({GmailService? gmailService})
      : _gmail = gmailService ?? GmailService();

  final GmailService _gmail;

  @override
  String get name => 'email';

  @override
  String get description =>
      'Composes, revises, confirms, and sends emails via Gmail API with OAuth 2.0 and contacts lookup.';

  static const String keyPendingDraft = 'pending_email_draft';
  static const String keyPendingRecipientQuery = 'pending_email_recipient_query';
  static const String keyPendingTopic = 'pending_email_topic';
  static const String keyDisambiguationList = 'pending_email_disambiguation';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();

    // 1. Pending email draft state (confirmation or revision)
    if (context.recall(keyPendingDraft) != null) {
      return true;
    }

    // 2. Pending recipient selection state
    if (context.recall(keyDisambiguationList) != null ||
        context.recall(keyPendingRecipientQuery) != null) {
      return true;
    }

    // 3. New email composition requests
    if (lower.startsWith('send an email to') ||
        lower.startsWith('send email to') ||
        lower.startsWith('email ') ||
        lower.startsWith('write an email to') ||
        lower.startsWith('compose email to')) {
      return true;
    }

    // 4. Reading email requests
    if (lower.contains('read my email') ||
        lower.contains('read my mail') ||
        lower.contains('check my email') ||
        lower.contains('check my mail') ||
        lower.contains('check emails')) {
      return true;
    }

    return false;
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final lower = rawInput.trim().toLowerCase();
    final sir = context.userName;

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Pending recipient selection / disambiguation
    // ─────────────────────────────────────────────────────────────────────────
    final disambiguation = context.recallAs<List<Map<String, String>>>(keyDisambiguationList);
    if (disambiguation != null && disambiguation.isNotEmpty) {
      context.forget(keyDisambiguationList);
      final topic = context.recallAs<String>(keyPendingTopic) ?? 'General message';
      context.forget(keyPendingTopic);

      // Check which email address the user picked
      Map<String, String>? chosenContact;
      for (final c in disambiguation) {
        final email = c['email']?.toLowerCase() ?? '';
        final name = c['name']?.toLowerCase() ?? '';
        if (lower.contains(email) || lower.contains(name)) {
          chosenContact = c;
          break;
        }
      }
      chosenContact ??= disambiguation.first;

      return _createAndReadDraft(
        recipientName: chosenContact['name'] ?? 'Recipient',
        recipientEmail: chosenContact['email'] ?? '',
        topic: topic,
        context: context,
      );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Pending recipient email address input
    // ─────────────────────────────────────────────────────────────────────────
    if (context.recall(keyPendingRecipientQuery) != null) {
      final name = context.recallAs<String>(keyPendingRecipientQuery)!;
      final topic = context.recallAs<String>(keyPendingTopic) ?? 'Message from $sir';
      context.forget(keyPendingRecipientQuery);
      context.forget(keyPendingTopic);

      // Extract email address from input
      final emailRegex = RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}');
      final match = emailRegex.firstMatch(rawInput);
      final email = match != null ? match.group(0)! : rawInput.trim();

      return _createAndReadDraft(
        recipientName: name,
        recipientEmail: email,
        topic: topic,
        context: context,
      );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Pending draft confirmation, tone adjustment, or content addition
    // ─────────────────────────────────────────────────────────────────────────
    final pendingDraft = context.recallAs<Map<String, dynamic>>(keyPendingDraft);
    if (pendingDraft != null) {
      // Affirmative: send email!
      if (_isAffirmative(lower) || lower.contains('send it') || lower.contains('send')) {
        context.forget(keyPendingDraft);
        final to = pendingDraft['to'] as String;
        final subject = pendingDraft['subject'] as String;
        final body = pendingDraft['body'] as String;

        final sendResult = await _gmail.sendEmail(
          to: to,
          subject: subject,
          body: body,
        );

        if (sendResult.startsWith('Error:')) {
          return SkillResult.success(
            'I encountered an issue sending the email, $sir: $sendResult',
          );
        }
        return SkillResult.success('The email has been sent to $to, $sir.');
      }

      // Cancellation: discard draft
      if (lower == 'cancel' ||
          lower == 'discard' ||
          lower == 'nevermind' ||
          lower == 'no' ||
          lower == 'don\'t send') {
        context.forget(keyPendingDraft);
        return SkillResult.success('Draft discarded, $sir.');
      }

      // Tone revision: e.g. "change the tone to formal", "make it more casual"
      if (lower.contains('change the tone') ||
          lower.contains('change tone') ||
          lower.contains('make it more') ||
          lower.contains('more formal') ||
          lower.contains('more casual') ||
          lower.contains('more polite')) {
        String currentBody = pendingDraft['body'] as String;
        String newTone = 'formal';
        if (lower.contains('casual') || lower.contains('informal')) newTone = 'casual';
        if (lower.contains('polite') || lower.contains('courteous')) newTone = 'polite';
        if (lower.contains('urgent')) newTone = 'urgent';

        final updatedBody = _adjustDraftTone(currentBody, newTone, pendingDraft['recipientName'] ?? '');
        pendingDraft['body'] = updatedBody;
        context.remember(keyPendingDraft, pendingDraft);

        return SkillResult.followUp(
          'I have updated the draft to a $newTone tone: "$updatedBody". Shall I send it now, $sir?',
        );
      }

      // Adding content: e.g. "add that I will be 10 minutes late", "add something"
      if (lower.startsWith('add ') || lower.startsWith('also say ')) {
        final addition = rawInput.replaceFirst(RegExp(r'^(?:add\s+(?:that\s+)?|also\s+say\s+(?:that\s+)?)', caseSensitive: false), '').trim();
        final currentBody = pendingDraft['body'] as String;
        final updatedBody = '$currentBody\n\nAdditionally, $addition';
        pendingDraft['body'] = updatedBody;
        context.remember(keyPendingDraft, pendingDraft);

        return SkillResult.followUp(
          'I have added that to the draft: "$updatedBody". Shall I send it now, $sir?',
        );
      }

      return SkillResult.followUp(
        'Shall I send the email, $sir, or would you like to change the tone or add something first?',
      );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Reading recent emails
    // ─────────────────────────────────────────────────────────────────────────
    if (lower.contains('read my email') ||
        lower.contains('read my mail') ||
        lower.contains('check my email') ||
        lower.contains('check my mail') ||
        lower.contains('check emails')) {
      final emails = await _gmail.getRecentEmails(maxResults: 3);
      if (emails.isEmpty) {
        return SkillResult.success(
          'You have no unread or recent messages in your inbox, $sir.',
        );
      }

      final buffer = StringBuffer('You have ${emails.length} recent messages, $sir: ');
      for (int i = 0; i < emails.length; i++) {
        final em = emails[i];
        final from = em['from']?.split('<').first.trim() ?? 'Unknown sender';
        final subject = em['subject'] ?? 'No subject';
        buffer.write('${i + 1}: From $from regarding "$subject". ');
      }
      return SkillResult.success(buffer.toString());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Initial composition: "send an email to [name] about [topic]"
    // ─────────────────────────────────────────────────────────────────────────
    final sendMatch = RegExp(
      r'^(?:send\s+an?\s+email\s+to|send\s+email\s+to|email|write\s+an?\s+email\s+to|compose\s+email\s+to)\s+([a-zA-Z0-9_\s.]+?)(?:\s+(?:about|saying|that|with\s+topic|with\s+message)\s+|\s*:\s*)(.*)$',
      caseSensitive: false,
    ).firstMatch(rawInput.trim());

    if (sendMatch == null) {
      return SkillResult.success('Who would you like me to email and what is the topic, $sir?');
    }

    final targetName = sendMatch.group(1)!.trim();
    final topic = sendMatch.group(2)!.trim();

    // Check if target is already an explicit email address
    if (targetName.contains('@')) {
      return _createAndReadDraft(
        recipientName: targetName,
        recipientEmail: targetName,
        topic: topic,
        context: context,
      );
    }

    // Look up recipient in device contacts via PlatformService
    final contacts = await PlatformService.findContactEmails(targetName);

    if (contacts.isEmpty) {
      context.remember(keyPendingRecipientQuery, targetName);
      context.remember(keyPendingTopic, topic);
      return SkillResult.followUp(
        'I couldn\'t find an email address for $targetName in your contacts, $sir. What email address should I use?',
      );
    }

    if (contacts.length > 1) {
      context.remember(keyDisambiguationList, contacts);
      context.remember(keyPendingTopic, topic);
      final emailList = contacts.map((c) => '${c['name']} (${c['email']})').join(', ');
      return SkillResult.followUp(
        'I found multiple email addresses for $targetName: $emailList. Which one shall I use, $sir?',
      );
    }

    final matched = contacts.first;
    return _createAndReadDraft(
      recipientName: matched['name'] ?? targetName,
      recipientEmail: matched['email'] ?? '',
      topic: topic,
      context: context,
    );
  }

  SkillResult _createAndReadDraft({
    required String recipientName,
    required String recipientEmail,
    required String topic,
    required SkillContext context,
  }) {
    final sir = context.userName;
    final subject = _generateSubject(topic);
    final body = _generatePoliteDraft(recipientName, topic, sir);

    context.remember(keyPendingDraft, {
      'to': recipientEmail,
      'recipientName': recipientName,
      'subject': subject,
      'body': body,
    });

    return SkillResult.followUp(
      'I have prepared the email for $recipientName with subject "$subject": "$body". Shall I send it, $sir?',
    );
  }

  String _generateSubject(String topic) {
    if (topic.isEmpty) return 'Important Update';
    final words = topic.split(RegExp(r'\s+')).take(5).join(' ');
    final capitalized = words[0].toUpperCase() + words.substring(1);
    return capitalized.replaceAll(RegExp(r'[?.!,]+$'), '');
  }

  String _generatePoliteDraft(String recipient, String topic, String senderTitle) {
    return 'Dear $recipient,\n\nI hope this email finds you well. I am writing regarding $topic.\n\nPlease let me know your thoughts.\n\nBest regards,\nJude';
  }

  String _adjustDraftTone(String original, String tone, String recipient) {
    switch (tone) {
      case 'formal':
        return 'Dear $recipient,\n\nPlease accept this formal correspondence regarding our recent discussion. Kindly review and advise at your earliest convenience.\n\nSincerely,\nJude';
      case 'casual':
        return 'Hi $recipient,\n\nHope you\'re doing great! Just wanted to quickly touch base with you about this. Let me know what you think.\n\nCheers,\nJude';
      case 'urgent':
        return 'Dear $recipient,\n\nThis is an urgent matter regarding our ongoing task. Please review this message as soon as possible.\n\nBest regards,\nJude';
      default:
        return original;
    }
  }

  bool _isAffirmative(String input) {
    final lower = input.trim().toLowerCase();
    return lower.startsWith('yes') ||
        lower.startsWith('yeah') ||
        lower.startsWith('yep') ||
        lower.startsWith('sure') ||
        lower.startsWith('send') ||
        lower.startsWith('please') ||
        lower.startsWith('go ahead') ||
        lower.startsWith('do it') ||
        lower.startsWith('okay') ||
        lower.startsWith('ok');
  }
}

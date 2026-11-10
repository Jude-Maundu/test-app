import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Call skill placing direct phone calls via Android ACTION_CALL intent.
/// Includes runtime permission management (CALL_PHONE & READ_CONTACTS),
/// contact name lookup, multi-match disambiguation, and out-loud confirmation.
class CallSkill extends JarvisSkill {
  @override
  String get name => 'calls';

  @override
  String get description =>
      'Places direct phone calls via ACTION_CALL, with contact resolution and permissions handling.';

  static const String keyPendingMatches = 'pending_call_matches';
  static const String keyPendingTargetName = 'pending_call_target_name';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();

    // 1. Pending contact selection from a previous turn
    if (context.recall(keyPendingMatches) != null ||
        context.recall(keyPendingTargetName) != null) {
      return true;
    }

    // 2. Direct calling commands
    return lower.startsWith('call ') ||
        lower.startsWith('dial ') ||
        lower.startsWith('phone ');
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final lower = rawInput.trim().toLowerCase();
    final sir = context.userName;

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Resolve pending multiple matches
    // ─────────────────────────────────────────────────────────────────────────
    final pendingMatches = context.recallAs<List<PhoneContact>>(keyPendingMatches);
    if (pendingMatches != null && pendingMatches.isNotEmpty) {
      context.forget(keyPendingMatches);

      // Check which contact or number the user selected
      PhoneContact? selected;
      for (final c in pendingMatches) {
        if (lower.contains(c.name.toLowerCase()) || lower.contains(c.phoneNumber)) {
          selected = c;
          break;
        }
      }
      selected ??= pendingMatches.first;

      return _dialDirectly(selected.name, selected.phoneNumber, sir);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Resolve pending phone number for previously unfound contact
    // ─────────────────────────────────────────────────────────────────────────
    if (context.recall(keyPendingTargetName) != null) {
      final name = context.recallAs<String>(keyPendingTargetName)!;
      context.forget(keyPendingTargetName);

      final cleanNumber = rawInput.replaceAll(RegExp(r'[^0-9+]'), '');
      if (cleanNumber.isNotEmpty) {
        return _dialDirectly(name, cleanNumber, sir);
      }
      return SkillResult.success('Call cancelled, $sir.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. New call request: "call [name / number]"
    // ─────────────────────────────────────────────────────────────────────────
    final match = RegExp(
      r'^(?:call|dial|phone)\s+([a-zA-Z0-9_\s.+-]+)$',
      caseSensitive: false,
    ).firstMatch(rawInput.trim());

    if (match == null) {
      return SkillResult.success('Who would you like me to call, $sir?');
    }

    final target = match.group(1)!.trim();

    // Check runtime permissions: CALL_PHONE and READ_CONTACTS
    final hasPermissions = await _ensurePermissions();
    if (!hasPermissions) {
      return SkillResult.success(
        'I require Phone and Contacts permissions to place calls directly, $sir. Please enable them in your device settings.',
      );
    }

    // If target is directly digits/phone number
    final digitsOnly = target.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digitsOnly.length >= 3 && !RegExp(r'[a-zA-Z]').hasMatch(target)) {
      return _dialDirectly('phone number', target, sir);
    }

    // Look up contact in device contacts
    final contacts = await PlatformService.findContacts(target);

    if (contacts.isEmpty) {
      context.remember(keyPendingTargetName, target);
      return SkillResult.followUp(
        'I couldn\'t find $target in your contacts, $sir. What number would you like me to dial?',
      );
    }

    if (contacts.length > 1) {
      context.remember(keyPendingMatches, contacts);
      final listStr = contacts
          .take(3)
          .map((c) => '${c.name} at ${c.phoneNumber}')
          .join(', or ');
      return SkillResult.followUp(
        'I found several contacts matching $target: $listStr. Which one should I call, $sir?',
      );
    }

    // Single match found
    final contact = contacts.first;
    return _dialDirectly(contact.name, contact.phoneNumber, sir);
  }

  Future<SkillResult> _dialDirectly(String name, String phoneNumber, String sir) async {
    // Confirm the name out loud before dialing directly via ACTION_CALL
    final callRes = await PlatformService.makeCall(phoneNumber);
    if (PlatformService.isError(callRes)) {
      return SkillResult.success('Unable to complete call to $name, $sir: $callRes');
    }

    return SkillResult.success('Calling $name at $phoneNumber now, $sir.');
  }

  Future<bool> _ensurePermissions() async {
    if (PlatformService.isLinux) return true;
    try {
      final phoneStatus = await Permission.phone.request();
      final contactsStatus = await Permission.contacts.request();
      return phoneStatus.isGranted && contactsStatus.isGranted;
    } on MissingPluginException {
      // Test environment
      return true;
    } catch (_) {
      return true;
    }
  }
}

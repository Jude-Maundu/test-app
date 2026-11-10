import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/skills/skill_base.dart';

/// Music skill providing Android MediaStore intent-based music playback,
/// playback controls (pause, resume, next, previous, volume), YouTube routing,
/// and short-term memory for contextual requests like "play it again".
class MusicSkill extends JarvisSkill {
  @override
  String get name => 'music';

  @override
  String get description =>
      'Controls music playback, volume, and song requests via default music player or YouTube.';

  static const String keyLastPlayedQuery = 'last_played_query';
  static const String keyLastPlayedTitle = 'last_played_title';
  static const String keyLastPlayedArtist = 'last_played_artist';
  static const String keyLastPlayedYouTube = 'last_played_youtube';
  static const String keyPendingAction = 'pending_music_action';
  static const String keyPendingQuery = 'pending_music_query';

  @override
  bool canHandle(String normalizedInput, SkillContext context) {
    final lower = normalizedInput.trim().toLowerCase();

    // 1. Pending follow-up question ("Would you like me to play it on YouTube instead?")
    if (context.recall(keyPendingAction) == 'ask_youtube') {
      return true;
    }

    // 2. Short-term memory requests
    if (lower == 'play it again' ||
        lower == 'play that again' ||
        lower == 'replay' ||
        lower == 'replay that' ||
        lower == 'play it one more time') {
      return true;
    }
    if (lower.startsWith('play something similar') ||
        lower.startsWith('play similar music') ||
        lower.startsWith('play more like this')) {
      return true;
    }

    // 3. Playback and volume controls
    if (lower == 'pause' ||
        lower == 'pause music' ||
        lower == 'stop music' ||
        lower == 'halt music' ||
        lower == 'halt') {
      return true;
    }
    if (lower == 'resume' ||
        lower == 'resume music' ||
        lower == 'unpause' ||
        lower == 'continue music' ||
        lower == 'play' ||
        lower == 'play music') {
      return true;
    }
    if (lower == 'next' ||
        lower == 'next song' ||
        lower == 'next track' ||
        lower == 'skip' ||
        lower == 'skip song' ||
        lower == 'skip track') {
      return true;
    }
    if (lower == 'previous' ||
        lower == 'previous song' ||
        lower == 'previous track' ||
        lower == 'go back' ||
        lower == 'last song') {
      return true;
    }
    if (lower == 'volume up' ||
        lower == 'increase volume' ||
        lower == 'turn it up' ||
        lower == 'louder' ||
        lower == 'more volume') {
      return true;
    }
    if (lower == 'volume down' ||
        lower == 'decrease volume' ||
        lower == 'turn it down' ||
        lower == 'softer' ||
        lower == 'lower volume' ||
        lower == 'less volume') {
      return true;
    }

    // 4. Play song / artist requests
    if (lower.startsWith('play ') || lower.startsWith('listen to ')) {
      return true;
    }

    return false;
  }

  @override
  Future<SkillResult> execute(String rawInput, SkillContext context) async {
    final lower = rawInput.trim().toLowerCase();
    final sir = context.userName;

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Pending follow-up: user responding to "Would you like YouTube instead?"
    // ─────────────────────────────────────────────────────────────────────────
    if (context.recall(keyPendingAction) == 'ask_youtube') {
      final pendingQuery = context.recallAs<String>(keyPendingQuery) ?? '';
      context.forget(keyPendingAction);
      context.forget(keyPendingQuery);

      if (_isAffirmative(lower) || lower.contains('youtube') || lower.contains('sure')) {
        await PlatformService.playMediaFromSearch(
          query: pendingQuery,
          isYouTube: true,
        );
        context.remember(keyLastPlayedQuery, pendingQuery);
        context.remember(keyLastPlayedYouTube, true);
        return SkillResult.success('Playing "$pendingQuery" on YouTube, $sir.');
      } else {
        return SkillResult.success(
          'Very well, $sir. Let me know what you would prefer instead.',
        );
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Conversational short-term memory: "play it again"
    // ─────────────────────────────────────────────────────────────────────────
    if (lower == 'play it again' ||
        lower == 'play that again' ||
        lower == 'replay' ||
        lower == 'replay that' ||
        lower == 'play it one more time') {
      final lastQuery = context.recallAs<String>(keyLastPlayedQuery);
      if (lastQuery == null || lastQuery.isEmpty) {
        return SkillResult.success(
          'We haven\'t played any music recently, $sir. What track or artist would you like?',
        );
      }

      final wasYouTube = context.recallAs<bool>(keyLastPlayedYouTube) ?? false;
      final result = await PlatformService.playMediaFromSearch(
        query: lastQuery,
        isYouTube: wasYouTube,
      );

      if (_isNoMusicApp(result)) {
        return _handleNoMusicAppFound(lastQuery, context);
      }
      return SkillResult.success('Replaying "$lastQuery", $sir.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Conversational short-term memory: "play something similar"
    // ─────────────────────────────────────────────────────────────────────────
    if (lower.startsWith('play something similar') ||
        lower.startsWith('play similar music') ||
        lower.startsWith('play more like this')) {
      final lastArtist = context.recallAs<String>(keyLastPlayedArtist);
      final lastQuery = context.recallAs<String>(keyLastPlayedQuery);
      final seed = lastArtist ?? lastQuery;

      if (seed == null || seed.isEmpty) {
        return SkillResult.success(
          'I don\'t have a recent artist on record, $sir. Which artist or genre should I base it on?',
        );
      }

      final similarQuery = 'music similar to $seed';
      final result = await PlatformService.playMediaFromSearch(
        query: similarQuery,
        isYouTube: false,
      );

      if (_isNoMusicApp(result)) {
        return _handleNoMusicAppFound(similarQuery, context);
      }

      context.remember(keyLastPlayedQuery, similarQuery);
      context.remember(keyLastPlayedYouTube, false);
      return SkillResult.success('Playing music similar to $seed, $sir.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Playback and volume controls
    // ─────────────────────────────────────────────────────────────────────────
    if (lower == 'pause' ||
        lower == 'pause music' ||
        lower == 'stop music' ||
        lower == 'halt music' ||
        lower == 'halt') {
      await PlatformService.mediaControl('pause');
      return SkillResult.success('Paused, $sir.');
    }

    if (lower == 'resume' ||
        lower == 'resume music' ||
        lower == 'unpause' ||
        lower == 'continue music' ||
        lower == 'play' ||
        lower == 'play music') {
      await PlatformService.mediaControl('resume');
      return SkillResult.success('Resuming playback, $sir.');
    }

    if (lower == 'next' ||
        lower == 'next song' ||
        lower == 'next track' ||
        lower == 'skip' ||
        lower == 'skip song' ||
        lower == 'skip track') {
      await PlatformService.mediaControl('next');
      return SkillResult.success('Skipping to the next track, $sir.');
    }

    if (lower == 'previous' ||
        lower == 'previous song' ||
        lower == 'previous track' ||
        lower == 'go back' ||
        lower == 'last song') {
      await PlatformService.mediaControl('previous');
      return SkillResult.success('Returning to the previous track, $sir.');
    }

    if (lower == 'volume up' ||
        lower == 'increase volume' ||
        lower == 'turn it up' ||
        lower == 'louder' ||
        lower == 'more volume') {
      await PlatformService.mediaControl('volume_up');
      return SkillResult.success('Volume increased, $sir.');
    }

    if (lower == 'volume down' ||
        lower == 'decrease volume' ||
        lower == 'turn it down' ||
        lower == 'softer' ||
        lower == 'lower volume' ||
        lower == 'less volume') {
      await PlatformService.mediaControl('volume_down');
      return SkillResult.success('Volume decreased, $sir.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. "play [song or artist]" request
    // ─────────────────────────────────────────────────────────────────────────
    String query = rawInput.trim();
    if (query.toLowerCase().startsWith('play ')) {
      query = query.substring(5).trim();
    } else if (query.toLowerCase().startsWith('listen to ')) {
      query = query.substring(10).trim();
    }

    // Explicit YouTube check: ONLY use YouTube if user explicitly says "on YouTube"
    bool isYouTube = false;
    final ytRegex = RegExp(r'\s+on\s+youtube\b', caseSensitive: false);
    if (ytRegex.hasMatch(query)) {
      isYouTube = true;
      query = query.replaceAll(ytRegex, '').trim();
    }

    // Strip trailing punctuation
    query = query.replaceAll(RegExp(r'[?.!,]+$'), '').trim();

    if (query.isEmpty) {
      return SkillResult.success('What would you like me to play, $sir?');
    }

    // Parse potential "song by artist" pattern
    String? title;
    String? artist;
    final byMatch = RegExp(r'^(.*?)\s+by\s+(.*)$', caseSensitive: false).firstMatch(query);
    if (byMatch != null) {
      title = byMatch.group(1)?.trim();
      artist = byMatch.group(2)?.trim();
    }

    // Send intent to Android default music player (MEDIA_PLAY_FROM_SEARCH) or YouTube
    final result = await PlatformService.playMediaFromSearch(
      query: query,
      isYouTube: isYouTube,
      artist: artist,
      title: title,
    );

    // If no music player app can handle the request
    if (_isNoMusicApp(result)) {
      return _handleNoMusicAppFound(query, context);
    }

    // Save into short-term memory
    context.remember(keyLastPlayedQuery, query);
    context.remember(keyLastPlayedTitle, title ?? query);
    context.remember(keyLastPlayedArtist, artist);
    context.remember(keyLastPlayedYouTube, isYouTube);

    if (isYouTube) {
      return SkillResult.success('Playing "$query" on YouTube, $sir.');
    } else {
      return SkillResult.success('Playing "$query", $sir.');
    }
  }

  bool _isAffirmative(String input) {
    final lower = input.trim().toLowerCase();
    return lower.startsWith('yes') ||
        lower.startsWith('yeah') ||
        lower.startsWith('yep') ||
        lower.startsWith('sure') ||
        lower.startsWith('please') ||
        lower.startsWith('go ahead') ||
        lower.startsWith('do it') ||
        lower.startsWith('okay') ||
        lower.startsWith('ok');
  }

  bool _isNoMusicApp(String result) {
    final lower = result.toLowerCase();
    return lower.contains('no_music_app') ||
        lower.contains('no music player') ||
        lower.contains('no music app');
  }

  SkillResult _handleNoMusicAppFound(String query, SkillContext context) {
    context.remember(keyPendingAction, 'ask_youtube');
    context.remember(keyPendingQuery, query);
    final sir = context.userName;
    return SkillResult.followUp(
      'I couldn\'t find a music player installed on your device to handle that, $sir. Would you like me to play it on YouTube instead?',
    );
  }
}

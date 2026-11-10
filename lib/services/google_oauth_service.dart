import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Handles Google OAuth 2.0 authentication, secure token storage, and automatic
/// access token refresh for Gmail and Google Calendar APIs.
class GoogleOAuthService {
  GoogleOAuthService({
    FlutterSecureStorage? storage,
    http.Client? httpClient,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _client = httpClient ?? http.Client();

  final FlutterSecureStorage _storage;
  final http.Client _client;

  static const String _keyClientId = 'google_oauth_client_id';
  static const String _keyClientSecret = 'google_oauth_client_secret';
  static const String _keyRefreshToken = 'google_oauth_refresh_token';
  static const String _keyAccessToken = 'google_oauth_access_token';
  static const String _keyExpiry = 'google_oauth_token_expiry';

  // OAuth 2.0 Scopes required by Jarvis
  static const String scopeGmailSend = 'https://www.googleapis.com/auth/gmail.send';
  static const String scopeGmailReadonly = 'https://www.googleapis.com/auth/gmail.readonly';
  static const String scopeCalendar = 'https://www.googleapis.com/auth/calendar.events';
  static const String scopeCalendarReadonly = 'https://www.googleapis.com/auth/calendar.readonly';

  static const List<String> allScopes = [
    scopeGmailSend,
    scopeGmailReadonly,
    scopeCalendar,
    scopeCalendarReadonly,
  ];

  /// Stores OAuth credentials securely in encrypted storage.
  /// Never hardcode API keys or tokens in source code!
  Future<void> storeCredentials({
    required String clientId,
    String? clientSecret,
    required String refreshToken,
    String? accessToken,
    int? expiresInSeconds,
  }) async {
    await _storage.write(key: _keyClientId, value: clientId.trim());
    if (clientSecret != null && clientSecret.isNotEmpty) {
      await _storage.write(key: _keyClientSecret, value: clientSecret.trim());
    }
    await _storage.write(key: _keyRefreshToken, value: refreshToken.trim());

    if (accessToken != null && accessToken.isNotEmpty) {
      await _storage.write(key: _keyAccessToken, value: accessToken.trim());
      final expiryTime = DateTime.now().millisecondsSinceEpoch +
          ((expiresInSeconds ?? 3600) * 1000);
      await _storage.write(key: _keyExpiry, value: expiryTime.toString());
    }
  }

  /// Returns true if valid Google OAuth credentials have been configured.
  Future<bool> isAuthenticated() async {
    final refreshToken = await _storage.read(key: _keyRefreshToken);
    final accessToken = await _storage.read(key: _keyAccessToken);
    return (refreshToken != null && refreshToken.isNotEmpty) ||
        (accessToken != null && accessToken.isNotEmpty);
  }

  /// Retrieves a valid access token. Automatically exchanges refresh_token
  /// with Google's OAuth endpoint if the current access token is expired.
  Future<String?> getValidAccessToken() async {
    final token = await _storage.read(key: _keyAccessToken);
    final expiryStr = await _storage.read(key: _keyExpiry);
    final expiryMillis = int.tryParse(expiryStr ?? '') ?? 0;

    // Check if current access token is still valid (with 60-second safety margin)
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    if (token != null && token.isNotEmpty && expiryMillis > nowMillis + 60000) {
      return token;
    }

    // Refresh token using Google OAuth 2.0 token endpoint
    return await refreshAccessToken();
  }

  /// Exchanges the stored refresh token for a fresh access token.
  Future<String?> refreshAccessToken() async {
    final refreshToken = await _storage.read(key: _keyRefreshToken);
    final clientId = await _storage.read(key: _keyClientId);
    final clientSecret = await _storage.read(key: _keyClientSecret);

    if (refreshToken == null || refreshToken.isEmpty || clientId == null) {
      return null;
    }

    try {
      final response = await _client.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          if (clientSecret != null && clientSecret.isNotEmpty)
            'client_secret': clientSecret,
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final newAccessToken = data['access_token'] as String?;
        final expiresIn = data['expires_in'] as int? ?? 3600;

        if (newAccessToken != null && newAccessToken.isNotEmpty) {
          await _storage.write(key: _keyAccessToken, value: newAccessToken);
          final expiryTime = DateTime.now().millisecondsSinceEpoch + (expiresIn * 1000);
          await _storage.write(key: _keyExpiry, value: expiryTime.toString());
          return newAccessToken;
        }
      } else {
        debugPrint('Google OAuth token refresh error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Google OAuth token refresh network failure: $e');
    }

    // Fall back to stored token if network failed
    return await _storage.read(key: _keyAccessToken);
  }

  /// Clears stored OAuth tokens upon user sign-out.
  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyAccessToken);
    await _storage.delete(key: _keyRefreshToken);
    await _storage.delete(key: _keyExpiry);
  }
}

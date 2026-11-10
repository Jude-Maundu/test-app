import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:test_app/services/google_oauth_service.dart';

/// Service interfacing directly with the Google Gmail REST API v1
/// using OAuth 2.0 Bearer tokens.
class GmailService {
  GmailService({
    GoogleOAuthService? oauthService,
    http.Client? httpClient,
  })  : _oauthService = oauthService ?? GoogleOAuthService(),
        _client = httpClient ?? http.Client();

  final GoogleOAuthService _oauthService;
  final http.Client _client;

  static const String _gmailApiBase = 'https://gmail.googleapis.com/gmail/v1/users/me';

  /// Sends an email directly via the Gmail API with OAuth 2.0.
  /// Converts the parameters to RFC 2822 format and base64url encodes it.
  Future<String> sendEmail({
    required String to,
    required String subject,
    required String body,
  }) async {
    final token = await _oauthService.getValidAccessToken();
    if (token == null || token.isEmpty) {
      return 'Error: Google OAuth is not configured. Please set your credentials in Settings.';
    }

    try {
      // Build RFC 2822 email format
      final rfc2822 = [
        'To: $to',
        'Subject: $subject',
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset="UTF-8"',
        'Content-Transfer-Encoding: 7bit',
        '',
        body,
      ].join('\r\n');

      final base64urlEncoded = base64Url
          .encode(utf8.encode(rfc2822))
          .replaceAll('=', '');

      final response = await _client.post(
        Uri.parse('$_gmailApiBase/messages/send'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'raw': base64urlEncoded}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return 'Email sent successfully to $to.';
      } else {
        final err = 'Gmail API error (${response.statusCode}): ${response.body}';
        debugPrint(err);
        return 'Error sending email: ${response.statusCode}';
      }
    } catch (e) {
      debugPrint('Gmail send failure: $e');
      return 'Error sending email: $e';
    }
  }

  /// Fetches recent email message summaries from Gmail.
  Future<List<Map<String, String>>> getRecentEmails({
    int maxResults = 5,
    String? query,
  }) async {
    final token = await _oauthService.getValidAccessToken();
    if (token == null || token.isEmpty) {
      return [];
    }

    try {
      final queryParam = query != null && query.isNotEmpty ? '&q=${Uri.encodeComponent(query)}' : '';
      final listUri = Uri.parse('$_gmailApiBase/messages?maxResults=$maxResults$queryParam');
      final listResponse = await _client.get(
        listUri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (listResponse.statusCode != 200) {
        debugPrint('Gmail list error: ${listResponse.statusCode} - ${listResponse.body}');
        return [];
      }

      final listData = jsonDecode(listResponse.body) as Map<String, dynamic>;
      final messages = (listData['messages'] as List<dynamic>?) ?? [];
      final results = <Map<String, String>>[];

      for (final msg in messages.take(maxResults)) {
        final id = msg['id'] as String;
        final detailUri = Uri.parse('$_gmailApiBase/messages/$id?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date');
        final detailRes = await _client.get(
          detailUri,
          headers: {'Authorization': 'Bearer $token'},
        );

        if (detailRes.statusCode == 200) {
          final detailData = jsonDecode(detailRes.body) as Map<String, dynamic>;
          final snippet = detailData['snippet'] as String? ?? '';
          final headers = (detailData['payload']?['headers'] as List<dynamic>?) ?? [];

          String from = '';
          String subject = '';
          String date = '';

          for (final h in headers) {
            final name = h['name'] as String? ?? '';
            final val = h['value'] as String? ?? '';
            if (name.toLowerCase() == 'from') from = val;
            if (name.toLowerCase() == 'subject') subject = val;
            if (name.toLowerCase() == 'date') date = val;
          }

          results.add({
            'id': id,
            'from': from,
            'subject': subject,
            'snippet': snippet,
            'date': date,
          });
        }
      }
      return results;
    } catch (e) {
      debugPrint('Gmail fetch error: $e');
      return [];
    }
  }
}

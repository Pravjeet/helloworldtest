import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/college_notice.dart';

/// Reads the college's public notice feed from sliet.ac.in.
///
/// SLIET runs WordPress with its REST API open, so there is no scraping here —
/// `/wp-json/wp/v2/posts` returns clean JSON. Categories 7 (Notification) and
/// 11 (Student Notification) are the two that carry notices; a post may be in
/// both, and the API returns each post once, so no de-duplication is needed.
///
/// **On CORS.** This is a cross-origin request. WordPress normally allows it,
/// but if SLIET's server or a security plugin strips the header, the browser
/// will block it on Flutter *web* — desktop and mobile are unaffected because
/// they have no origin policy. That failure is caught and surfaced as
/// [CollegeFeedException] with `isLikelyCors` set, so the UI can offer a link
/// to the website instead of showing a broken panel.
///
/// The service is deliberately narrow: one method returning a list. If the
/// direct fetch proves unreliable, a Cloud Function can cache the same feed
/// into Firestore and only this file changes.
class CollegeFeedService {
  CollegeFeedService._();
  static final CollegeFeedService instance = CollegeFeedService._();

  static const String _host = 'sliet.ac.in';

  /// Where to send someone when the feed can't be loaded in-app.
  static const String noticesPageUrl =
      'https://sliet.ac.in/category/notification/';

  /// Cached so switching tabs doesn't re-fetch. The college publishes a few
  /// notices a week; a session-lifetime cache is plenty.
  List<CollegeNotice>? _cache;
  DateTime? _fetchedAt;

  static const Duration _cacheFor = Duration(minutes: 30);

  bool get hasFresh =>
      _cache != null &&
      _fetchedAt != null &&
      DateTime.now().difference(_fetchedAt!) < _cacheFor;

  /// Latest notices, newest first.
  ///
  /// [limit] caps the result; the API is asked for the same number so we don't
  /// transfer more than we show.
  Future<List<CollegeNotice>> fetchLatest({
    int limit = 15,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && hasFresh) return _cache!;

    final uri = Uri.https(_host, '/wp-json/wp/v2/posts', {
      'categories': '$kNotificationCategory,$kStudentNotificationCategory',
      'per_page': '$limit',
      'orderby': 'date',
      'order': 'desc',
      // Ask for only what's rendered. Saves roughly 80% of the payload —
      // the default response carries revisions, _links and meta we ignore.
      '_fields': 'id,date,link,title,excerpt,content,categories',
    });

    try {
      final res = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) {
        throw CollegeFeedException(
          'The college website returned ${res.statusCode}.',
        );
      }

      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) {
        throw const CollegeFeedException(
          'The college website sent something unexpected.',
        );
      }

      final notices = decoded
          .whereType<Map<String, dynamic>>()
          .map(CollegeNotice.fromWordPress)
          .where((n) => n.title.isNotEmpty)
          .toList();

      _cache = notices;
      _fetchedAt = DateTime.now();
      return notices;
    } on CollegeFeedException {
      rethrow;
    } catch (e) {
      // A blocked cross-origin request surfaces as a transport-level failure
      // with no status code, so it is indistinguishable from being offline.
      // Say so honestly rather than guessing at one cause.
      throw CollegeFeedException(
        'Could not reach the college website.',
        isLikelyCors: true,
        cause: e,
      );
    }
  }

  /// Drops the cache so the next read goes to the network.
  void invalidate() {
    _cache = null;
    _fetchedAt = null;
  }
}

class CollegeFeedException implements Exception {
  final String message;

  /// True when the failure looks like a browser policy or connectivity
  /// problem rather than a bad response from the server.
  final bool isLikelyCors;

  final Object? cause;

  const CollegeFeedException(
    this.message, {
    this.isLikelyCors = false,
    this.cause,
  });

  @override
  String toString() => message;
}

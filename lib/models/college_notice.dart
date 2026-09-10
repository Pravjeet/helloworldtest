/// A notice published on the college's own website.
///
/// This is *not* stored in Firestore — it comes from sliet.ac.in and is
/// read-only. Nobody in this app can create, edit or delete one, which is why
/// it is a separate type from [Notice] rather than a flag on it. Conflating
/// the two would mean every delete button needs a "but not if it came from the
/// website" guard.
class CollegeNotice {
  /// WordPress post id. Stable, so it works as a de-duplication key.
  final int id;

  final String title;

  /// Plain-text summary, HTML already stripped.
  final String summary;

  /// The post's page on sliet.ac.in.
  final String link;

  /// The first document linked from the post body, if any. Most SLIET notices
  /// are a one-line post wrapping a link to the real PDF, so this is usually
  /// what the reader actually wants.
  final String? documentUrl;

  final DateTime? published;

  /// True when SLIET tagged this for students specifically (category 11)
  /// rather than only as a general notification.
  final bool forStudents;

  const CollegeNotice({
    required this.id,
    required this.title,
    required this.summary,
    required this.link,
    this.documentUrl,
    this.published,
    this.forStudents = false,
  });

  /// Builds one from a WordPress REST API post object.
  factory CollegeNotice.fromWordPress(Map<String, dynamic> m) {
    final rawTitle = _rendered(m['title']);
    final rawExcerpt = _rendered(m['excerpt']);
    final rawContent = _rendered(m['content']);

    final categories = (m['categories'] as List?)?.cast<Object?>() ?? const [];

    return CollegeNotice(
      id: (m['id'] as num?)?.toInt() ?? 0,
      title: decodeHtml(stripHtml(rawTitle)),
      summary: decodeHtml(stripHtml(rawExcerpt)),
      link: m['link'] as String? ?? '',
      documentUrl: firstLinkIn(rawContent),
      published: DateTime.tryParse(m['date'] as String? ?? ''),
      forStudents: categories.contains(kStudentNotificationCategory),
    );
  }

  static String _rendered(Object? field) {
    if (field is Map && field['rendered'] is String) {
      return field['rendered'] as String;
    }
    return field is String ? field : '';
  }

  /// What to open when the row is tapped: the PDF if there is one, otherwise
  /// the post page.
  String get target => documentUrl ?? link;

  bool get isPdf => (documentUrl ?? '').toLowerCase().endsWith('.pdf');
}

/// SLIET's WordPress category ids.
///
/// 7 is named "Notification" but its description on the site is literally
/// "announcement" — it is the feed rendered as *Notifications* on the
/// homepage, and it is a superset of the small Announcements widget.
const int kNotificationCategory = 7;
const int kStudentNotificationCategory = 11;

// ---------------------------------------------------------------------
// Tiny HTML helpers
//
// The feed returns rendered HTML. Rather than take a parser dependency for
// three operations, these handle the narrow shapes WordPress actually emits.
// ---------------------------------------------------------------------

/// Removes tags and collapses whitespace.
String stripHtml(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Decodes the handful of entities WordPress emits in titles — curly quotes,
/// ampersands and the like.
String decodeHtml(String s) {
  const named = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#039;': "'",
    '&#8217;': '’',
    '&#8216;': '‘',
    '&#8220;': '“',
    '&#8221;': '”',
    '&#8211;': '–',
    '&#8212;': '—',
    '&nbsp;': ' ',
    '&hellip;': '…',
  };
  var out = s;
  named.forEach((k, v) => out = out.replaceAll(k, v));

  // Any remaining numeric entities.
  return out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
}

/// The href of the first anchor in a fragment, or null.
String? firstLinkIn(String html) {
  final m = RegExp(
    r'''<a[^>]+href=["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(html);
  final href = m?.group(1);
  if (href == null || href.isEmpty) return null;
  // Upgrade the http:// links SLIET emits — mixed content is blocked when the
  // app itself is served over https.
  return href.startsWith('http://')
      ? href.replaceFirst('http://', 'https://')
      : href;
}

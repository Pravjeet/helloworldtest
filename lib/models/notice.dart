import 'package:cloud_firestore/cloud_firestore.dart';

/// A notice posted to the college community.
///
/// Staff with `notices.manage` post notices; students with `notices.view` read
/// them. A notice may have an optional expiry date, after which it's considered
/// archived and hidden from the student view.
class Notice {
  final String id;
  final String title;
  final String content;

  /// Who posted it. Denormalised so the list doesn't need extra reads.
  final String postedByUid;
  final String postedByName;
  final String? postedByDesignation;

  /// One of [kNoticeCategories].
  final String category;

  final DateTime? createdAt;
  final DateTime? expiryDate;

  const Notice({
    required this.id,
    required this.title,
    required this.content,
    required this.postedByUid,
    required this.postedByName,
    this.postedByDesignation,
    this.category = 'General',
    this.createdAt,
    this.expiryDate,
  });

  factory Notice.fromMap(String id, Map<String, dynamic> m) => Notice(
    id: id,
    title: m['title'] as String? ?? '',
    content: m['content'] as String? ?? '',
    postedByUid: m['postedByUid'] as String? ?? '',
    postedByName: m['postedByName'] as String? ?? 'Unknown',
    postedByDesignation: m['postedByDesignation'] as String?,
    category: m['category'] as String? ?? 'General',
    createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
    expiryDate: (m['expiryDate'] as Timestamp?)?.toDate(),
  );

  Map<String, dynamic> toMap() => {
    'title': title,
    'content': content,
    'postedByUid': postedByUid,
    'postedByName': postedByName,
    'postedByDesignation': postedByDesignation,
    'category': category,
    'expiryDate': expiryDate == null ? null : Timestamp.fromDate(expiryDate!),
  };

  /// True if this notice has passed its expiry date.
  bool get isExpired {
    if (expiryDate == null) return false;
    return DateTime.now().isAfter(expiryDate!);
  }

  /// Formatted expiry string, or null if no expiry.
  String? get expiryLabel {
    if (expiryDate == null) return null;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${expiryDate!.day} ${months[expiryDate!.month - 1]} ${expiryDate!.year}';
  }
}

const List<String> kNoticeCategories = [
  'Academic',
  'Maintenance',
  'Event',
  'General',
  'Hostel',
  'Emergency',
];

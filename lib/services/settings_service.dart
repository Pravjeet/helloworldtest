import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/college_settings.dart';
import 'stream_cache.dart';

/// Workspace configuration, at `colleges/{collegeId}/settings/config`.
///
/// A single fixed document id rather than a growing collection: there is
/// exactly one current configuration at any time. Same shape as the mess
/// module's `menu` and `config`.
///
/// Everyone in the college can READ this — the sidebar needs the institution
/// name, the fines form needs the category list, the theme needs the accent
/// colour. Only `settings.manage` may write.
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _doc(String collegeId) => _db
      .collection('colleges')
      .doc(collegeId)
      .collection('settings')
      .doc('config');

  /// Never emits an error state for "not configured yet" — a workspace that
  /// has never opened the settings screen gets defaults, which is what every
  /// caller wants.
  final CachedStreamPool<CollegeSettings> _pool = CachedStreamPool();

  Stream<CollegeSettings> watch(String collegeId) => _pool.stream(
    collegeId,
    () => _doc(collegeId).snapshots().map(
      (d) => d.exists
          ? CollegeSettings.fromMap(d.data()!)
          : const CollegeSettings(),
    ),
  );

  Future<CollegeSettings> read(String collegeId) async {
    final d = await _doc(collegeId).get();
    return d.exists
        ? CollegeSettings.fromMap(d.data()!)
        : const CollegeSettings();
  }

  /// Writes one section without sending the others.
  ///
  /// `set` with merge so two admins editing different sections at the same
  /// time don't wipe each other's work, and so a newer version of the app
  /// adding a field doesn't lose it when an older client saves.
  Future<void> saveSection(
    String collegeId,
    String section,
    Map<String, dynamic> value, {
    String? byName,
  }) => _doc(collegeId).set({
    section: value,
    'updatedAt': FieldValue.serverTimestamp(),
    if (byName != null) 'updatedByName': byName,
  }, SetOptions(merge: true));

  Future<void> saveInstitution(
    String collegeId,
    InstitutionProfile v, {
    String? byName,
  }) => saveSection(collegeId, 'institution', v.toMap(), byName: byName);

  Future<void> saveTheming(String collegeId, AppTheming v, {String? byName}) =>
      saveSection(collegeId, 'theming', v.toMap(), byName: byName);

  Future<void> saveSession(
    String collegeId,
    AcademicSession v, {
    String? byName,
  }) => saveSection(collegeId, 'session', v.toMap(), byName: byName);

  Future<void> saveFineCategories(
    String collegeId,
    List<FineCategory> v, {
    String? byName,
  }) => _doc(collegeId).set({
    'fineCategories': v.map((c) => c.toMap()).toList(),
    'updatedAt': FieldValue.serverTimestamp(),
    if (byName != null) 'updatedByName': byName,
  }, SetOptions(merge: true));

  Future<void> saveTrades(String collegeId, List<Trade> v, {String? byName}) =>
      _doc(collegeId).set({
        'trades': v.map((t) => t.toMap()).toList(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (byName != null) 'updatedByName': byName,
      }, SetOptions(merge: true));

  Future<void> saveCourseRules(
    String collegeId,
    List<CourseRule> v, {
    String? byName,
  }) => _doc(collegeId).set({
    'courseRules': v.map((r) => r.toMap()).toList(),
    'updatedAt': FieldValue.serverTimestamp(),
    if (byName != null) 'updatedByName': byName,
  }, SetOptions(merge: true));

  /// Renames the college itself. Stored on the college document, not in
  /// settings, because that is what every user's session reads at login.
  Future<void> renameCollege(String collegeId, String name) => _db
      .collection('colleges')
      .doc(collegeId)
      .update({'name': name.trim(), 'updatedAt': FieldValue.serverTimestamp()});
}

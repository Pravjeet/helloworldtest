import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/mess.dart';
import 'stream_cache.dart';

/// Firestore access for the mess module.
///
/// Both documents live under `colleges/{collegeId}/mess/`:
///   * `menu`   — the seven-day menu grid
///   * `config` — fees, timings and rebate rules
///
/// Two fixed document ids rather than a growing collection, because there is
/// exactly one current menu and one current fee structure at any time.
/// Historic menus, if they're ever wanted, belong in a separate archive.
class MessService {
  MessService._();
  static final MessService instance = MessService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _doc(String collegeId, String id) =>
      _db.collection('colleges').doc(collegeId).collection('mess').doc(id);

  // ------------------------------ menu ------------------------------

  final CachedStreamPool<MessMenu> _menuPool = CachedStreamPool();
  final CachedStreamPool<MessConfig> _configPool = CachedStreamPool();

  Stream<MessMenu> watchMenu(String collegeId) => _menuPool.stream(
    collegeId,
    () => _doc(collegeId, 'menu').snapshots().map(
      (d) => d.exists ? MessMenu.fromMap(d.data()!) : const MessMenu(),
    ),
  );

  /// Writes the whole grid. `set` with merge so a save never wipes fields a
  /// newer version of the app might have added.
  Future<void> saveMenu(String collegeId, MessMenu menu, {String? byName}) =>
      _doc(collegeId, 'menu').set({
        ...menu.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (byName != null) 'updatedByName': byName,
      }, SetOptions(merge: true));

  /// Updates one cell of the grid without sending the other 27.
  Future<void> saveMeal(
    String collegeId,
    int weekday,
    Meal meal,
    String value, {
    String? byName,
  }) => _doc(collegeId, 'menu').set({
    'days': {
      weekday.toString(): {meal.name: value.trim()},
    },
    'updatedAt': FieldValue.serverTimestamp(),
    if (byName != null) 'updatedByName': byName,
  }, SetOptions(merge: true));

  Future<void> saveNotes(String collegeId, List<String> notes) =>
      _doc(collegeId, 'menu').set({
        'notes': notes,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  // ------------------------------ config ------------------------------

  Stream<MessConfig> watchConfig(String collegeId) => _configPool.stream(
    collegeId,
    () => _doc(collegeId, 'config').snapshots().map(
      (d) => d.exists ? MessConfig.fromMap(d.data()!) : const MessConfig(),
    ),
  );

  Future<void> saveConfig(String collegeId, MessConfig config) =>
      _doc(collegeId, 'config').set({
        ...config.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  // ------------------------------ seeding ------------------------------

  /// Fills a blank menu with the standard institute grid, so a new mess
  /// manager starts from something editable rather than 28 empty boxes.
  Future<void> seedDefaultMenu(String collegeId, {String? byName}) =>
      saveMenu(collegeId, kDefaultMessMenu, byName: byName);
}

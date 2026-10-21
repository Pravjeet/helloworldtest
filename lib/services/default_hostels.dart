import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Seeds the hostels built in hostel_app into a workspace, once.
///
/// The data lives in `assets/default_hostels.json`: every hostel's name,
/// code, gender, amenities and full room layout, with no occupants and no
/// warden (those point at people who don't exist in this project).
///
/// They are ordinary hostel documents once written, so they can be edited
/// or deleted like any other. The college doc is then stamped with
/// [_flag], so a deleted default stays deleted instead of coming back on the
/// next sign-in.
class DefaultHostels {
  DefaultHostels._();
  static final DefaultHostels instance = DefaultHostels._();

  static const String _asset = 'assets/default_hostels.json';
  static const String _flag = 'defaultHostelsSeeded';

  /// Firestore caps a single batch at 500 operations.
  static const int _batchLimit = 450;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// One attempt per college per app run.
  final Set<String> _attempted = {};

  /// Writes the defaults unless this college has already been seeded.
  ///
  /// Needs a super admin: creating hostels takes `hostels.manage`, and only a
  /// super admin may stamp the college doc. A default whose code is already
  /// taken in this college is skipped, so hostels made by hand are never
  /// duplicated. Safe to call repeatedly and to re-run after an interruption:
  /// each hostel's rooms go in before the hostel itself, under fixed ids, so a
  /// half-finished run just gets overwritten.
  Future<void> seedIfNeeded(String collegeId) async {
    if (!_attempted.add(collegeId)) return;
    try {
      final collegeRef = _db.collection('colleges').doc(collegeId);
      final college = await collegeRef.get();
      if (college.data()?[_flag] == true) return;

      final hostelsRef = collegeRef.collection('hostels');
      final existing = await hostelsRef.get();
      final takenCodes = existing.docs
          .map((d) => _normCode(d.data()['code'] as String?))
          .where((c) => c.isNotEmpty)
          .toSet();

      final defaults = (jsonDecode(await rootBundle.loadString(_asset)) as List)
          .cast<Map<String, dynamic>>();

      for (final h in defaults) {
        if (takenCodes.contains(_normCode(h['code'] as String?))) continue;
        await _writeHostel(hostelsRef.doc(h['id'] as String), h);
      }

      await collegeRef.update({_flag: true});
    } catch (e) {
      // Not fatal: the app works without the defaults, and the next sign-in
      // tries again.
      _attempted.remove(collegeId);
      debugPrint('Default hostel seeding failed: $e');
    }
  }

  Future<void> _writeHostel(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> h,
  ) async {
    final rooms = (h['rooms'] as List).cast<Map<String, dynamic>>();

    for (var start = 0; start < rooms.length; start += _batchLimit) {
      final end = (start + _batchLimit).clamp(0, rooms.length);
      final batch = _db.batch();
      for (final r in rooms.sublist(start, end)) {
        batch.set(ref.collection('rooms').doc(r['id'] as String), {
          'number': r['number'] ?? r['id'],
          'floor': r['floor'] ?? 0,
          'capacity': r['capacity'] ?? 1,
          'features': r['features'] ?? const <String>[],
          'status': r['status'] ?? 'active',
          'occupantUids': const <String>[],
          'rentPerBed': r['rentPerBed'],
          'note': r['note'],
          'maintenanceNote': null,
        });
      }
      await batch.commit();
    }

    final beds = rooms.fold<int>(
      0,
      (a, r) => a + ((r['capacity'] as num?)?.toInt() ?? 1),
    );
    await ref.set({
      'name': h['name'],
      'code': h['code'] ?? '',
      'gender': h['gender'] ?? 'coed',
      'floors': h['floors'] ?? 1,
      'amenities': h['amenities'] ?? const <String>[],
      'wardenUid': null,
      'wardenName': null,
      'address': h['address'],
      'roomCount': rooms.length,
      'bedCount': beds,
      'occupiedBeds': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// "GH -2" and "gh-2" are the same hostel.
  static String _normCode(String? code) =>
      (code ?? '').replaceAll(' ', '').toLowerCase();
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the composite indexes the app's queries cannot run without.
///
/// Firestore needs a composite index whenever a query mixes an equality and an
/// inequality on different fields. Nothing in the Dart toolchain checks this —
/// `flutter analyze` is happy, the code is correct, and the query throws
/// `failed-precondition` only against real Firestore, only at the moment a
/// user clicks the thing.
///
/// That is exactly how "Empty all rooms" shipped broken: it cleared every room
/// and then threw on the query that clears the students, leaving the rooms
/// looking empty while the students were still allotted to them. The index had
/// never been added here at all.
///
/// So: when you write a query that needs an index, add it to
/// `firestore.indexes.json`, add it below, and **deploy it** — the file on disk
/// does nothing until `deploy-rules.bat` publishes it.
void main() {
  final indexes =
      (jsonDecode(File('firestore.indexes.json').readAsStringSync())
              as Map<String, dynamic>)['indexes']
          as List;

  bool has(String collection, List<String> fields) => indexes.any((i) {
    final m = i as Map<String, dynamic>;
    if (m['collectionGroup'] != collection) return false;
    final paths = (m['fields'] as List)
        .map((f) => (f as Map<String, dynamic>)['fieldPath'])
        .toList();
    return paths.length == fields.length &&
        List.generate(fields.length, (n) => paths[n] == fields[n]).every((b) => b);
  });

  group('firestore.indexes.json', () {
    test('covers the dashboard\'s per-role user counts', () {
      // DataService.countUsersByRole
      expect(has('users', ['collegeId', 'roleId']), isTrue);
    });

    test('covers finding every allotted student in a college', () {
      // HostelService._allottedStudentRefs — collegeId == x AND hostelId != null.
      // Without this, "Empty all rooms" half-runs.
      expect(has('users', ['collegeId', 'hostelId']), isTrue);
    });
  });
}

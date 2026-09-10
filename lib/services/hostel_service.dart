import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/hostel.dart';
import 'stream_cache.dart';

/// Firestore access for hostels and their rooms.
///
/// Rooms live in a subcollection of their hostel:
///   colleges/{collegeId}/hostels/{hostelId}/rooms/{roomNumber}
///
/// The room number doubles as the document id, which makes duplicate room
/// numbers within a hostel structurally impossible.
class HostelService {
  HostelService._();
  static final HostelService instance = HostelService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Firestore caps a single batch at 500 operations.
  static const int _batchLimit = 450;

  CollectionReference<Map<String, dynamic>> _hostels(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('hostels');

  CollectionReference<Map<String, dynamic>> _rooms(
    String collegeId,
    String hostelId,
  ) => _hostels(collegeId).doc(hostelId).collection('rooms');

  // ------------------------------ reads ------------------------------

  final CachedStreamPool<List<Hostel>> _hostelPool = CachedStreamPool();
  final CachedStreamPool<List<Room>> _roomPool = CachedStreamPool();

  Stream<List<Hostel>> watchHostels(String collegeId) => _hostelPool.stream(
    collegeId,
    () => _hostels(collegeId)
        .orderBy('name')
        .snapshots()
        .map((s) => s.docs.map((d) => Hostel.fromMap(d.id, d.data())).toList()),
  );

  Stream<Hostel?> watchHostel(String collegeId, String hostelId) =>
      _hostels(collegeId)
          .doc(hostelId)
          .snapshots()
          .map((d) => d.exists ? Hostel.fromMap(d.id, d.data()!) : null);

  /// Rooms sorted by floor then number. Sorting client-side keeps this to a
  /// single-field Firestore index instead of a composite one.
  Stream<List<Room>> watchRooms(String collegeId, String hostelId) =>
      _roomPool.stream(
        '$collegeId/$hostelId',
        () => _rooms(collegeId, hostelId).snapshots().map((s) {
          final rooms = s.docs
              .map((d) => Room.fromMap(d.id, d.data()))
              .toList();
          rooms.sort((a, b) {
            final byFloor = a.floor.compareTo(b.floor);
            if (byFloor != 0) return byFloor;
            return _numericCompare(a.number, b.number);
          });
          return rooms;
        }),
      );

  /// One-shot read of a hostel's rooms.
  ///
  /// The bulk importer needs this rather than `watchRooms(...).first`: taking
  /// `.first` off a snapshot stream opens a live listener that is never
  /// cancelled, and if the stream never emits (offline, or a rules change mid
  /// import) the await hangs with no timeout — which is exactly what a stuck
  /// "Importing…" looks like.
  Future<List<Room>> roomsOnce(String collegeId, String hostelId) async {
    final snap = await _rooms(collegeId, hostelId).get();
    final rooms = snap.docs.map((d) => Room.fromMap(d.id, d.data())).toList();
    rooms.sort((a, b) {
      final byFloor = a.floor.compareTo(b.floor);
      if (byFloor != 0) return byFloor;
      return _numericCompare(a.number, b.number);
    });
    return rooms;
  }

  /// Compares room numbers numerically where possible, so "9" sorts before
  /// "10" instead of after it.
  static int _numericCompare(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    return a.compareTo(b);
  }

  // ------------------------------ writes -----------------------------

  /// Creates the hostel and every room in its plan.
  ///
  /// Rooms are written in chunks because a 6-floor × 100-room hostel would
  /// blow past Firestore's 500-operation batch limit.
  Future<String> createHostel({
    required String collegeId,
    required Hostel hostel,
    required RoomPlan plan,
  }) async {
    final ref = _hostels(collegeId).doc();
    final rooms = plan.build();

    await ref.set({
      ...hostel.toMap(),
      'floors': plan.floors,
      'roomCount': rooms.length,
      'bedCount': plan.totalBeds,
      'occupiedBeds': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await _writeRoomsChunked(collegeId, ref.id, rooms);
    return ref.id;
  }

  Future<void> _writeRoomsChunked(
    String collegeId,
    String hostelId,
    List<Room> rooms,
  ) async {
    final col = _rooms(collegeId, hostelId);
    for (var start = 0; start < rooms.length; start += _batchLimit) {
      final end = (start + _batchLimit).clamp(0, rooms.length);
      final batch = _db.batch();
      for (final room in rooms.sublist(start, end)) {
        batch.set(col.doc(room.id), room.toMap());
      }
      await batch.commit();
    }
  }

  /// Updates the editable hostel fields. Counters are deliberately excluded —
  /// they're derived from the rooms and are maintained by the room methods.
  Future<void> updateHostel(String collegeId, Hostel hostel) =>
      _hostels(collegeId).doc(hostel.id).update({
        'name': hostel.name,
        'code': hostel.code,
        'gender': hostel.gender.name,
        'amenities': hostel.amenities,
        'wardenUid': hostel.wardenUid,
        'wardenName': hostel.wardenName,
        'address': hostel.address,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Deletes a hostel and all of its rooms.
  ///
  /// Firestore does *not* cascade — deleting a document leaves its
  /// subcollections orphaned and invisible but still billed. So we clear the
  /// rooms first, in chunks, then remove the hostel.
  Future<void> deleteHostel(String collegeId, String hostelId) async {
    final col = _rooms(collegeId, hostelId);
    while (true) {
      final snap = await col.limit(_batchLimit).get();
      if (snap.docs.isEmpty) break;
      final batch = _db.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      if (snap.docs.length < _batchLimit) break;
    }
    await _hostels(collegeId).doc(hostelId).delete();
  }

  /// Adds one room outside the original plan (a late addition, a converted
  /// store room). Bumps the hostel counters in the same batch so they can't
  /// drift out of step.
  Future<void> addRoom({
    required String collegeId,
    required String hostelId,
    required Room room,
  }) async {
    final roomRef = _rooms(collegeId, hostelId).doc(room.id);
    if ((await roomRef.get()).exists) {
      throw Exception('Room ${room.number} already exists in this hostel.');
    }

    final batch = _db.batch();
    batch.set(roomRef, room.toMap());
    batch.update(_hostels(collegeId).doc(hostelId), {
      'roomCount': FieldValue.increment(1),
      'bedCount': FieldValue.increment(room.capacity),
      'floors': FieldValue.increment(0),
    });
    await batch.commit();
  }

  /// Edits a room. If the capacity changed, the hostel's bed count moves by
  /// the difference in the same batch.
  Future<void> updateRoom({
    required String collegeId,
    required String hostelId,
    required Room before,
    required Room after,
  }) async {
    final batch = _db.batch();
    batch.update(_rooms(collegeId, hostelId).doc(after.id), after.toMap());

    final bedDelta = after.capacity - before.capacity;
    if (bedDelta != 0) {
      batch.update(_hostels(collegeId).doc(hostelId), {
        'bedCount': FieldValue.increment(bedDelta),
      });
    }
    await batch.commit();
  }

  Future<void> deleteRoom({
    required String collegeId,
    required String hostelId,
    required Room room,
  }) async {
    if (room.occupied > 0) {
      throw Exception(
        'Room ${room.number} still has ${room.occupied} student(s) in it. '
        'Move them out before deleting the room.',
      );
    }
    final batch = _db.batch();
    batch.delete(_rooms(collegeId, hostelId).doc(room.id));
    batch.update(_hostels(collegeId).doc(hostelId), {
      'roomCount': FieldValue.increment(-1),
      'bedCount': FieldValue.increment(-room.capacity),
    });
    await batch.commit();
  }

  /// Appends a floor of rooms to an existing hostel.
  Future<void> addFloor({
    required String collegeId,
    required String hostelId,
    required int floor,
    required int roomsPerFloor,
    required int capacity,
    required List<String> features,
  }) async {
    final existing = await _rooms(collegeId, hostelId).get();
    final taken = existing.docs.map((d) => d.id).toSet();

    final rooms = <Room>[];
    for (var i = 1; i <= roomsPerFloor; i++) {
      final number = '${floor * 100 + i}';
      if (taken.contains(number)) continue; // never clobber an existing room
      rooms.add(
        Room(
          id: number,
          number: number,
          floor: floor,
          capacity: capacity,
          features: features,
        ),
      );
    }
    if (rooms.isEmpty) {
      throw Exception('Every room number on floor $floor already exists.');
    }

    await _writeRoomsChunked(collegeId, hostelId, rooms);
    await _hostels(collegeId).doc(hostelId).update({
      'roomCount': FieldValue.increment(rooms.length),
      'bedCount': FieldValue.increment(rooms.length * capacity),
      'floors': floor,
    });
  }

  /// Deletes every room in the hostel and replaces them with a freshly
  /// generated plan.
  ///
  /// For when the initial room layout was wrong — mistyped floor count,
  /// wrong capacity — and re-doing it is easier than editing dozens of rooms
  /// by hand or deleting the whole hostel and starting over.
  ///
  /// Refuses if any existing room currently holds a student: replacing the
  /// room documents would silently strand that allotment. Move everyone out
  /// first (or leave those rooms as-is and only add/edit around them).
  Future<void> regenerateRooms({
    required String collegeId,
    required String hostelId,
    required RoomPlan plan,
  }) async {
    final existing = await _rooms(collegeId, hostelId).get();
    final occupied = existing.docs
        .map((d) => Room.fromMap(d.id, d.data()))
        .where((r) => r.occupied > 0)
        .toList();
    if (occupied.isNotEmpty) {
      throw Exception(
        '${occupied.length} room(s) still have students in them (e.g. room '
        '${occupied.first.number}). Move everyone out before regenerating '
        'rooms.',
      );
    }

    for (var start = 0; start < existing.docs.length; start += _batchLimit) {
      final end = (start + _batchLimit).clamp(0, existing.docs.length);
      final batch = _db.batch();
      for (final d in existing.docs.sublist(start, end)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }

    final rooms = plan.build();
    await _writeRoomsChunked(collegeId, hostelId, rooms);
    await _hostels(collegeId).doc(hostelId).update({
      'floors': plan.floors,
      'roomCount': rooms.length,
      'bedCount': plan.totalBeds,
      'occupiedBeds': 0,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Clears every room's occupants and resets every hostel's occupied-bed
  /// counter to zero, across the whole college.
  ///
  /// For when residents left some other way than [AllotmentService.vacate] —
  /// a bulk account deletion where the vacate step failed silently, or a
  /// direct console edit — and rooms are left listing uids that no longer
  /// exist. `vacate` only ever clears one student's own room; nothing else
  /// repairs a room that's gone stale on its own. Skips rooms that are
  /// already empty, so re-running this after a partial run is cheap.
  Future<({int roomsCleared, int bedsFreed})> emptyAllRooms(
    String collegeId,
  ) async {
    final hostels = await _hostels(collegeId).get();
    var roomsCleared = 0;
    var bedsFreed = 0;

    for (final hostelDoc in hostels.docs) {
      final roomsSnap = await _rooms(collegeId, hostelDoc.id).get();
      final occupied = roomsSnap.docs.where((d) {
        final list = d.data()['occupantUids'] as List?;
        return list != null && list.isNotEmpty;
      }).toList();
      if (occupied.isEmpty) continue;

      for (var start = 0; start < occupied.length; start += _batchLimit) {
        final end = (start + _batchLimit).clamp(0, occupied.length);
        final batch = _db.batch();
        for (final d in occupied.sublist(start, end)) {
          bedsFreed += (d.data()['occupantUids'] as List).length;
          batch.update(d.reference, {'occupantUids': <String>[]});
        }
        await batch.commit();
      }
      roomsCleared += occupied.length;

      await _hostels(collegeId).doc(hostelDoc.id).update({'occupiedBeds': 0});
    }

    return (roomsCleared: roomsCleared, bedsFreed: bedsFreed);
  }

  /// Recomputes the denormalised counters from the rooms themselves.
  /// Useful if a write ever fails halfway and the numbers drift.
  Future<void> recalculateCounters(String collegeId, String hostelId) async {
    final snap = await _rooms(collegeId, hostelId).get();
    var beds = 0;
    var occupied = 0;
    var maxFloor = 1;
    for (final d in snap.docs) {
      final room = Room.fromMap(d.id, d.data());
      beds += room.capacity;
      occupied += room.occupied;
      if (room.floor > maxFloor) maxFloor = room.floor;
    }
    await _hostels(collegeId).doc(hostelId).update({
      'roomCount': snap.docs.length,
      'bedCount': beds,
      'occupiedBeds': occupied,
      'floors': maxFloor,
    });
  }
}

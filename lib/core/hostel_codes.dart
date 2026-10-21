import '../models/hostel.dart';

/// Turns a stored hostel *name* into the hostel's code, for display.
///
/// Students, fines, fees, requests and enrollments all record the hostel by
/// name (and sometimes id) at the moment they were written — none of them
/// carry the code. Rather than migrate every one of those documents, the app
/// keeps the live hostel list here and translates at display time, so
/// "Meghnad Saha House" reads as "BH-3" everywhere and a renamed code shows
/// up immediately on old records too.
///
/// Filled by the session loader (auth_gate.dart) from the shared, already
/// cached `HostelService.watchHostels` stream, before the dashboard draws.
/// Accounts that can't read hostels (students) never fill it, and [of] then
/// falls back to the name it was given, so nothing ever shows blank.
class HostelCodes {
  HostelCodes._();

  static Map<String, String> _byName = const {};
  static Map<String, String> _byId = const {};

  /// Changes whenever the mapping does, so [SessionScope] can tell its
  /// dependents to rebuild when a hostel's code is edited.
  static String signature = '';

  static void update(Iterable<Hostel> hostels) {
    _byName = {for (final h in hostels) _key(h.name): h.label};
    _byId = {for (final h in hostels) h.id: h.label};
    signature = [for (final h in hostels) '${h.id}=${h.label}'].join('|');
  }

  static String _key(String name) => name.trim().toLowerCase();

  /// The code for a hostel recorded as [name] (or [id], when the record has
  /// it). Returns [name] unchanged when the hostel isn't known, and null only
  /// when there was no hostel at all.
  static String? of(String? name, {String? id}) {
    if (id != null && _byId.containsKey(id)) return _byId[id];
    if (name == null || name.trim().isEmpty) return name;
    return _byName[_key(name)] ?? name;
  }
}

/// Pure, synchronous helpers for turning a batch/session string into the
/// year a student is in — and nothing else. No Firebase calls here on
/// purpose, so every rule below can be unit tested without a database.
///
/// The one idea everything here rests on: year is not a property of a
/// student, it's a property of a student-in-a-session. A batch tells you
/// which session a student's Year 1 was; from that and the session running
/// right now, the year follows by subtraction — no course-specific branch,
/// no special case for lateral entry (SLIET gives a lateral entrant the same
/// batch label as the students already ahead of them, so the same formula
/// lands them in the right class automatically).
library;

/// Pulls the start year out of a "2025-27" / "2025-26" style string.
///
/// Returns null rather than throwing on anything that doesn't parse — a
/// blank or malformed batch/session must not crash an import or a promotion
/// run; the caller decides how to flag it.
int? startYearOf(String? span) {
  final v = span?.trim() ?? '';
  final dash = v.indexOf('-');
  if (dash <= 0) return null;
  return int.tryParse(v.substring(0, dash));
}

/// The year a student is in, given the session running right now.
///
/// `batch` is the session in which this student's Year 1 began — e.g. a
/// student who started in the 2025-26 session has batch "2025-26" whatever
/// course they're on; a lateral entrant slotted into an existing 4-year
/// cohort carries that cohort's batch, not their own shorter one. Returns
/// null when either string doesn't parse, so a bad row is flagged rather
/// than silently mis-classed.
int? yearFromBatch(String? batch, String? currentSession) {
  final batchStart = startYearOf(batch);
  final sessionStart = startYearOf(currentSession);
  if (batchStart == null || sessionStart == null) return null;
  return sessionStart - batchStart + 1;
}

/// "2026-27" -> "2027-28". Used to suggest the next session before flipping
/// `config`, and to derive a batch's own span when only the start year is
/// known.
String? nextSessionAfter(String? session) {
  final start = startYearOf(session);
  if (start == null) return null;
  return '${start + 1}-${_shortYear(start + 2)}';
}

String _shortYear(int fullYear) =>
    (fullYear % 100).toString().padLeft(2, '0');

/// True once a student's year has run past how long their course lasts —
/// the graduation check. Compares the *year*, not the batch's end date,
/// because a repeater's year can lag behind what their batch alone would
/// predict; graduation should follow where they actually are.
bool hasGraduated(int year, int totalYears) => year > totalYears;

// =====================================================================
// Room seating policy
// =====================================================================

/// The room capacity (1 = Single, 3 = 3-Seater) a student is entitled to
/// this year, per the college's seating policy:
///
///  - Diploma: always 3-Seater, all three years.
///  - B.E. year 1–2: always 3-Seater.
///  - B.E. year 3+: Single if [singleRoomEligible] (earned by performing
///    well in 2nd year), otherwise 3-Seater.
///  - M.Tech / M.Sc / PhD: always Single.
///
/// Returns null for a course this policy doesn't recognise — that means "no
/// enforcement", not "3-Seater by default". A college running a course
/// outside this list should have room type left to staff judgement rather
/// than the app silently guessing wrong.
///
/// [singleRoomEligible] is a permanent flag (see [AppUser.singleRoomEligible])
/// — once earned it stays true, so a B.E. student who earned a Single in
/// year 3 is still entitled to one in year 4. It's harmless to pass true for
/// a Diploma or year 1/2 student; the policy for those is unconditional and
/// simply ignores it.
int? requiredRoomCapacity({
  required String? course,
  required int year,
  required bool singleRoomEligible,
}) {
  final c = (course ?? '').trim().toLowerCase().replaceAll(
    RegExp(r'[.\s]'),
    '',
  );
  if (c.isEmpty) return null;

  final isPostgradSingle =
      c.contains('mtech') || c.contains('msc') || c.contains('phd');
  if (isPostgradSingle) return 1;

  if (c.contains('diploma')) return 3;

  final isBE = c == 'be' || c.contains('btech');
  if (isBE) {
    if (year <= 2) return 3;
    return singleRoomEligible ? 1 : 3;
  }

  return null;
}

/// "Single" / "3-Seater", for messages referencing [requiredRoomCapacity]'s
/// result. Distinct from [Room.capacityLabel] in hostel.dart, which uses
/// "Seater" without the hyphen — kept as its own string here rather than
/// importing the model, since this file is deliberately Firebase-free.
String roomTypeLabel(int capacity) => capacity == 1 ? 'Single' : '$capacity-Seater';

/// "1st", "2nd", "3rd", "4th", "5th"... for display. Falls back to a bare
/// number past 20th's teens exception, which no hostel course reaches
/// anyway, but the formula stays correct if one ever does.
String ordinal(int year) {
  if (year % 100 >= 11 && year % 100 <= 13) return '${year}th';
  return switch (year % 10) {
    1 => '${year}st',
    2 => '${year}nd',
    3 => '${year}rd',
    _ => '${year}th',
  };
}

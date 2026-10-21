import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/hostel.dart';

/// Hostels read in building order, not dictionary order.
///
/// Plain string comparison files BH-10 between BH-1 and BH-2, because it
/// compares "1" then "0" against "2" one character at a time. Every list of
/// hostels in the app — the cards, the fees filter, the overview filter —
/// shares this comparator so they cannot disagree about the order.
void main() {
  Hostel h(String code, {String name = 'House'}) =>
      Hostel(id: code, name: name, code: code);

  List<String> ordered(List<String> codes) =>
      (codes.map((c) => h(c)).toList()..sort(Hostel.compareByCode))
          .map((x) => x.code)
          .toList();

  group('numbers inside codes sort as numbers', () {
    test('BH-10 comes after BH-9, not after BH-1', () {
      expect(ordered(['BH-10', 'BH-2', 'BH-1', 'BH-9']), [
        'BH-1',
        'BH-2',
        'BH-9',
        'BH-10',
      ]);
    });

    test('a full block of ten sorts correctly', () {
      final codes = [for (var i = 10; i >= 1; i--) 'BH-$i'];
      expect(ordered(codes), [for (var i = 1; i <= 10; i++) 'BH-$i']);
    });

    test('past ten keeps going', () {
      expect(ordered(['BH-100', 'BH-20', 'BH-3']), [
        'BH-3',
        'BH-20',
        'BH-100',
      ]);
    });
  });

  group('prefixes group before numbers are compared', () {
    test('every BH sorts before every GH', () {
      expect(ordered(['GH-1', 'BH-9', 'GH-2', 'BH-10']), [
        'BH-9',
        'BH-10',
        'GH-1',
        'GH-2',
      ]);
    });

    test('a code with no number still has a place', () {
      final out = ordered(['BH-2', 'PG GIRLS', 'BH-1']);
      expect(out.take(2), ['BH-1', 'BH-2']);
      expect(out.last, 'PG GIRLS');
    });
  });

  group('edge cases that must not throw', () {
    test('falls back to the name when there is no code', () {
      final list = [
        Hostel(id: 'b', name: 'Zeta House', code: ''),
        Hostel(id: 'a', name: 'Alpha House', code: ''),
      ]..sort(Hostel.compareByCode);
      expect(list.map((x) => x.name), ['Alpha House', 'Zeta House']);
    });

    test('case does not change the order', () {
      expect(ordered(['bh-2', 'BH-1']), ['BH-1', 'bh-2']);
    });

    test('identical codes compare equal rather than flipping', () {
      expect(Hostel.compareByCode(h('BH-1'), h('BH-1')), 0);
    });

    test('an empty list and a single item are fine', () {
      expect(ordered(const []), isEmpty);
      expect(ordered(['BH-7']), ['BH-7']);
    });
  });

  group('the label comparator matches, for dropdowns', () {
    test('same ordering when all a screen has is the text', () {
      final labels = ['BH-10', 'BH-2', 'Unallotted', 'BH-1']
        ..sort(Hostel.compareLabels);
      expect(labels.take(3), ['BH-1', 'BH-2', 'BH-10']);
    });
  });
}

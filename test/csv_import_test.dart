import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/services/csv_import.dart';

void main() {
  group('parseSem', () {
    test('accepts the shapes a real college sheet contains', () {
      expect(parseSem('5'), 5);
      expect(parseSem('Sem 5'), 5);
      expect(parseSem('sem5'), 5);
      expect(parseSem('5th'), 5);
      expect(parseSem(' 3 '), 3);
    });

    test('accepts roman numerals', () {
      expect(parseSem('V'), 5);
      expect(parseSem('III Sem'), 3);
      expect(parseSem('viii'), 8);
    });

    test('rejects what is not a semester', () {
      expect(parseSem(null), isNull);
      expect(parseSem(''), isNull);
      expect(parseSem('N/A'), isNull);
      expect(parseSem('0'), isNull);
      expect(parseSem('99'), isNull);
    });
  });

  group('batchFromRegistrationNo', () {
    test('reads the admission year off the registration number', () {
      expect(batchFromRegistrationNo('2110910'), '2021-22');
      expect(batchFromRegistrationNo('2316309'), '2023-24');
      expect(batchFromRegistrationNo('2040272'), '2020-21');
      expect(batchFromRegistrationNo('2244125'), '2022-23');
    });

    test('pads a single-digit end year', () {
      expect(batchFromRegistrationNo('0812345'), '2008-09');
    });

    test('refuses a number it cannot read as a year', () {
      expect(batchFromRegistrationNo(null), isNull);
      expect(batchFromRegistrationNo(''), isNull);
      expect(batchFromRegistrationNo('X'), isNull);
      expect(batchFromRegistrationNo('AB12345'), isNull);
      // A year far in the future is a typo, not a batch.
      expect(batchFromRegistrationNo('9912345'), isNull);
    });
  });

  group('normaliseState', () {
    test('accepts the abbreviations college sheets actually use', () {
      expect(normaliseState('UP'), 'Uttar Pradesh');
      expect(normaliseState('MP'), 'Madhya Pradesh');
      expect(normaliseState('  punjab '), 'Punjab');
      expect(normaliseState('Tamilnadu'), 'Tamil Nadu');
      expect(normaliseState('Orissa'), 'Odisha');
      expect(normaliseState('J&K'), 'Jammu and Kashmir');
    });

    test('refuses what is not a state, rather than inventing one', () {
      expect(normaliseState(null), isNull);
      expect(normaliseState(''), isNull);
      expect(normaliseState('Ludhiana'), isNull);
      expect(normaliseState('12345'), isNull);
    });
  });

  group('stateFromAddress', () {
    test('reads the state off a "City, State" address', () {
      expect(stateFromAddress('Ludhiana, Punjab'), 'Punjab');
      expect(stateFromAddress('Kanpur, UP'), 'Uttar Pradesh');
      expect(stateFromAddress('Bhopal, MP'), 'Madhya Pradesh');
      expect(stateFromAddress('Ranchi, Jharkhand'), 'Jharkhand');
    });

    test('scans backwards, so a three-part address still works', () {
      expect(
        stateFromAddress('Village Rampur, Sangrur District, Punjab'),
        'Punjab',
      );
    });

    test('returns null when no segment is a state', () {
      expect(stateFromAddress('Somewhere, Nowhere'), isNull);
      expect(stateFromAddress(''), isNull);
      expect(stateFromAddress(null), isNull);
    });

    test('two spellings of one state collapse to the same bucket', () {
      // The whole point: otherwise the dashboard charts them separately.
      expect(
        stateFromAddress('Kanpur, UP'),
        stateFromAddress('Lucknow, Uttar Pradesh'),
      );
    });
  });

  group('every trade in the test sheet is a known code', () {
    test('kTrades covers the SLIET codes we import', () {
      const inSheet = [
        'DCE-CBM', 'DEC-CSME', 'DEE-CEN', 'DFT-CFP', 'DME-CAF', 'DME-CFF',
        'DME-CTD', 'GCS', 'GCT', 'GEC', 'GEE', 'GIN', 'GME', 'PGFET',
        'PGMATH', 'PGWLF',
      ];
      for (final t in inSheet) {
        expect(kTrades, contains(t), reason: '$t missing from kTrades');
      }
    });
  });

  group('header aliasing', () {
    test('maps the column names a college sheet actually uses', () {
      final table = parseDelimited(
        'Student Name,Registration Number,Branch,Semester,Batch,Hostel Number,'
        'Room No\n'
        'Om Kumar,2110910,DCE-CBM,Sem 5,2021-22,BH-01,101',
      );
      expect(table.headers, [
        'name',
        'registrationNo',
        'trade',
        'sem',
        'batch',
        'hostel',
        'room',
      ]);
      expect(table.rows.single.first, 'Om Kumar');
    });

    test('trade and sem no longer collide with course and year', () {
      final table = parseDelimited('course,year,trade,sem\nB.E.,3rd,GME,5');
      expect(table.headers, ['course', 'year', 'trade', 'sem']);
    });
  });
}

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

  group('the downloadable template', () {
    // The example row is built positionally, so adding or removing a column
    // in one list and not the other silently shifts every value after it
    // under the wrong header. That has happened once already — the template
    // itself then teaches people the wrong shape, and the import "succeeds"
    // with every field one column out.
    test('the example row has exactly one value per column', () {
      final lines = templateWithExample().split('\n');
      final header = parseDelimited(templateWithExample()).headers;
      final example = parseDelimited(templateWithExample()).rows.single;

      expect(lines, hasLength(2));
      expect(header, hasLength(kImportColumns.length));
      expect(
        example,
        hasLength(kImportColumns.length),
        reason: 'example row and kImportColumns have drifted apart',
      );
    });

    test('the example lands each value under the right header', () {
      final table = parseDelimited(templateWithExample());
      final row = <String, String>{
        for (var i = 0; i < table.headers.length; i++)
          table.headers[i]: table.rows.single[i],
      };

      // Spot-check either side of where columns have been added and removed.
      expect(row['name'], 'Aarav Sharma');
      expect(row['registrationNo'], '2040353');
      expect(row['room'], '101');
      expect(row['dateOfBirth'], '14/03/2004');
      expect(row['address'], 'Ludhiana, Punjab');
      expect(row['pinCode'], '141001');
    });

    test('office room is gone — it was never a student field', () {
      expect(kImportColumns, isNot(contains('officeRoom')));
      // And the header aliases must not quietly resurrect it.
      final table = parseDelimited('name,Office Room\nAarav,Admin Block 12');
      expect(table.headers, isNot(contains('officeRoom')));
    });
  });
}

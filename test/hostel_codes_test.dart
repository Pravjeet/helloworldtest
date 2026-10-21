import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/core/hostel_codes.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/models/hostel.dart';

void main() {
  tearDown(() => HostelCodes.update(const []));

  group('HostelCodes', () {
    setUp(
      () => HostelCodes.update(const [
        Hostel(id: 'h3', name: 'Meghnad Saha House', code: 'BH-3'),
        Hostel(id: 'h9', name: 'Uncoded Block', code: ''),
      ]),
    );

    test('a stored name reads as its code', () {
      expect(HostelCodes.of('Meghnad Saha House'), 'BH-3');
    });

    test('ignores case and stray spaces from old records', () {
      expect(HostelCodes.of('  meghnad saha house '), 'BH-3');
    });

    test('an id wins over a name, so a renamed hostel still resolves', () {
      expect(HostelCodes.of('Old Name', id: 'h3'), 'BH-3');
    });

    test('a hostel with no code keeps its name', () {
      expect(HostelCodes.of('Uncoded Block'), 'Uncoded Block');
    });

    test('an unknown hostel falls back to the name it was given', () {
      expect(HostelCodes.of('Somewhere Else'), 'Somewhere Else');
      expect(HostelCodes.of(null), isNull);
    });

    test('roomLabel uses the code', () {
      const u = AppUser(
        uid: 'u',
        name: 'u',
        email: 'u@x.test',
        collegeId: 'c',
        hostelId: 'h3',
        hostelName: 'Meghnad Saha House',
        roomId: '5',
        roomNumber: '5',
      );
      expect(u.roomLabel, 'BH-3 · Room 5');
    });
  });

  group('religionLabel', () {
    test('matches the standard list whatever the case', () {
      expect(religionLabel(' hindu '), 'Hindu');
      expect(religionLabel('SIKH'), 'Sikh');
    });

    test('keeps an unlisted value as typed', () {
      expect(religionLabel('Baháʼí'), 'Baháʼí');
    });

    test('blank means nothing recorded', () {
      expect(religionLabel('  '), isNull);
      expect(religionLabel(null), isNull);
    });
  });
}

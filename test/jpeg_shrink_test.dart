import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/utils/jpeg_shrink.dart';
import 'package:image/image.dart' as img;

/// Office-order scans are shrunk to 70 KB before upload. The worry with a
/// budget that tight is legibility, so this pins both halves: a phone photo
/// of a printed page does fit, and it is not squeezed to a thumbnail to get
/// there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A phone photo of an A4 page: off-white paper with slight sensor noise
  /// and rows of dark "text" strokes.
  Uint8List pagePhoto() {
    final rnd = Random(3);
    final page = img.Image(width: 3000, height: 4000);
    for (final p in page) {
      final v = 235 + rnd.nextInt(12);
      p
        ..r = v
        ..g = v
        ..b = v - 6;
    }
    for (var y = 400; y < 3700; y += 70) {
      var x = 300;
      while (x < 2700) {
        final word = 60 + rnd.nextInt(180);
        img.fillRect(
          page,
          x1: x,
          y1: y,
          x2: x + word,
          y2: y + 28,
          color: img.ColorRgb8(30, 30, 40),
        );
        x += word + 40;
      }
    }
    return img.encodeJpg(page, quality: 90);
  }

  test('even an ink-heavy page fits in 70 KB with its text intact', () async {
    final source = pagePhoto();
    expect(source.length, greaterThan(500 * 1024));

    final out = await shrinkToJpeg(
      source,
      maxEdge: 1600,
      maxBytes: 70 * 1024,
      whitenPaper: true,
    );

    expect(out.lengthInBytes, lessThanOrEqualTo(70 * 1024));
    final decoded = img.decodeJpg(out)!;
    // This page is a deliberate worst case — about 22% solid ink, where a
    // typed letter is 5-8% — so it lands at the smaller end of the ladder.
    // It must still fit without falling off the bottom of it.
    expect(decoded.height, greaterThanOrEqualTo(640));
    expect(decoded.width / decoded.height, closeTo(0.75, 0.01));
    // The text is still there: dark strokes survive the paper whitening.
    final ink = decoded.where((p) => p.r < 90).length;
    expect(ink, greaterThan(decoded.width * decoded.height * 0.05));
  });
}

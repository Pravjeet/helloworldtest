import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/services/photo_service.dart';
import 'package:image/image.dart' as img;

/// ID photos are shrunk on the device before they go into Firestore, because
/// a raw phone photo (3–5 MB) cannot fit in a document at all and thousands
/// of them would blow the Spark plan's 1 GiB. These pin the three promises
/// the upload button makes: any real photo fits, a too-small one is refused,
/// and something that isn't an image is refused rather than stored.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A camera-sized photo with enough noise that it compresses like a real
  /// one rather than to a few hundred bytes.
  Uint8List cameraShot({int width = 3000, int height = 4000}) {
    final rnd = Random(7);
    final image = img.Image(width: width, height: height);
    for (final p in image) {
      p
        ..r = (p.x * 255 ~/ width + rnd.nextInt(60)).clamp(0, 255)
        ..g = (p.y * 255 ~/ height + rnd.nextInt(60)).clamp(0, 255)
        ..b = rnd.nextInt(255);
    }
    return img.encodeJpg(image, quality: 92);
  }

  test('a full-size portrait photo is shrunk to a small JPEG', () async {
    final source = cameraShot();
    expect(source.lengthInBytes, greaterThan(1024 * 1024));

    final out = await PhotoService.prepare(source);

    expect(out.lengthInBytes, lessThanOrEqualTo(PhotoService.maxStoredBytes));
    // JPEG magic bytes — stored as JPEG whatever was picked.
    expect(out.sublist(0, 2), [0xFF, 0xD8]);
    final decoded = img.decodeJpg(out)!;
    expect(decoded.height, PhotoService.maxEdge);
    // Aspect ratio kept (3:4), not squashed into a square.
    expect(decoded.width, 360);
  });

  test('a landscape photo is limited by its width instead', () async {
    final out = await PhotoService.prepare(
      cameraShot(width: 2000, height: 1000),
    );
    final decoded = img.decodeJpg(out)!;
    expect(decoded.width, PhotoService.maxEdge);
    expect(decoded.height, 240);
  });

  test('anything under 20 KB is refused as too little to recognise', () async {
    final tiny = img.encodeJpg(img.Image(width: 40, height: 50), quality: 50);
    expect(tiny.lengthInBytes, lessThan(PhotoService.minSourceBytes));

    expect(
      () => PhotoService.prepare(tiny),
      throwsA(
        isA<PhotoRejected>().having(
          (e) => e.message,
          'message',
          contains('at least 20 KB'),
        ),
      ),
    );
  });

  test('a file that is not an image is refused, not stored', () async {
    final junk = Uint8List.fromList(
      List.generate(40 * 1024, (i) => (i * 31) % 256),
    );

    expect(() => PhotoService.prepare(junk), throwsA(isA<PhotoRejected>()));
  });
}

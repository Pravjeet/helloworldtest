import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// A picked file that can't be stored. [message] is shown verbatim.
class PhotoRejected implements Exception {
  final String message;
  const PhotoRejected(this.message);

  @override
  String toString() => message;
}

/// Shrinks any picked image to a JPEG of at most [maxBytes], or throws
/// [PhotoRejected].
///
/// There is no Firebase Storage on the Spark plan, so every image the app
/// keeps is base64 inside a Firestore document, and the budget is set by the
/// caller. Rather than refusing a 4 MB phone photo and making staff shrink it
/// elsewhere, this does it: largest size first, then lower quality, then a
/// smaller size — so the result is as legible as the budget allows.
///
/// Decoding and the first downscale go through the engine's own codec (fast,
/// and it honours a phone's EXIF rotation); only the JPEG encode and any
/// further resizing are pure Dart, on an image already a manageable size.
Future<Uint8List> shrinkToJpeg(
  Uint8List source, {
  required int maxEdge,
  required int maxBytes,
  List<double> edgeSteps = const [1, 0.88, 0.77, 0.68, 0.6, 0.52, 0.45, 0.4],
  List<int> qualities = const [82, 70, 58, 46],
  bool whitenPaper = false,
}) async {
  final ui.Image decoded;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(source);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        if (w <= maxEdge && h <= maxEdge) {
          return ui.TargetImageSize(width: w, height: h);
        }
        // One side only — the engine keeps the aspect ratio.
        return w >= h
            ? ui.TargetImageSize(width: maxEdge)
            : ui.TargetImageSize(height: maxEdge);
      },
    );
    decoded = (await codec.getNextFrame()).image;
    codec.dispose();
  } catch (_) {
    throw const PhotoRejected('That file could not be read as an image.');
  }

  final img.Image full;
  try {
    final data = await decoded.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw const PhotoRejected('That file could not be read as an image.');
    }
    if (whitenPaper) _whitenPaper(data.buffer.asUint8List());
    full = img.Image.fromBytes(
      width: decoded.width,
      height: decoded.height,
      bytes: data.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  } finally {
    decoded.dispose();
  }

  final longest = full.width >= full.height ? full.width : full.height;
  for (final step in edgeSteps) {
    final edge = (longest * step).round();
    final pixels = step == 1
        ? full
        : img.copyResize(
            full,
            width: full.width >= full.height ? edge : null,
            height: full.width >= full.height ? null : edge,
            interpolation: img.Interpolation.average,
          );
    for (final quality in qualities) {
      // 4:2:0, as every camera writes: colour at half resolution costs
      // nothing visible and roughly halves the size.
      final jpeg = img.encodeJpg(
        pixels,
        quality: quality,
        chroma: img.JpegChroma.yuv420,
      );
      if (jpeg.lengthInBytes <= maxBytes) return jpeg;
    }
  }
  throw PhotoRejected(
    'That image could not be compressed under ${maxBytes ~/ 1024} KB. Try a '
    'photo with less background around it.',
  );
}

/// What a scanner app does to a phone photo of a page: lifts the paper to
/// pure white. Paper photographed under a tube light is grey and grainy, and
/// JPEG spends most of a small budget faithfully encoding that grain; flat
/// white costs almost nothing, leaving the bytes for the text.
///
/// Global levels, not per-region: the brightest ~15% of the image is taken as
/// the paper and scaled to white, and anything that ends up near-white snaps
/// to it. Ink, signatures and stamps are far darker and survive untouched in
/// hue — only brightened by the same factor.
void _whitenPaper(Uint8List rgba) {
  final histogram = List<int>.filled(256, 0);
  for (var i = 0; i < rgba.length; i += 4) {
    histogram[(rgba[i] * 77 + rgba[i + 1] * 150 + rgba[i + 2] * 29) >> 8]++;
  }
  final pixels = rgba.length ~/ 4;
  var seen = 0;
  var paper = 255;
  for (var v = 255; v >= 0; v--) {
    seen += histogram[v];
    if (seen >= pixels * 0.15) {
      paper = v;
      break;
    }
  }
  // A dark or mostly-dark image isn't a page; leave it as it is.
  if (paper < 110) return;

  final scale = 255 / (paper * 0.94);
  for (var i = 0; i < rgba.length; i += 4) {
    final r = (rgba[i] * scale).round().clamp(0, 255);
    final g = (rgba[i + 1] * scale).round().clamp(0, 255);
    final b = (rgba[i + 2] * scale).round().clamp(0, 255);
    if (r > 232 && g > 232 && b > 232) {
      rgba[i] = rgba[i + 1] = rgba[i + 2] = 255;
    } else {
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
    }
  }
}

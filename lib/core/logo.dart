import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme.dart';

/// The mark shown in the sidebar: a college's own uploaded photo if it has
/// one, otherwise the drawn [HomiLogo]. Kept as one widget so every call
/// site gets the fallback for free instead of repeating the null check.
class WorkspaceLogo extends StatelessWidget {
  final String? logoBase64;
  final double size;
  final Color? background;
  final bool bare;

  const WorkspaceLogo({
    super.key,
    required this.logoBase64,
    this.size = 56,
    this.background,
    this.bare = false,
  });

  @override
  Widget build(BuildContext context) {
    final bytes = _decodeLogo(logoBase64);
    if (bytes == null) {
      return HomiLogo(size: size, background: background, bare: bare);
    }

    final image = Image.memory(
      bytes,
      fit: BoxFit.cover,
      // A stored photo that fails to decode (truncated write, corrupt data)
      // shouldn't blank the sidebar — fall back exactly as if none was set.
      errorBuilder: (_, __, ___) =>
          HomiLogo(size: size, background: background, bare: bare),
    );

    if (bare) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: SizedBox.square(dimension: size, child: image),
      );
    }

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: (background ?? AppColors.primary).withValues(alpha: 0.32),
            blurRadius: size * 0.22,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: image,
    );
  }
}

Uint8List? _decodeLogo(String? base64) {
  if (base64 == null || base64.isEmpty) return null;
  try {
    return base64Decode(base64);
  } catch (_) {
    return null;
  }
}

/// The Homi Hostel mark.
///
/// Two towers of unequal height under a shared roofline, with a window grid —
/// and the windows are the point. Some are lit and some are dark, because the
/// one thing this app exists to answer is *which beds are occupied*. A generic
/// shield or house icon says "an app"; a facade with a half-filled window grid
/// says "occupancy", which is the actual subject.
///
/// Drawn rather than shipped as an image: it stays crisp at any size, it
/// recolours with the theme, and there is no asset to add to pubspec or forget
/// to include in a build.
class HomiLogo extends StatelessWidget {
  final double size;

  /// Colour of the badge behind the mark. The mark itself is always drawn in
  /// white/translucent white on top.
  ///
  /// Nullable so it can default to the *current* accent. A default of
  /// `AppColors.primary` would be baked in at compile time and the logo would
  /// stay indigo no matter what the workspace picked — which is exactly the
  /// bug this whole refactor exists to fix.
  final Color? background;

  /// Draw only the mark, no rounded-square badge — for placing on a surface
  /// that already provides its own container.
  final bool bare;

  const HomiLogo({
    super.key,
    this.size = 56,
    this.background,
    this.bare = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = background ?? AppColors.primary;

    final mark = CustomPaint(
      size: Size.square(size),
      painter: _HomiPainter(
        ink: bare ? bg : Colors.white,
        // Below roughly 22px the window grid turns to mud, so the painter
        // drops to a simplified two-tower silhouette.
        detailed: size >= 22,
      ),
    );

    if (bare) return SizedBox.square(dimension: size, child: mark);

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(bg, Colors.white, 0.18)!,
            bg,
            Color.lerp(bg, Colors.black, 0.22)!,
          ],
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: bg.withValues(alpha: 0.32),
            blurRadius: size * 0.22,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(size * 0.2),
        child: CustomPaint(
          painter: _HomiPainter(ink: Colors.white, detailed: size >= 22),
        ),
      ),
    );
  }
}

class _HomiPainter extends CustomPainter {
  final Color ink;
  final bool detailed;

  const _HomiPainter({required this.ink, required this.detailed});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final solid = Paint()..color = ink;
    final dim = Paint()..color = ink.withValues(alpha: 0.34);

    // --- roofline: a shallow pitch spanning both towers ---
    final roofH = h * 0.2;
    final roof = Path()
      ..moveTo(0, roofH)
      ..lineTo(w * 0.5, 0)
      ..lineTo(w, roofH)
      ..lineTo(w * 0.88, roofH)
      ..lineTo(w * 0.5, h * 0.075)
      ..lineTo(w * 0.12, roofH)
      ..close();
    canvas.drawPath(roof, solid);

    // --- two towers, unequal heights ---
    final tallTop = h * 0.28;
    final shortTop = h * 0.42;
    final base = h;

    final leftRect = RRect.fromLTRBAndCorners(
      w * 0.06,
      tallTop,
      w * 0.46,
      base,
      topLeft: Radius.circular(w * 0.04),
      topRight: Radius.circular(w * 0.04),
    );
    final rightRect = RRect.fromLTRBAndCorners(
      w * 0.54,
      shortTop,
      w * 0.94,
      base,
      topLeft: Radius.circular(w * 0.04),
      topRight: Radius.circular(w * 0.04),
    );

    if (!detailed) {
      // Small sizes: solid silhouette, still reads as two buildings.
      canvas.drawRRect(leftRect, solid);
      canvas.drawRRect(rightRect, solid);
      return;
    }

    final outline = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(w * 0.045, 1.1);

    canvas.drawRRect(leftRect, outline);
    canvas.drawRRect(rightRect, outline);

    // --- windows: filled = occupied, outlined = free ---
    //
    // The pattern is fixed, not random: a logo that redraws differently on
    // each build is not a logo.
    const leftLit = [true, false, true, true, false, true];
    const rightLit = [false, true, true, false];

    void grid(RRect box, int cols, int rows, List<bool> lit) {
      final inset = w * 0.055;
      final left = box.left + inset;
      final right = box.right - inset;
      final top = box.top + inset * 1.25;
      final bottom = box.bottom - inset;
      final cellW = (right - left) / cols;
      final cellH = (bottom - top) / rows;
      final pad = math.min(cellW, cellH) * 0.24;

      var i = 0;
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final on = i < lit.length && lit[i];
          i++;
          final rect = RRect.fromRectAndRadius(
            Rect.fromLTRB(
              left + c * cellW + pad,
              top + r * cellH + pad,
              left + (c + 1) * cellW - pad,
              top + (r + 1) * cellH - pad,
            ),
            Radius.circular(w * 0.018),
          );
          canvas.drawRRect(rect, on ? solid : dim);
        }
      }
    }

    grid(leftRect, 2, 3, leftLit);
    grid(rightRect, 2, 2, rightLit);
  }

  @override
  bool shouldRepaint(_HomiPainter old) =>
      old.ink != ink || old.detailed != detailed;
}

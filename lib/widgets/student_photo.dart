import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/app_user.dart';
import '../services/photo_service.dart';

/// Someone's ID photo, or their initials when there isn't one.
///
/// Takes [collegeId] explicitly instead of reading the session, because it is
/// used inside dialogs — which sit above SessionScope, where `Session.of`
/// throws.
///
/// [hasPhoto] decides whether a read is spent at all: false (a loaded profile
/// with no `photoUpdatedAt`) paints initials for free; null means "unknown"
/// (only a uid is at hand, as on a fine) and tries the one read.
///
/// Tapping a real photo opens it large — the size a guard actually compares a
/// face against.
class StudentPhoto extends StatefulWidget {
  final String collegeId;
  final String uid;
  final String name;
  final bool? hasPhoto;
  final DateTime? version;
  final double width;
  final double height;
  final double radius;
  final bool enlargeOnTap;

  const StudentPhoto({
    super.key,
    required this.collegeId,
    required this.uid,
    required this.name,
    this.hasPhoto,
    this.version,
    this.width = 48,
    this.height = 64,
    this.radius = 10,
    this.enlargeOnTap = true,
  });

  /// From a loaded profile — skips the read entirely when they have no photo.
  /// Portrait 3:4 unless [height] is given.
  factory StudentPhoto.user(
    AppUser user, {
    Key? key,
    double width = 48,
    double? height,
    double radius = 10,
    bool enlargeOnTap = true,
  }) => StudentPhoto(
    key: key,
    collegeId: user.collegeId,
    uid: user.uid,
    name: user.name,
    hasPhoto: user.hasPhoto,
    version: user.photoUpdatedAt,
    width: width,
    height: height ?? width * 4 / 3,
    radius: radius,
    enlargeOnTap: enlargeOnTap,
  );

  @override
  State<StudentPhoto> createState() => _StudentPhotoState();
}

class _StudentPhotoState extends State<StudentPhoto> {
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(StudentPhoto old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid ||
        old.collegeId != widget.collegeId ||
        old.hasPhoto != widget.hasPhoto ||
        old.version != widget.version) {
      _resolve();
    }
  }

  void _resolve() {
    _future = widget.hasPhoto == false
        ? null
        : PhotoService.instance.load(
            widget.collegeId,
            widget.uid,
            version: widget.version,
          );
  }

  @override
  Widget build(BuildContext context) {
    if (_future == null) return _placeholder(loading: false);

    // Already fetched earlier in the session: paint it on this frame rather
    // than showing a placeholder for one first.
    final ready = PhotoService.instance.peek(
      widget.collegeId,
      widget.uid,
      version: widget.version,
    );
    if (ready != null) return _photo(ready);

    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes != null) return _photo(bytes);
        return _placeholder(
          loading: snap.connectionState != ConnectionState.done,
        );
      },
    );
  }

  Widget _photo(Uint8List bytes) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        // Decoded at roughly the painted size, not the stored 480px, so a
        // list of faces doesn't hold full bitmaps for every one.
        cacheWidth: (widget.width * dpr).round(),
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => _placeholder(loading: false),
      ),
    );
    if (!widget.enlargeOnTap) return image;
    return MouseRegion(
      cursor: SystemMouseCursors.zoomIn,
      child: GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.82),
          builder: (_) => _PhotoViewer(bytes: bytes, name: widget.name),
        ),
        child: image,
      ),
    );
  }

  Widget _placeholder({required bool loading}) {
    final big = widget.width >= 80;
    return Container(
      width: widget.width,
      height: widget.height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: loading && big
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _initials(widget.name),
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: (widget.width * 0.3).clamp(11.0, 30.0),
                  ),
                ),
                if (big && !loading) ...[
                  const SizedBox(height: 4),
                  Text(
                    'No photo',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class _PhotoViewer extends StatelessWidget {
  final Uint8List bytes;
  final String name;

  const _PhotoViewer({required this.bytes, required this.name});

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                tooltip: 'Close',
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

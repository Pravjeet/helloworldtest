import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../models/college_notice.dart';
import '../../services/college_feed_service.dart';

/// Notices pulled from the college's own website.
///
/// Read-only by nature — these belong to SLIET, not to this app, so there is
/// no create, edit or delete here. Tapping a row opens the linked PDF (or the
/// post) in the user's browser.
class CollegeNoticesView extends StatefulWidget {
  const CollegeNoticesView({super.key});

  @override
  State<CollegeNoticesView> createState() => _CollegeNoticesViewState();
}

class _CollegeNoticesViewState extends State<CollegeNoticesView> {
  late Future<List<CollegeNotice>> _future;
  bool _studentsOnly = false;

  @override
  void initState() {
    super.initState();
    _future = CollegeFeedService.instance.fetchLatest();
  }

  void _reload() {
    CollegeFeedService.instance.invalidate();
    setState(() {
      _future = CollegeFeedService.instance.fetchLatest(forceRefresh: true);
    });
  }

  Future<void> _open(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open that link')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CollegeNotice>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snap.hasError) {
          return _Unavailable(
            error: snap.error!,
            onRetry: _reload,
            onOpenSite: () => _open(CollegeFeedService.noticesPageUrl),
          );
        }

        final all = snap.data ?? const <CollegeNotice>[];
        final shown = _studentsOnly
            ? all.where((n) => n.forStudents).toList()
            : all;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Row(
                children: [
                  Icon(
                    Icons.public_rounded,
                    size: 19,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Published on sliet.ac.in. Read-only — tap to open the '
                      'notice.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilterChip(
                    label: const Text('For students'),
                    selected: _studentsOnly,
                    onSelected: (v) => setState(() => _studentsOnly = v),
                    selectedColor: AppColors.primarySoft,
                    labelStyle: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _studentsOnly
                          ? AppColors.primary
                          : AppColors.textStrong,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    tooltip: 'Refresh from the college website',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (shown.isEmpty)
              AppCard(
                padding: const EdgeInsets.symmetric(vertical: 54),
                child: Center(
                  child: Text(
                    _studentsOnly
                        ? 'None of the latest notices are tagged for students.'
                        : 'The college has not posted any notices.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              )
            else
              AppCard(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    for (var i = 0; i < shown.length; i++) ...[
                      _CollegeRow(
                        notice: shown[i],
                        onTap: () => _open(shown[i].target),
                      ),
                      if (i != shown.length - 1)
                        Divider(
                          height: 1,
                          indent: 20,
                          endIndent: 20,
                          color: AppColors.border,
                        ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 14),
            Center(
              child: TextButton.icon(
                onPressed: () => _open(CollegeFeedService.noticesPageUrl),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('See all notices on sliet.ac.in'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CollegeRow extends StatelessWidget {
  final CollegeNotice notice;
  final VoidCallback onTap;

  const _CollegeRow({required this.notice, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = notice.published;
    final dateStr = d == null
        ? ''
        : '${d.day} ${months[d.month - 1]} ${d.year}';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 40,
              width: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.canvas,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                notice.isPdf
                    ? Icons.picture_as_pdf_rounded
                    : Icons.article_outlined,
                size: 19,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notice.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (dateStr.isNotEmpty)
                        Text(
                          dateStr,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      if (notice.forStudents) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            'STUDENTS',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.open_in_new_rounded,
              size: 16,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the feed can't be read.
///
/// On Flutter web a blocked cross-origin request is indistinguishable from
/// being offline, so this doesn't claim to know which it was — it offers the
/// two things that help either way.
class _Unavailable extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onOpenSite;

  const _Unavailable({
    required this.error,
    required this.onRetry,
    required this.onOpenSite,
  });

  @override
  Widget build(BuildContext context) {
    final e = error;
    final message = e is CollegeFeedException
        ? e.message
        : 'Could not load notices from the college website.';

    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 46, horizontal: 28),
      child: Column(
        children: [
          Container(
            height: 58,
            width: 58,
            decoration: BoxDecoration(
              color: AppColors.canvas,
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(
              Icons.cloud_off_rounded,
              size: 27,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              'Notices posted here in the app are unaffected — this only '
              'covers the feed from sliet.ac.in.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Try again'),
              ),
              FilledButton.icon(
                onPressed: onOpenSite,
                icon: const Icon(Icons.open_in_new_rounded, size: 17),
                label: const Text('Open sliet.ac.in'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

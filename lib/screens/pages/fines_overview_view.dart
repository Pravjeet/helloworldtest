import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/fine.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/fine_service.dart';
import '../../services/hostel_service.dart';
import 'fines_shared.dart';

/// The fines analytics dashboard, modelled on the institute's Power BI report.
///
/// Laid out the same way that report is: headline counts top-left, a row of
/// dropdown filters beneath, the charts in a grid, and every click-to-filter
/// slicer gathered into a rail down the right-hand side. Colours follow the
/// app's own palette rather than the report's pink — one differently-coloured
/// screen in an otherwise indigo app reads as a bug, not a feature.
///
/// Everything cross-filters: pick a semester, or click a bar, and every tile,
/// chart and slicer count below updates together.
class FinesOverviewView extends StatefulWidget {
  final String collegeId;
  final VoidCallback onBack;

  const FinesOverviewView({
    super.key,
    required this.collegeId,
    required this.onBack,
  });

  @override
  State<FinesOverviewView> createState() => _FinesOverviewViewState();
}

class _FinesOverviewViewState extends State<FinesOverviewView> {
  String? _hostel;
  String? _batch;
  String? _sem;
  String? _trade;
  String? _state;
  String? _status;
  String? _regNo;
  String? _officeOrder;
  String? _room;
  String? _year;

  /// Hostel display name -> short code ("Birbal Sahni House" -> "BH-01").
  ///
  /// Fines snapshot the hostel's full name, which is the right thing to store
  /// but unreadable on a bar chart — ten "… House" labels overlap into mush.
  /// Resolved from the hostels collection rather than denormalised onto every
  /// fine: it is one small read for the page, versus a field on thousands of
  /// documents that would go stale the moment a block is renamed.
  Map<String, String> _codes = const {};

  /// Every hostel currently in the college, labelled the same way the chart
  /// and filters are — so "Hostel" always offers every hostel that exists,
  /// not just the ones that happen to already have a fine recorded against
  /// them. A hostel with zero fines is still a real filter choice; it should
  /// show an empty result, not be missing from the list entirely.
  List<String> _allHostelLabels = const [];

  String _hostelLabel(String? name) {
    if (name == null || name.trim().isEmpty) return 'None';
    return _codes[name] ?? name;
  }

  /// Click to select, click again to clear — how a report slicer behaves.
  void _toggle(String? current, String value, ValueChanged<String?> set) =>
      setState(() => set(current == value ? null : value));

  // The hostel filter holds a CODE, since that is what the chart and the
  // slicer both show — comparing against the label keeps the two in step.
  bool _keep(Fine f) =>
      (_hostel == null || _hostelLabel(f.hostelName) == _hostel) &&
      (_batch == null || f.batch == _batch) &&
      (_sem == null || '${f.sem}' == _sem) &&
      (_trade == null || f.trade == _trade) &&
      (_state == null || (f.state ?? 'Not set') == _state) &&
      (_status == null || f.status.name == _status) &&
      (_regNo == null || f.studentRegNo == _regNo) &&
      (_officeOrder == null || f.officeOrderNo == _officeOrder) &&
      (_room == null || f.roomNumber == _room) &&
      (_year == null || '${f.createdAt?.year}' == _year);

  bool get _anyFilter =>
      _hostel != null ||
      _batch != null ||
      _sem != null ||
      _trade != null ||
      _state != null ||
      _status != null ||
      _regNo != null ||
      _officeOrder != null ||
      _room != null ||
      _year != null;

  void _clearAll() => setState(() {
    _hostel = _batch = _sem = _trade = _state = null;
    _status = _regNo = _officeOrder = _room = _year = null;
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Hostel>>(
      stream: HostelService.instance.watchHostels(widget.collegeId),
      builder: (context, hostelSnap) {
        final hostels = hostelSnap.data ?? const <Hostel>[];
        _codes = {
          for (final h in hostels)
            if (h.code.trim().isNotEmpty) h.name: h.code,
        };
        _allHostelLabels =
            hostels
                .map((h) => h.code.trim().isNotEmpty ? h.code : h.name)
                .toList()
              ..sort();
        return _buildBody(context);
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    return StreamBuilder<List<Fine>>(
      stream: FineService.instance.watchAll(widget.collegeId),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(child: Text(AuthService.describeError(snap.error!)));
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final all = FineSummary(snap.data!);
        final shown = FineSummary(snap.data!.where(_keep).toList());

        // Every hostel that exists, plus any hostel name a fine still points
        // at even if that hostel has since been deleted — a filter option
        // must never disappear out from under a fine that references it.
        final hostelOptions = ({
          ..._allHostelLabels,
          ...all.valuesOf((f) => _hostelLabel(f.hostelName)),
        }.toList()..sort());

        // Same reasoning for trades: every trade the college runs, plus any
        // still referenced by an existing fine even if it was since removed
        // from the list.
        final tradeOptions = ({
          ...Session.of(context).settings.tradeCodes,
          ...all.valuesOf((f) => f.trade),
        }.toList()..sort());

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Banner(
              summary: shown,
              onBack: widget.onBack,
              anyFilter: _anyFilter,
              onClear: _clearAll,
            ),
            const SizedBox(height: 14),
            _Filters(
              all: all,
              hostelOptions: hostelOptions,
              regNo: _regNo,
              hostel: _hostel,
              officeOrder: _officeOrder,
              room: _room,
              status: _status,
              year: _year,
              onRegNo: (v) => setState(() => _regNo = v),
              onHostel: (v) => setState(() => _hostel = v),
              onOfficeOrder: (v) => setState(() => _officeOrder = v),
              onRoom: (v) => setState(() => _room = v),
              onStatus: (v) => setState(() => _status = v),
              onYear: (v) => setState(() => _year = v),
            ),
            const SizedBox(height: 14),
            // Charts on the left, slicer rail down the right — the report's
            // own arrangement.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Charts(
                    summary: shown,
                    hostelLabel: _hostelLabel,
                    onFilter: _onChartTap,
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 232,
                  child: _SlicerRail(
                    all: all,
                    hostelOptions: hostelOptions,
                    tradeOptions: tradeOptions,
                    sem: _sem,
                    trade: _trade,
                    batch: _batch,
                    hostel: _hostel,
                    state: _state,
                    onSem: (v) => _toggle(_sem, v, (x) => _sem = x),
                    onTrade: (v) => _toggle(_trade, v, (x) => _trade = x),
                    onBatch: (v) => _toggle(_batch, v, (x) => _batch = x),
                    onHostel: (v) => _toggle(_hostel, v, (x) => _hostel = x),
                    onState: (v) => _toggle(_state, v, (x) => _state = x),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _onChartTap(String dimension, String value) {
    switch (dimension) {
      case 'hostel':
        _toggle(_hostel, value, (x) => _hostel = x);
      case 'batch':
        _toggle(_batch, value, (x) => _batch = x);
      case 'sem':
        _toggle(_sem, value, (x) => _sem = x);
      case 'trade':
        _toggle(_trade, value, (x) => _trade = x);
      case 'state':
        _toggle(_state, value, (x) => _state = x);
    }
  }
}

// ------------------------------- banner -------------------------------

class _Banner extends StatelessWidget {
  final FineSummary summary;
  final VoidCallback onBack;
  final bool anyFilter;
  final VoidCallback onClear;

  const _Banner({
    required this.summary,
    required this.onBack,
    required this.anyFilter,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    child: Row(
      children: [
        IconButton(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to fines',
        ),
        const SizedBox(width: 6),
        _Headline('${summary.count}', 'Count of Amount of Fine'),
        const SizedBox(width: 14),
        _Headline(compactAmount(summary.total), 'Sum of Amount of Fine'),
        const SizedBox(width: 14),
        _Headline(
          compactAmount(summary.outstanding),
          'Still Outstanding',
          accentOverride: summary.outstanding == 0
              ? AppColors.success
              : AppColors.danger,
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                'Hostel Fines Dashboard',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Sant Longowal Institute of Engineering & Technology',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        if (anyFilter)
          TextButton.icon(
            onPressed: onClear,
            icon: Icon(Icons.filter_alt_off_rounded, size: 17),
            label: Text('Clear filters'),
          ),
      ],
    ),
  );
}

class _Headline extends StatelessWidget {
  final String value;
  final String label;

  /// Nullable so it resolves to the live accent rather than a colour baked in
  /// at compile time.
  final Color? accentOverride;
  const _Headline(this.value, this.label, {this.accentOverride});

  @override
  Widget build(BuildContext context) {
    final accent = accentOverride ?? AppColors.primary;
    return Container(
      width: 168,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: accent,
                height: 1.05,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------- filters -------------------------------

class _Filters extends StatelessWidget {
  final FineSummary all;
  final List<String> hostelOptions;
  final String? regNo;
  final String? hostel;
  final String? officeOrder;
  final String? room;
  final String? status;
  final String? year;
  final ValueChanged<String?> onRegNo;
  final ValueChanged<String?> onHostel;
  final ValueChanged<String?> onOfficeOrder;
  final ValueChanged<String?> onRoom;
  final ValueChanged<String?> onStatus;
  final ValueChanged<String?> onYear;

  const _Filters({
    required this.all,
    required this.hostelOptions,
    required this.regNo,
    required this.hostel,
    required this.officeOrder,
    required this.room,
    required this.status,
    required this.year,
    required this.onRegNo,
    required this.onHostel,
    required this.onOfficeOrder,
    required this.onRoom,
    required this.onStatus,
    required this.onYear,
  });

  @override
  Widget build(BuildContext context) {
    // Newest year first — that's the one most people are filtering for.
    final years = all.valuesOf((f) => f.createdAt?.year.toString())
      ..sort((a, b) => b.compareTo(a));

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _Drop(
            label: 'Student Registration Number',
            value: regNo,
            options: all.valuesOf((f) => f.studentRegNo),
            onChanged: onRegNo,
            width: 236,
          ),
          _Drop(
            label: 'Hostel',
            value: hostel,
            options: hostelOptions,
            onChanged: onHostel,
            width: 150,
          ),
          _Drop(
            label: 'Office Order',
            value: officeOrder,
            options: all.valuesOf((f) => f.officeOrderNo),
            onChanged: onOfficeOrder,
            width: 200,
          ),
          _Drop(
            label: 'Hostel Room No.',
            value: room,
            options: all.valuesOf((f) => f.roomNumber),
            onChanged: onRoom,
            width: 160,
          ),
          _Drop(
            label: 'Status',
            value: status,
            options: FineStatus.values.map((s) => s.name).toList(),
            labelFor: (v) => FineStatusX.parse(v).label,
            onChanged: onStatus,
            width: 150,
          ),
          _Drop(
            label: 'Year',
            value: year,
            options: years,
            onChanged: onYear,
            width: 110,
          ),
        ],
      ),
    );
  }
}

class _Drop extends StatelessWidget {
  final String label;
  final String? value;
  final List<String> options;
  final String Function(String)? labelFor;
  final ValueChanged<String?> onChanged;
  final double width;

  const _Drop({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.labelFor,
    this.width = 200,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DropdownButtonFormField<String>(
      initialValue: options.contains(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      hint: const Text('All'),
      items: [
        const DropdownMenuItem<String>(value: null, child: Text('All')),
        ...options.map(
          (o) => DropdownMenuItem(
            value: o,
            child: Text(
              labelFor == null ? o : labelFor!(o),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: onChanged,
    ),
  );
}

// ------------------------------- charts -------------------------------

class _Charts extends StatelessWidget {
  final FineSummary summary;
  final String Function(String?) hostelLabel;
  final void Function(String dimension, String value) onFilter;

  const _Charts({
    required this.summary,
    required this.hostelLabel,
    required this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    final bySem = summary.countBy((f) => f.sem?.toString(), unknownLabel: '—')
      ..sort(
        (a, b) =>
            (int.tryParse(a.key) ?? 999).compareTo(int.tryParse(b.key) ?? 999),
      );
    final byBatch = summary.countBy((f) => f.batch, unknownLabel: '—')
      ..sort((a, b) => a.key.compareTo(b.key));

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        _Panel(
          title: 'Sum of Amount of Fine by Hostel Number',
          child: _VBars(
            // Grouped by CODE, not the full name: ten "… House" labels on one
            // axis are unreadable, and BH-01 is what people say out loud.
            data: summary.sumBy((f) => hostelLabel(f.hostelName)),
            money: true,
            axisTitle: 'Hostel Number',
            onTap: (v) => onFilter('hostel', v),
          ),
        ),
        _Panel(
          title: 'Count of Amount of Fine by Batch',
          child: _HBars(
            data: byBatch,
            money: false,
            axisTitle: 'Batch',
            onTap: (v) => onFilter('batch', v),
          ),
        ),
        _Panel(
          title: 'Count of Amount of Fine by Sem',
          child: _VBars(
            data: bySem,
            money: false,
            axisTitle: 'Sem',
            onTap: (v) => onFilter('sem', v),
          ),
        ),
        _Panel(
          title: 'Count of Amount of Fine by Student Name',
          child: _VBars(
            data: summary.countBy((f) => f.studentName, limit: 12),
            money: false,
            axisTitle: 'Student Name',
            rotate: true,
          ),
        ),
        _Panel(
          title: 'Sum of Amount of Fine by Student Name',
          child: _VBars(
            data: summary.sumBy((f) => f.studentName, limit: 12),
            money: true,
            axisTitle: 'Student Name',
            rotate: true,
          ),
        ),
        _Panel(
          title: 'Sum of Amount of Fine by Trade',
          child: _HBars(
            data: summary.sumBy(
              (f) => f.trade,
              unknownLabel: 'None',
              limit: 12,
            ),
            money: true,
            axisTitle: 'Trade',
            onTap: (v) => onFilter('trade', v),
          ),
        ),
        // Distinct students, not fine count: one student with three fines is
        // one defaulter. Counting fines would let a single repeat offender
        // outrank a state with five separate students.
        _Panel(
          // The title carries the unit, so the bars just show the number —
          // "11 students" on every row is noise that costs 60px of width.
          title: 'Top States by Defaulters (students)',
          child: _HBars(
            data: summary.defaultersBy((f) => f.state, limit: 12),
            money: false,
            axisTitle: 'State',
            labelWidth: 92,
            onTap: (v) => onFilter('state', v),
          ),
        ),
        _Panel(
          title: 'Sum of Amount of Fine by State',
          child: _HBars(
            data: summary.sumBy((f) => f.state, limit: 12),
            money: true,
            axisTitle: 'State',
            labelWidth: 92,
            onTap: (v) => onFilter('state', v),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;
  const _Panel({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => SizedBox(
    // Fixed size on purpose: these sit in a Wrap, which hands children
    // unbounded height, and a chart measured against infinity fails to lay
    // out and silently blanks the whole row.
    width: 428,
    height: 296,
    child: AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

/// Column chart with the value printed above every bar and a labelled y-axis —
/// the two things that make the reference report readable at a glance.
class _VBars extends StatelessWidget {
  final List<MapEntry<String, num>> data;
  final bool money;
  final String axisTitle;
  final bool rotate;
  final ValueChanged<String>? onTap;

  const _VBars({
    required this.data,
    required this.money,
    required this.axisTitle,
    this.rotate = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const _NoData();

    final shown = data.length > 12 ? data.sublist(0, 12) : data;
    final max = shown.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    final top = max <= 0 ? 1.0 : max * 1.32;

    return Column(
      children: [
        Expanded(
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: top,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: top / 4,
                getDrawingHorizontalLine: (_) =>
                    FlLine(color: AppColors.border, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              // Labels are drawn as always-on tooltips. Touch stays enabled so
              // a tap can filter, but the tooltip is styled away to nothing so
              // it reads as a plain number sitting above the bar.
              barTouchData: BarTouchData(
                enabled: true,
                handleBuiltInTouches: false,
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => Colors.transparent,
                  tooltipPadding: EdgeInsets.zero,
                  tooltipMargin: 2,
                  getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                    money ? compactAmount(rod.toY) : rod.toY.toStringAsFixed(0),
                    TextStyle(
                      color: AppColors.textStrong,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                touchCallback: (event, response) {
                  if (onTap == null || !event.isInterestedForInteractions) {
                    return;
                  }
                  final i = response?.spot?.touchedBarGroupIndex;
                  if (i != null && i >= 0 && i < shown.length) {
                    onTap!(shown[i].key);
                  }
                },
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: top / 4,
                    getTitlesWidget: (v, meta) => Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: Text(
                        money ? compactAmount(v) : v.toStringAsFixed(0),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: rotate ? 68 : 24,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= shown.length) {
                        return const SizedBox.shrink();
                      }
                      final label = shown[i].key;
                      if (!rotate) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: SizedBox(
                          height: 64,
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: AppColors.textMuted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < shown.length; i++)
                  BarChartGroupData(
                    x: i,
                    showingTooltipIndicators: const [0],
                    barRods: [
                      BarChartRodData(
                        toY: shown[i].value.toDouble(),
                        color: AppColors.primary,
                        width: shown.length > 8 ? 12 : 22,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(3),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          axisTitle,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textMuted,
          ),
        ),
      ],
    );
  }
}

/// Horizontal bars with a category axis down the left and the value printed at
/// the end of each bar. Hand-built rather than a rotated chart, because a
/// rotated chart rotates its labels too.
class _HBars extends StatelessWidget {
  final List<MapEntry<String, num>> data;
  final bool money;
  final String axisTitle;

  /// Width reserved for the category names on the left. Trade codes are short;
  /// state names are not, so the state charts pass a wider value rather than
  /// rendering "Uttar Prade…".
  final double labelWidth;

  final ValueChanged<String>? onTap;

  const _HBars({
    required this.data,
    required this.money,
    required this.axisTitle,
    this.labelWidth = 62,
    this.onTap,
  });

  /// Space kept for the number printed at the end of each bar.
  ///
  /// This has to be reserved OUTSIDE the bar's Expanded. Letting the bar size
  /// itself against the full width and then appending the value after it is
  /// what pushed the longest row past the panel edge — the bar took 87% and
  /// the text needed more than the 13% left over.
  static const double _valueWidth = 46;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const _NoData();

    final max = data.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    final top = max <= 0 ? 1.0 : max * 1.02;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RotatedBox(
          quarterTurns: 3,
          child: Text(
            axisTitle,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(top: 2),
            itemCount: data.length,
            separatorBuilder: (_, _) => const SizedBox(height: 7),
            itemBuilder: (context, i) {
              final e = data[i];
              return InkWell(
                onTap: onTap == null ? null : () => onTap!(e.key),
                borderRadius: BorderRadius.circular(4),
                child: Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Tooltip(
                        message: e.key,
                        child: Text(
                          e.key,
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    // The bar gets whatever is left after the value column is
                    // reserved, so the longest row lands exactly on the edge
                    // instead of past it.
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final w = box.maxWidth * (e.value / top);
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              height: 15,
                              width: w.isFinite && w > 0
                                  ? w.clamp(2.0, box.maxWidth)
                                  : 2,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.horizontal(
                                  right: Radius.circular(3),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: _valueWidth,
                      child: Text(
                        money
                            ? compactAmount(e.value)
                            : e.value.toStringAsFixed(0),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textStrong,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'Nothing matches these filters.',
      style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
    ),
  );
}

// ----------------------------- slicer rail -----------------------------

class _SlicerRail extends StatelessWidget {
  final FineSummary all;
  final List<String> hostelOptions;
  final List<String> tradeOptions;
  final String? sem;
  final String? trade;
  final String? batch;
  final String? hostel;
  final String? state;
  final ValueChanged<String> onSem;
  final ValueChanged<String> onTrade;
  final ValueChanged<String> onBatch;
  final ValueChanged<String> onHostel;
  final ValueChanged<String> onState;

  const _SlicerRail({
    required this.all,
    required this.hostelOptions,
    required this.tradeOptions,
    required this.sem,
    required this.trade,
    required this.batch,
    required this.hostel,
    required this.state,
    required this.onSem,
    required this.onTrade,
    required this.onBatch,
    required this.onHostel,
    required this.onState,
  });

  @override
  Widget build(BuildContext context) {
    // Options always come from the UNFILTERED set. Building them from filtered
    // data would make a slicer erase its own options the moment you used one,
    // leaving no way back.
    final sems = all.valuesOf((f) => f.sem?.toString())
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SlicerBox(
          title: 'Sem',
          options: sems,
          selected: sem,
          onTap: onSem,
          columns: 3,
        ),
        const SizedBox(height: 14),
        _SlicerBox(
          title: 'Trade',
          options: tradeOptions,
          selected: trade,
          onTap: onTrade,
          columns: 2,
          maxHeight: 180,
        ),
        const SizedBox(height: 14),
        _SlicerBox(
          title: 'Batch',
          options: all.valuesOf((f) => f.batch),
          selected: batch,
          onTap: onBatch,
          columns: 2,
        ),
        const SizedBox(height: 14),
        _SlicerBox(
          title: 'Hostel Number',
          options: hostelOptions,
          selected: hostel,
          onTap: onHostel,
          columns: 2,
          maxHeight: 160,
        ),
        const SizedBox(height: 14),
        _SlicerBox(
          title: 'Home State',
          options: all.valuesOf((f) => f.state),
          selected: state,
          onTap: onState,
          columns: 1,
          maxHeight: 200,
        ),
      ],
    );
  }
}

class _SlicerBox extends StatelessWidget {
  final String title;
  final List<String> options;
  final String? selected;
  final ValueChanged<String> onTap;
  final int columns;
  final double? maxHeight;

  const _SlicerBox({
    required this.title,
    required this.options,
    required this.selected,
    required this.onTap,
    required this.columns,
    this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    final grid = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final o in options)
          _Tile(
            label: o,
            selected: selected == o,
            onTap: () => onTap(o),
            // -6 per gap, divided by column count, inside 232-32 of padding.
            width: columns == 1
                ? double.infinity
                : (200 - (columns - 1) * 6) / columns,
          ),
      ],
    );

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (maxHeight == null)
            grid
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight!),
              child: SingleChildScrollView(child: grid),
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  const _Tile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.width,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width == double.infinity ? null : width,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width == double.infinity ? double.infinity : null,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.canvas,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.textStrong,
          ),
        ),
      ),
    ),
  );
}

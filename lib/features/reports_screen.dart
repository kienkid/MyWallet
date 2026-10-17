import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../app/providers.dart';
import '../app/strings.dart';
import '../app/widgets.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/util.dart';
import 'transactions_screens.dart';

/// Reports read income/expense only – transfers and loans never appear here.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final f = ref.watch(reportFilterProvider);
    final data = ref.watch(reportDataProvider);
    final cats = ref.watch(allCategoriesProvider).value ?? const <Category>[];
    final parentsWithChildren = {for (final c in cats) if (c.parentId != null) c.parentId!};
    return Scaffold(
      appBar: AppBar(title: Text(s['tabReports'])),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        _Filters(filter: f),
        data.when(
          loading: () => const Padding(padding: EdgeInsets.all(48), child: Loading()),
          error: (e, st) => const ErrorView(),
          data: (d) {
            if (d.isEmpty) {
              return EmptyState(
                icon: Icons.pie_chart_outline,
                message: s['emptyReport'],
                action: s['addTransaction'],
                onAction: () => openAdd(context, s),
              );
            }
            final net = d.income - d.expense;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    _kv(context, s['income'], formatMoney(d.income, f.currencyCode, s.lang),
                        amountColor(context, TxType.income)),
                    _kv(context, s['expense'], formatMoney(d.expense, f.currencyCode, s.lang),
                        amountColor(context, TxType.expense)),
                    const Divider(),
                    _kv(context, s['netCashFlow'], formatMoney(net, f.currencyCode, s.lang, signed: true),
                        amountColor(context, net >= 0 ? TxType.income : TxType.expense)),
                    if (d.income > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(s['spentOfIncome'].replaceAll(
                            '{p}', formatPercent(d.expense * 10000 ~/ d.income))),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(s['reportExcludes'], style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ]),
                ),
              ),
              SectionHeader(s['expenseByCategory']),
              _PieSection(
                  slices: d.expenseSlices, s: s, currency: f.currencyCode,
                  type: TxType.expense, drillable: parentsWithChildren),
              SectionHeader(s['incomeByCategory']),
              _PieSection(
                  slices: d.incomeSlices, s: s, currency: f.currencyCode,
                  type: TxType.income, drillable: parentsWithChildren),
              SectionHeader(s['monthlyIncomeExpense']),
              _MonthlyBars(months: d.monthly, s: s),
              SectionHeader(s['byWallet']),
              for (final w in d.wallets)
                ListTile(
                  title: Text(w.walletName),
                  subtitle: Text('${s['income']}: ${formatMoney(w.income, f.currencyCode, s.lang)}'),
                  trailing: Text(formatMoney(-w.expense, f.currencyCode, s.lang),
                      style: TextStyle(
                          color: amountColor(context, TxType.expense), fontWeight: FontWeight.w600)),
                ),
            ]);
          },
        ),
      ]),
    );
  }

  Widget _kv(BuildContext c, String k, String v, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _Filters extends ConsumerWidget {
  const _Filters({required this.filter});
  final ReportFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final n = ref.read(reportFilterProvider.notifier);
    final wallets = ref.watch(allWalletsProvider).value ?? const [];
    final cats = orderTree(ref.watch(allCategoriesProvider).value ?? const <Category>[]);
    final now = DateTime.now();
    final thisMonth = startOfMonth(now);
    final df = DateFormat.yMd(s.lang);
    bool isRange(DateTime a, DateTime b) => filter.from == a && filter.to == b;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          ChoiceChip(
            label: Text(s['thisMonth']),
            selected: isRange(thisMonth, addMonths(thisMonth, 1)),
            onSelected: (_) => n.set(filter.copyWith(from: thisMonth, to: addMonths(thisMonth, 1))),
          ),
          ChoiceChip(
            label: Text(s['lastMonth']),
            selected: isRange(addMonths(thisMonth, -1), thisMonth),
            onSelected: (_) => n.set(filter.copyWith(from: addMonths(thisMonth, -1), to: thisMonth)),
          ),
          ChoiceChip(
            label: Text(s['thisYear']),
            selected: isRange(DateTime(now.year), DateTime(now.year + 1)),
            onSelected: (_) => n.set(filter.copyWith(from: DateTime(now.year), to: DateTime(now.year + 1))),
          ),
          ActionChip(
            avatar: const Icon(Icons.date_range, size: 18),
            label: Text('${df.format(filter.from)} – ${df.format(filter.to.subtract(const Duration(days: 1)))}'),
            onPressed: () async {
              final r = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                locale: Locale(s.lang),
              );
              if (r != null) {
                n.set(filter.copyWith(
                    from: startOfDay(r.start), to: startOfDay(r.end).add(const Duration(days: 1))));
              }
            },
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              key: ValueKey('rw${filter.walletId}'),
              initialValue: filter.walletId,
              isExpanded: true,
              decoration: InputDecoration(labelText: s['wallet'], isDense: true),
              items: [
                DropdownMenuItem(value: null, child: Text(s['allWallets'])),
                for (final w in wallets)
                  DropdownMenuItem(value: w.wallet.id, child: Text(w.wallet.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => n.set(filter.copyWith(walletId: v)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String?>(
              key: ValueKey('rc${filter.categoryId}'),
              initialValue: filter.categoryId,
              isExpanded: true,
              decoration: InputDecoration(labelText: s['category'], isDense: true),
              items: [
                DropdownMenuItem(value: null, child: Text(s['allCategories'])),
                for (final c in cats)
                  DropdownMenuItem(
                      value: c.id,
                      child: Text(
                          c.parentId == null
                              ? '${s.categoryName(c)} (${c.type == TxType.income ? '+' : '−'})'
                              : '   › ${s.categoryName(c)}',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => n.set(filter.copyWith(categoryId: v)),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _PieSection extends StatelessWidget {
  const _PieSection({
    required this.slices,
    required this.s,
    required this.currency,
    required this.type,
    required this.drillable,
  });
  final List<CategorySlice> slices;
  final S s;
  final String currency;
  final TxType type;
  final Set<String> drillable; // parents that have sub-categories

  @override
  Widget build(BuildContext context) {
    if (slices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(s['noDataForPeriod'], textAlign: TextAlign.center),
      );
    }
    final bp = basisPoints(slices.map((e) => e.total).toList());
    // Chart groups slices < 3% into "Other" for readability; legend lists all.
    final sections = <PieChartSectionData>[];
    var otherBp = 0;
    var otherValue = 0;
    for (var i = 0; i < slices.length; i++) {
      if (bp[i] < 300 && slices.length > 6) {
        otherBp += bp[i];
        otherValue += slices[i].total;
        continue;
      }
      sections.add(PieChartSectionData(
        value: slices[i].total.toDouble(),
        color: Color(slices[i].category.colorValue),
        title: bp[i] >= 800 ? formatPercent(bp[i]) : '',
        radius: 60,
        titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
      ));
    }
    if (otherValue > 0) {
      sections.add(PieChartSectionData(
        value: otherValue.toDouble(),
        color: Colors.grey,
        title: otherBp >= 800 ? formatPercent(otherBp) : '',
        radius: 60,
      ));
    }
    return Column(children: [
      Semantics(
        label: slices
            .asMap()
            .entries
            .map((e) => '${s.categoryName(e.value.category)} ${formatPercent(bp[e.key])}')
            .join(', '),
        child: SizedBox(
          height: 200,
          child: PieChart(PieChartData(sections: sections, centerSpaceRadius: 40, sectionsSpace: 2)),
        ),
      ),
      for (var i = 0; i < slices.length; i++)
        _legendTile(context, slices[i], bp[i], drillable.contains(slices[i].category.id)),
    ]);
  }

  Widget _legendTile(BuildContext context, CategorySlice sl, int bp, bool canDrill) {
    return ListTile(
      dense: true,
      leading: ColoredIcon.fromKey(iconKey: sl.category.iconKey, color: sl.category.colorValue, size: 32),
      title: Text(s.categoryName(sl.category)),
      subtitle: Text(canDrill
          ? '${sl.count} ${s['transactionsCount']} · ${s['tapForDetails']}'
          : '${sl.count} ${s['transactionsCount']}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(formatMoney(sl.total, currency, s.lang), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(formatPercent(bp)),
          ],
        ),
        if (canDrill) const Icon(Icons.chevron_right),
      ]),
      onTap: !canDrill
          ? null
          : () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (c) => SafeArea(
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ListTile(
                        leading: ColoredIcon.fromKey(
                            iconKey: sl.category.iconKey, color: sl.category.colorValue, size: 36),
                        title: Text(s.categoryName(sl.category),
                            style: Theme.of(c).textTheme.titleMedium),
                        trailing: Text(formatMoney(sl.total, currency, s.lang),
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      const Divider(height: 1),
                      _Breakdown(parent: sl.category, type: type, currency: currency),
                      const SizedBox(height: 16),
                    ]),
                  ),
                ),
              ),
    );
  }
}

/// Sub-category breakdown of one parent (drill-down).
class _Breakdown extends ConsumerWidget {
  const _Breakdown({required this.parent, required this.type, required this.currency});
  final Category parent;
  final TxType type;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final data = ref.watch(categoryBreakdownProvider((parent.id, type)));
    return data.when(
      loading: () => const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
      error: (e, st) => Padding(padding: const EdgeInsets.all(12), child: Text(s['err_load'])),
      data: (list) {
        final bp = basisPoints(list.map((e) => e.total).toList());
        return Column(children: [
          for (var i = 0; i < list.length; i++)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: ColoredIcon.fromKey(
                  iconKey: list[i].category.iconKey, color: list[i].category.colorValue, size: 26),
              title: Text(list[i].category.id == parent.id
                  ? '${s.categoryName(parent)} (${s['general']})'
                  : s.categoryName(list[i].category)),
              trailing: Text('${formatMoney(list[i].total, currency, s.lang)} · ${formatPercent(bp[i])}'),
            ),
        ]);
      },
    );
  }
}

class _MonthlyBars extends StatelessWidget {
  const _MonthlyBars({required this.months, required this.s});
  final List<MonthlyTotal> months;
  final S s;

  @override
  Widget build(BuildContext context) {
    final hasData = months.any((m) => m.income > 0 || m.expense > 0);
    if (!hasData) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(s['noDataForPeriod'], textAlign: TextAlign.center),
      );
    }
    final inc = amountColor(context, TxType.income);
    final exp = amountColor(context, TxType.expense);
    final mf = DateFormat.MMM(s.lang);
    return Column(children: [
      SizedBox(
        height: 220,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: BarChart(BarChartData(
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            barTouchData: const BarTouchData(enabled: false),
            titlesData: FlTitlesData(
              leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 28,
                  getTitlesWidget: (value, meta) {
                    final i = value.toInt();
                    if (i < 0 || i >= months.length) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(mf.format(months[i].monthStart), style: const TextStyle(fontSize: 11)),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < months.length; i++)
                BarChartGroupData(x: i, barsSpace: 4, barRods: [
                  BarChartRodData(toY: months[i].income.toDouble(), color: inc, width: 10),
                  BarChartRodData(toY: months[i].expense.toDouble(), color: exp, width: 10),
                ]),
            ],
          )),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.square, color: inc, size: 14),
          Text(' ${s['income']}    '),
          Icon(Icons.square, color: exp, size: 14),
          Text(' ${s['expense']}'),
        ]),
      ),
      for (final m in months.reversed)
        if (m.income > 0 || m.expense > 0)
          ListTile(
            dense: true,
            title: Text(DateFormat.yMMMM(s.lang).format(m.monthStart)),
            trailing: Text(
              '+${formatMoney(m.income, defaultCurrency, s.lang)} / −${formatMoney(m.expense, defaultCurrency, s.lang)}',
            ),
          ),
    ]);
  }
}

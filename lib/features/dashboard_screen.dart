import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/widgets.dart';
import '../core/models.dart';
import '../core/money.dart';
import 'debt_screens.dart';
import 'transactions_screens.dart';
import 'wallet_screens.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final data = ref.watch(dashboardProvider);
    final debts = ref.watch(debtsProvider).value;
    return Scaffold(
      appBar: AppBar(title: Text(s['appName'])),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openAdd(context, s),
        icon: const Icon(Icons.add),
        label: Text(s['addTransaction']),
      ),
      body: data.when(
        loading: () => const Loading(),
        error: (e, st) => const ErrorView(),
        data: (d) {
          if (d.wallets.isEmpty && d.recent.isEmpty) {
            return EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              message: s['emptyNoWallet'],
              action: s['addWallet'],
              onAction: () => openWalletForm(context),
            );
          }
          final net = d.monthIncome - d.monthExpense;
          final theme = Theme.of(context);
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s['totalBalance'], style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Text(formatMoney(d.combined, defaultCurrency, s.lang),
                      style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                  if (d.excludedOtherCurrency)
                    Text(s['otherCurrencyExcluded'], style: theme.textTheme.bodySmall),
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s['thisMonth'], style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _Row(s['income'], formatMoney(d.monthIncome, defaultCurrency, s.lang),
                      amountColor(context, TxType.income)),
                  _Row(s['expense'], formatMoney(d.monthExpense, defaultCurrency, s.lang),
                      amountColor(context, TxType.expense)),
                  const Divider(),
                  _Row(s['netCashFlow'], formatMoney(net, defaultCurrency, s.lang, signed: true),
                      net >= 0 ? amountColor(context, TxType.income) : amountColor(context, TxType.expense),
                      bold: true),
                ]),
              ),
            ),
            if (debts != null && (debts.owedToMe > 0 || debts.iOwe > 0))
              DebtSummaryCard(
                owedToMe: debts.owedToMe,
                iOwe: debts.iOwe,
                onTap: () => ref.read(tabIndexProvider.notifier).set(2),
              ),
            SectionHeader(s['wallets'],
                trailing: TextButton(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const WalletsScreen())),
                  child: Text(s['manage']),
                )),
            for (final w in d.wallets)
              ListTile(
                leading: ColoredIcon.fromKey(iconKey: w.wallet.iconKey, color: w.wallet.colorValue),
                title: Text(w.wallet.name),
                trailing: Text(formatMoney(w.balance, w.wallet.currencyCode, s.lang),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                onTap: () => openWalletForm(context, existing: w),
              ),
            SectionHeader(s['recentTransactions']),
            if (d.recent.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(s['emptyTransactions'], textAlign: TextAlign.center),
              ),
            for (final v in d.recent) TxTile(view: v, onTap: () => openEditor(context, v.tx)),
          ]);
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, this.color, {this.bold = false});
  final String label, value;
  final Color color;
  final bool bold;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text(value,
              style: TextStyle(color: color, fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
        ]),
      );
}

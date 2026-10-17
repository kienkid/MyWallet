import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../core/models.dart';
import '../core/money.dart';
import '../core/util.dart';
import '../data/backup_service.dart';
import '../data/debt_repository.dart';
import '../data/file_gateway.dart';
import '../data/repositories.dart';
import 'strings.dart';

// ---- Infrastructure (overridden in main.dart / tests) ----
final databaseProvider = Provider<Database>((ref) => throw UnimplementedError());
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError());

final walletRepoProvider = Provider((ref) => WalletRepository(ref.watch(databaseProvider)));
final categoryRepoProvider = Provider((ref) => CategoryRepository(ref.watch(databaseProvider)));
final txRepoProvider = Provider((ref) => TransactionRepository(ref.watch(databaseProvider)));
final reportRepoProvider = Provider((ref) => ReportRepository(ref.watch(databaseProvider)));
final peopleRepoProvider = Provider((ref) => PeopleRepository(ref.watch(databaseProvider)));
final debtRepoProvider = Provider((ref) => DebtRepository(ref.watch(databaseProvider)));
final exportServiceProvider = Provider((ref) => ExportService(ref.watch(databaseProvider)));
final importServiceProvider = Provider((ref) => ImportService(ref.watch(databaseProvider)));
final fileGatewayProvider = Provider((ref) => FileGateway());

/// Bumped after every successful write; all read providers watch it, so
/// balances, lists, debts and reports refresh automatically.
class DataVersion extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final dataVersionProvider = NotifierProvider<DataVersion, int>(DataVersion.new);

/// Selected bottom-navigation tab (0 Home, 1 Transactions, 2 Debts, 3 Reports, 4 Settings).
class TabIndex extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final tabIndexProvider = NotifierProvider<TabIndex, int>(TabIndex.new);

// ---- Settings ----
class AppSettings {
  const AppSettings(this.lang, this.themeMode);
  final String lang; // 'en' | 'vi'
  final ThemeMode themeMode;
}

class SettingsNotifier extends Notifier<AppSettings> {
  static const _kLang = 'lang';
  static const _kTheme = 'theme';

  @override
  AppSettings build() {
    final p = ref.watch(prefsProvider);
    final lang = p.getString(_kLang) ?? 'vi';
    final theme = ThemeMode.values.firstWhere(
      (m) => m.name == p.getString(_kTheme),
      orElse: () => ThemeMode.system,
    );
    return AppSettings(lang, theme);
  }

  Future<void> setLang(String lang) async {
    await ref.read(prefsProvider).setString(_kLang, lang);
    state = AppSettings(lang, state.themeMode);
  }

  Future<void> setTheme(ThemeMode m) async {
    await ref.read(prefsProvider).setString(_kTheme, m.name);
    state = AppSettings(state.lang, m);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
final stringsProvider = Provider<S>((ref) => S(ref.watch(settingsProvider).lang));

// ---- Wallets, categories, people ----
final activeWalletsProvider = FutureProvider<List<WalletWithBalance>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(walletRepoProvider).list();
});

final allWalletsProvider = FutureProvider<List<WalletWithBalance>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(walletRepoProvider).list(includeArchived: true);
});

final activeCategoriesProvider = FutureProvider.family<List<Category>, TxType>((ref, type) {
  ref.watch(dataVersionProvider);
  return ref.watch(categoryRepoProvider).list(type: type);
});

final allCategoriesProvider = FutureProvider<List<Category>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(categoryRepoProvider).list(includeArchived: true);
});

final peopleProvider = FutureProvider<List<Person>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(peopleRepoProvider).list(includeArchived: true);
});

/// Orders categories as: parent, its children, next parent, ...
/// Children whose parent is not in [list] are appended at the end.
List<Category> orderTree(List<Category> list) {
  final parents = list.where((c) => c.parentId == null).toList();
  final out = <Category>[];
  for (final p in parents) {
    out.add(p);
    out.addAll(list.where((c) => c.parentId == p.id));
  }
  out.addAll(list.where((c) => !out.contains(c)));
  return out;
}

// ---- Transactions ----
class TxFilterNotifier extends Notifier<TxFilter> {
  @override
  TxFilter build() => const TxFilter();
  void set(TxFilter f) => state = f;
  void setQuery(String q) => state = state.copyWith(query: q);
}

final txFilterProvider = NotifierProvider<TxFilterNotifier, TxFilter>(TxFilterNotifier.new);

final transactionsProvider = FutureProvider<List<TxView>>((ref) async {
  ref.watch(dataVersionProvider);
  final f = ref.watch(txFilterProvider);
  final s = ref.watch(stringsProvider);
  final list = await ref.watch(txRepoProvider).query(f);
  final q = normalizeText(f.query.trim());
  if (q.isEmpty) return list;
  final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
  bool has(String? v) => v != null && normalizeText(v).contains(q);
  return list.where((v) {
    if (has(v.tx.note) || has(v.walletName) || has(v.toWalletName) || has(v.personName)) {
      return true;
    }
    if (has(s.txTitle(v))) return true;
    if (v.parentName != null && has(s.keyedName(v.parentName!, v.parentNameKey))) return true;
    return digits.isNotEmpty && digits == q && v.tx.amount.toString().contains(digits);
  }).toList();
});

// ---- Debts ----
class DebtsData {
  const DebtsData(this.people, this.loans);
  final List<PersonDebt> people;
  final List<Loan> loans;
  int get owedToMe => people.fold(0, (a, p) => a + p.owedToMe);
  int get iOwe => people.fold(0, (a, p) => a + p.iOwe);
}

final debtsProvider = FutureProvider<DebtsData>((ref) async {
  ref.watch(dataVersionProvider);
  final people = await ref.watch(peopleRepoProvider).list(includeArchived: true);
  final loans = await ref.watch(debtRepoProvider).listLoans();
  final out = <PersonDebt>[];
  for (final p in people) {
    final mine = loans.where((l) => l.tx.personId == p.id).toList();
    var owed = 0;
    var owe = 0;
    for (final l in mine) {
      if (l.tx.type == TxType.lend) {
        owed += l.remaining;
      } else {
        owe += l.remaining;
      }
    }
    out.add(PersonDebt(p, owed, owe, mine));
  }
  // Largest outstanding first.
  out.sort((a, b) => (b.owedToMe + b.iOwe).compareTo(a.owedToMe + a.iOwe));
  return DebtsData(out, loans);
});

// ---- Dashboard ----
class DashboardData {
  const DashboardData({
    required this.combined,
    required this.excludedOtherCurrency,
    required this.monthIncome,
    required this.monthExpense,
    required this.wallets,
    required this.recent,
  });
  final int combined;
  final bool excludedOtherCurrency;
  final int monthIncome, monthExpense;
  final List<WalletWithBalance> wallets;
  final List<TxView> recent;
}

final dashboardProvider = FutureProvider<DashboardData>((ref) async {
  ref.watch(dataVersionProvider);
  final wallets = await ref.watch(walletRepoProvider).list();
  final now = DateTime.now();
  final month = await ref.watch(reportRepoProvider).totals(
        ReportFilter(from: startOfMonth(now), to: addMonths(startOfMonth(now), 1)),
      );
  final recent = await ref.watch(txRepoProvider).query(const TxFilter(), limit: 5);
  var combined = 0;
  var excluded = false;
  for (final w in wallets) {
    if (w.wallet.currencyCode == defaultCurrency) {
      combined += w.balance;
    } else {
      excluded = true;
    }
  }
  return DashboardData(
    combined: combined,
    excludedOtherCurrency: excluded,
    monthIncome: month.income,
    monthExpense: month.expense,
    wallets: wallets,
    recent: recent,
  );
});

// ---- Reports ----
class ReportFilterNotifier extends Notifier<ReportFilter> {
  @override
  ReportFilter build() {
    final m = startOfMonth(DateTime.now());
    return ReportFilter(from: m, to: addMonths(m, 1));
  }

  void set(ReportFilter f) => state = f;
}

final reportFilterProvider =
    NotifierProvider<ReportFilterNotifier, ReportFilter>(ReportFilterNotifier.new);

class ReportData {
  const ReportData(this.income, this.expense, this.expenseSlices, this.incomeSlices,
      this.monthly, this.wallets);
  final int income, expense;
  final List<CategorySlice> expenseSlices, incomeSlices;
  final List<MonthlyTotal> monthly;
  final List<WalletSpending> wallets;
  bool get isEmpty => income == 0 && expense == 0;
}

final reportDataProvider = FutureProvider<ReportData>((ref) async {
  ref.watch(dataVersionProvider);
  final f = ref.watch(reportFilterProvider);
  final repo = ref.watch(reportRepoProvider);
  final t = await repo.totals(f);
  // Monthly chart: always show up to 6 months ending at the range end.
  final chartFrom = addMonths(startOfMonth(f.to.subtract(const Duration(milliseconds: 1))), -5);
  final monthly = await repo.monthly(
      f.copyWith(from: chartFrom.isBefore(f.from) ? chartFrom : f.from));
  return ReportData(
    t.income,
    t.expense,
    await repo.byCategory(f, TxType.expense),
    await repo.byCategory(f, TxType.income),
    monthly,
    await repo.byWallet(f),
  );
});

/// Drill-down: a parent category split into itself + its sub-categories.
final categoryBreakdownProvider =
    FutureProvider.family<List<CategorySlice>, (String, TxType)>((ref, key) {
  ref.watch(dataVersionProvider);
  final f = ref.watch(reportFilterProvider);
  return ref.watch(reportRepoProvider).byCategory(f, key.$2, parentId: key.$1);
});

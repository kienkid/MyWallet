import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../app/providers.dart';
import '../app/strings.dart';
import '../app/widgets.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/util.dart';
import 'debt_screens.dart';
import 'transfer_screen.dart';
import 'wallet_screens.dart';

/// Shows the "what do you want to add?" sheet and opens the matching form.
Future<void> openAdd(BuildContext context, S s, {bool debtOnly = false, String? personId}) async {
  final type = await chooseAddType(context, s, debtOnly: debtOnly);
  if (type == null || !context.mounted) return;
  final Widget page = switch (type) {
    TxType.transfer => const TransferFormScreen(),
    TxType.lend || TxType.borrow => LoanFormScreen(initialType: type, personId: personId),
    _ => TransactionFormScreen(initialType: type),
  };
  await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

/// Opens the right editor for any row in the transaction list.
Future<void> openEditor(BuildContext context, Tx tx) {
  final Widget page = switch (tx.type) {
    TxType.income || TxType.expense => TransactionFormScreen(existing: tx),
    TxType.transfer => TransferFormScreen(existing: tx),
    TxType.lend || TxType.borrow => LoanFormScreen(existing: tx),
    _ => PaymentFormScreen(loanId: tx.loanId!, existing: tx),
  };
  return Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

// ============================== LIST =======================================
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});
  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final filter = ref.watch(txFilterProvider);
    final txs = ref.watch(transactionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s['tabTransactions']),
        actions: [
          IconButton(
            tooltip: s['filter'],
            icon: Badge(
              isLabelVisible: filter.hasStructuredFilters,
              child: const Icon(Icons.filter_list),
            ),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => const _FilterSheet(),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: s['addTransaction'],
        onPressed: () => openAdd(context, s),
        child: const Icon(Icons.add),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: s['searchHint'],
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: s['clear'],
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        ref.read(txFilterProvider.notifier).setQuery('');
                        setState(() {});
                      },
                    ),
            ),
            onChanged: (v) {
              ref.read(txFilterProvider.notifier).setQuery(v);
              setState(() {});
            },
          ),
        ),
        Expanded(
          child: txs.when(
            loading: () => const Loading(),
            error: (e, st) => const ErrorView(),
            data: (list) {
              if (list.isEmpty) {
                final filtered = filter.hasStructuredFilters || filter.query.isNotEmpty;
                return EmptyState(
                  icon: Icons.receipt_long_outlined,
                  message: filtered ? s['emptyFiltered'] : s['emptyTransactions'],
                  action: filtered ? s['clearFilters'] : s['addTransaction'],
                  onAction: filtered
                      ? () {
                          _search.clear();
                          ref.read(txFilterProvider.notifier).set(const TxFilter());
                        }
                      : () => openAdd(context, s),
                );
              }
              final items = <Widget>[];
              DateTime? day;
              for (final v in list) {
                final d = startOfDay(v.tx.occurredAt);
                if (day != d) {
                  day = d;
                  items.add(SectionHeader(DateFormat.yMMMMEEEEd(s.lang).format(d)));
                }
                items.add(TxTile(view: v, onTap: () => openEditor(context, v.tx)));
              }
              return ListView(padding: const EdgeInsets.only(bottom: 96), children: items);
            },
          ),
        ),
      ]),
    );
  }
}

class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet();
  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late TxFilter _f;

  @override
  void initState() {
    super.initState();
    _f = ref.read(txFilterProvider);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final wallets = ref.watch(allWalletsProvider).value ?? const [];
    final cats = ref.watch(allCategoriesProvider).value ?? const <Category>[];
    final showCategory = _f.group == null || _f.group == TxGroup.income || _f.group == TxGroup.expense;
    final visibleCats = orderTree(cats
        .where((c) =>
            _f.group == null ||
            (_f.group == TxGroup.income && c.type == TxType.income) ||
            (_f.group == TxGroup.expense && c.type == TxType.expense))
        .toList());
    final df = DateFormat.yMd(s.lang);
    final groups = <(TxGroup?, String)>[
      (null, s['all']),
      (TxGroup.expense, s['expense']),
      (TxGroup.income, s['income']),
      (TxGroup.transfer, s['transfer']),
      (TxGroup.debt, s['debt']),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s['filter'], style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final g in groups)
              ChoiceChip(
                label: Text(g.$2),
                selected: _f.group == g.$1,
                onSelected: (_) => setState(() {
                  final keepCat = cats.any((c) =>
                      c.id == _f.categoryId &&
                      (g.$1 == null ||
                          (g.$1 == TxGroup.income && c.type == TxType.income) ||
                          (g.$1 == TxGroup.expense && c.type == TxType.expense)));
                  _f = _f.copyWith(group: g.$1, categoryId: keepCat ? _f.categoryId : null);
                }),
              ),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: ValueKey('w${_f.walletId}'),
            initialValue: _f.walletId,
            isExpanded: true,
            decoration: InputDecoration(labelText: s['wallet']),
            items: [
              DropdownMenuItem(value: null, child: Text(s['allWallets'])),
              for (final w in wallets) DropdownMenuItem(value: w.wallet.id, child: Text(w.wallet.name)),
            ],
            onChanged: (v) => setState(() => _f = _f.copyWith(walletId: v)),
          ),
          if (showCategory) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: ValueKey('c${_f.categoryId}${_f.group}'),
              initialValue: _f.categoryId,
              isExpanded: true,
              decoration: InputDecoration(labelText: s['category'], helperText: s['categoryFilterHint']),
              items: [
                DropdownMenuItem(value: null, child: Text(s['allCategories'])),
                for (final c in visibleCats)
                  DropdownMenuItem(
                    value: c.id,
                    child: Padding(
                      padding: EdgeInsets.only(left: c.parentId == null ? 0 : 20),
                      child: Text(
                        '${c.parentId == null ? '' : '› '}${s.categoryName(c)}'
                        '${_f.group == null && c.parentId == null ? (c.type == TxType.income ? ' (+)' : ' (−)') : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _f = _f.copyWith(categoryId: v)),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.date_range),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            label: Text(_f.from == null
                ? s['allDates']
                : '${df.format(_f.from!)} – ${df.format(_f.to!.subtract(const Duration(days: 1)))}'),
            onPressed: () async {
              final r = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                locale: Locale(s.lang),
              );
              if (r != null) {
                setState(() => _f = _f.copyWith(
                    from: startOfDay(r.start), to: startOfDay(r.end).add(const Duration(days: 1))));
              }
            },
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  ref.read(txFilterProvider.notifier).set(TxFilter(query: _f.query));
                  Navigator.pop(context);
                },
                child: Text(s['reset']),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () {
                  ref.read(txFilterProvider.notifier).set(showCategory ? _f : _f.copyWith(categoryId: null));
                  Navigator.pop(context);
                },
                child: Text(s['apply']),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ======================== INCOME / EXPENSE FORM ============================
class TransactionFormScreen extends ConsumerStatefulWidget {
  const TransactionFormScreen({super.key, this.existing, this.initialType = TxType.expense});
  final Tx? existing;
  final TxType initialType;
  @override
  ConsumerState<TransactionFormScreen> createState() => _TxFormState();
}

class _TxFormState extends ConsumerState<TransactionFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late TxType _type;
  String? _walletId;
  String? _categoryId;
  late DateTime _when;
  bool _saving = false;

  Tx? get _e => widget.existing;

  @override
  void initState() {
    super.initState();
    final lang = ref.read(settingsProvider).lang;
    _amount = TextEditingController(text: _e == null ? '' : formatAmountInput(_e!.amount, lang));
    _note = TextEditingController(text: _e?.note ?? '');
    _type = _e?.type ?? widget.initialType;
    _walletId = _e?.walletId;
    _categoryId = _e?.categoryId;
    _when = _e?.occurredAt ?? DateTime.now();
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(txRepoProvider);
    final amount = parseAmount(_amount.text)!;
    final ok = await runAction(context, ref, () async {
      if (_e == null) {
        await repo.create(
            type: _type, amount: amount, walletId: _walletId!, categoryId: _categoryId!,
            occurredAt: _when, note: _note.text);
      } else {
        await repo.update(_e!.copyWith(
            type: _type, amount: amount, walletId: _walletId, categoryId: _categoryId,
            occurredAt: _when, note: _note.text));
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final s = ref.read(stringsProvider);
    if (!await confirmDialog(context, s, title: s['deleteTransaction'], message: s['deleteTransactionMsg'])) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(context, ref, () => ref.read(txRepoProvider).delete(_e!.id));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final wallets = ref.watch(allWalletsProvider);
    final allCats = ref.watch(allCategoriesProvider).value ?? const <Category>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(_e == null ? s['addTransaction'] : s['editTransaction']),
        actions: [
          if (_e != null)
            IconButton(tooltip: s['delete'], icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: wallets.when(
        loading: () => const Loading(),
        error: (e, st) => const ErrorView(),
        data: (ws) {
          final usable = ws.where((w) => !w.wallet.isArchived || w.wallet.id == _e?.walletId).toList();
          if (usable.isEmpty) {
            return EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              message: s['emptyNoWallet'],
              action: s['addWallet'],
              onAction: () => openWalletForm(context),
            );
          }
          _walletId ??= usable.first.wallet.id;
          // Active categories of this type, plus the current one if archived.
          final catList = allCats
              .where((c) => c.type == _type && (!c.isArchived || c.id == _categoryId))
              .toList();
          final selected = catList.where((c) => c.id == _categoryId).firstOrNull;
          final parent = selected?.parentId == null
              ? null
              : allCats.where((c) => c.id == selected!.parentId).firstOrNull;

          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              SegmentedButton<TxType>(
                segments: [
                  ButtonSegment(value: TxType.expense, label: Text(s['expense']), icon: const Icon(Icons.remove)),
                  ButtonSegment(value: TxType.income, label: Text(s['income']), icon: const Icon(Icons.add)),
                ],
                selected: {_type},
                onSelectionChanged: (v) => setState(() {
                  _type = v.first;
                  _categoryId = null;
                }),
              ),
              const SizedBox(height: 16),
              AmountField(controller: _amount, s: s, autofocus: _e == null),
              const SizedBox(height: 16),
              FormField<String>(
                key: ValueKey('cat$_type$_categoryId'),
                initialValue: _categoryId,
                validator: (_) => _categoryId == null ? s['err_categoryRequired'] : null,
                builder: (field) => InkWell(
                  onTap: () async {
                    final id = await pickCategory(context, s, catList, _categoryId);
                    if (id != null) {
                      setState(() => _categoryId = id);
                      field.didChange(id);
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: s['category'],
                      errorText: field.errorText,
                      suffixIcon: const Icon(Icons.arrow_drop_down),
                    ),
                    isEmpty: selected == null,
                    child: selected == null
                        ? const SizedBox(height: 20)
                        : Row(children: [
                            ColoredIcon.fromKey(iconKey: selected.iconKey, color: selected.colorValue, size: 28),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                parent == null
                                    ? s.categoryName(selected)
                                    : '${s.categoryName(parent)} › ${s.categoryName(selected)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ]),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              WalletDropdown(
                wallets: usable,
                value: _walletId,
                label: s['wallet'],
                onChanged: (v) => setState(() => _walletId = v),
              ),
              const SizedBox(height: 16),
              DateTimeRow(value: _when, s: s, onChanged: (d) => setState(() => _when = d)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: s['noteOptional']),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: Text(s['save']),
              ),
            ]),
          );
        },
      ),
    );
  }
}

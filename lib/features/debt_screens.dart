import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../app/providers.dart';
import '../app/strings.dart';
import '../app/widgets.dart';
import '../core/models.dart';
import '../core/money.dart';
import 'transactions_screens.dart';
import 'wallet_screens.dart';

/// Create or edit a person. Returns the person id, or null if cancelled.
Future<String?> editPersonDialog(BuildContext context, WidgetRef ref, {Person? existing}) async {
  final s = ref.read(stringsProvider);
  final name = TextEditingController(text: existing?.name ?? '');
  final note = TextEditingController(text: existing?.note ?? '');
  final formKey = GlobalKey<FormState>();
  String? resultId;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(existing == null ? s['addPerson'] : s['editPerson']),
      content: Form(
        key: formKey,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: name,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: s['name']),
            validator: (v) => (v == null || v.trim().isEmpty) ? s['err_nameRequired'] : null,
          ),
          TextFormField(
            controller: note,
            maxLength: 200,
            decoration: InputDecoration(labelText: s['noteOptional']),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(s['cancel'])),
        FilledButton(
          onPressed: () async {
            if (!formKey.currentState!.validate()) return;
            final repo = ref.read(peopleRepoProvider);
            final ok = await runAction(c, ref, () async {
              if (existing == null) {
                resultId = (await repo.create(name: name.text, note: note.text)).id;
              } else {
                await repo.update(Person(
                  id: existing.id,
                  name: name.text,
                  note: note.text,
                  isArchived: existing.isArchived,
                  createdAt: existing.createdAt,
                  updatedAt: existing.updatedAt,
                ));
                resultId = existing.id;
              }
            });
            if (ok && c.mounted) Navigator.pop(c);
          },
          child: Text(s['save']),
        ),
      ],
    ),
  );
  // Controllers are left to GC: disposing here can race the dialog's exit animation.
  return resultId;
}

// ============================== DEBTS TAB ==================================
class DebtsScreen extends ConsumerStatefulWidget {
  const DebtsScreen({super.key});
  @override
  ConsumerState<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends ConsumerState<DebtsScreen> {
  bool _activeOnly = true;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final data = ref.watch(debtsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s['tabDebts']),
        actions: [
          IconButton(
            tooltip: s['addPerson'],
            icon: const Icon(Icons.person_add_alt),
            onPressed: () => editPersonDialog(context, ref),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openAdd(context, s, debtOnly: true),
        icon: const Icon(Icons.add),
        label: Text(s['addLoan']),
      ),
      body: data.when(
        loading: () => const Loading(),
        error: (e, st) => const ErrorView(),
        data: (d) {
          final list = d.people.where((p) => !_activeOnly || p.hasActive).toList();
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            DebtSummaryCard(owedToMe: d.owedToMe, iOwe: d.iOwe),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text(s['activeDebts'])),
                  ButtonSegment(value: false, label: Text(s['allPeople'])),
                ],
                selected: {_activeOnly},
                onSelectionChanged: (v) => setState(() => _activeOnly = v.first),
              ),
            ),
            if (list.isEmpty)
              EmptyState(
                icon: Icons.handshake_outlined,
                message: _activeOnly ? s['emptyDebts'] : s['emptyPeople'],
                action: s['addLoan'],
                onAction: () => openAdd(context, s, debtOnly: true),
              ),
            for (final p in list) _PersonTile(p),
          ]);
        },
      ),
    );
  }
}

class DebtSummaryCard extends ConsumerWidget {
  const DebtSummaryCard({super.key, required this.owedToMe, required this.iOwe, this.onTap});
  final int owedToMe, iOwe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    Widget col(String label, int v, TxType t) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(formatMoney(v, defaultCurrency, s.lang),
                style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: t == TxType.lend
                        ? amountColor(context, TxType.income)
                        : amountColor(context, TxType.expense))),
          ]),
        );
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            col(s['owedToMe'], owedToMe, TxType.lend),
            col(s['iOwe'], iOwe, TxType.borrow),
            if (onTap != null) const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

class _PersonTile extends ConsumerWidget {
  const _PersonTile(this.p);
  final PersonDebt p;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final String status;
    final Color? color;
    if (!p.hasActive) {
      status = p.loans.isEmpty ? s['noLoans'] : s['settled'];
      color = null;
    } else if (p.net > 0) {
      status = s['personOwesYou'].replaceAll('{a}', formatMoney(p.net, defaultCurrency, s.lang));
      color = amountColor(context, TxType.income);
    } else if (p.net < 0) {
      status = s['youOwePerson'].replaceAll('{a}', formatMoney(-p.net, defaultCurrency, s.lang));
      color = amountColor(context, TxType.expense);
    } else {
      status = s['evenBalance'];
      color = null;
    }
    return Opacity(
      opacity: p.person.isArchived ? 0.6 : 1,
      child: ListTile(
        leading: CircleAvatar(child: Text(p.person.name.characters.first.toUpperCase())),
        title: Text(p.person.name),
        subtitle: Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => PersonDetailScreen(personId: p.person.id))),
      ),
    );
  }
}

// ============================ PERSON DETAIL ================================
class PersonDetailScreen extends ConsumerStatefulWidget {
  const PersonDetailScreen({super.key, required this.personId});
  final String personId;
  @override
  ConsumerState<PersonDetailScreen> createState() => _PersonDetailState();
}

class _PersonDetailState extends ConsumerState<PersonDetailScreen> {
  bool _showSettled = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final data = ref.watch(debtsProvider);
    return data.when(
      loading: () => const Scaffold(body: Loading()),
      error: (e, st) => const Scaffold(body: ErrorView()),
      data: (d) {
        final pd = d.people.where((x) => x.person.id == widget.personId).firstOrNull;
        if (pd == null) return Scaffold(appBar: AppBar(), body: EmptyState(icon: Icons.person_off, message: s['err_notFound']));
        final person = pd.person;
        final loans = pd.loans.where((l) => _showSettled || !l.isSettled).toList();
        final settledCount = pd.loans.where((l) => l.isSettled).length;
        return Scaffold(
          appBar: AppBar(
            title: Text(person.name),
            actions: [
              IconButton(
                tooltip: s['editPerson'],
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => editPersonDialog(context, ref, existing: person),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  final repo = ref.read(peopleRepoProvider);
                  if (v == 'archive') {
                    await runAction(context, ref, () => repo.setArchived(person.id, !person.isArchived));
                  } else if (v == 'delete') {
                    if (!await confirmDialog(context, s, title: s['deletePerson'], message: s['deletePersonMsg'])) {
                      return;
                    }
                    if (!context.mounted) return;
                    final ok = await runAction(context, ref, () => repo.delete(person.id));
                    if (ok && context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'archive', child: Text(person.isArchived ? s['unarchive'] : s['archive'])),
                  PopupMenuItem(value: 'delete', child: Text(s['delete'])),
                ],
              ),
            ],
          ),
          floatingActionButton: person.isArchived
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => openAdd(context, s, debtOnly: true, personId: person.id),
                  icon: const Icon(Icons.add),
                  label: Text(s['addLoan']),
                ),
          body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            DebtSummaryCard(owedToMe: pd.owedToMe, iOwe: pd.iOwe),
            if ((person.note ?? '').isNotEmpty)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(person.note!)),
            if (settledCount > 0)
              SwitchListTile(
                title: Text('${s['showSettled']} ($settledCount)'),
                value: _showSettled,
                onChanged: (v) => setState(() => _showSettled = v),
              ),
            if (loans.isEmpty)
              EmptyState(icon: Icons.handshake_outlined, message: s['emptyDebts']),
            for (final l in loans) _LoanCard(loan: l, s: s),
          ]),
        );
      },
    );
  }
}

class _LoanCard extends StatelessWidget {
  const _LoanCard({required this.loan, required this.s});
  final Loan loan;
  final S s;

  @override
  Widget build(BuildContext context) {
    final t = loan.tx;
    final theme = Theme.of(context);
    final df = DateFormat.yMd(s.lang);
    final isLend = t.type == TxType.lend;
    final progress = t.amount == 0 ? 0.0 : loan.paid / t.amount;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(debtIcon(t.type), color: theme.colorScheme.tertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${isLend ? s['lend'] : s['borrow']} · ${formatMoney(t.amount, loan.currencyCode, s.lang)}',
                  style: theme.textTheme.titleMedium),
            ),
            if (loan.isSettled) Chip(label: Text(s['settled']), visualDensity: VisualDensity.compact),
            IconButton(
              tooltip: s['editLoan'],
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => openEditor(context, t),
            ),
          ]),
          Text('${df.format(t.occurredAt)} · ${loan.walletName}${(t.note ?? '').isEmpty ? '' : ' · ${t.note}'}',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Semantics(
            label: '${isLend ? s['collected'] : s['repaid']} ${formatPercent((progress * 10000).round())}',
            child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Text(
                  '${isLend ? s['collected'] : s['repaid']}: ${formatMoney(loan.paid, loan.currencyCode, s.lang)}'),
            ),
            Text('${s['remaining']}: ${formatMoney(loan.remaining, loan.currencyCode, s.lang)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          for (final p in loan.payments)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 8),
              leading: Icon(debtIcon(p.tx.type), size: 20),
              title: Text(formatMoney(p.tx.amount, loan.currencyCode, s.lang)),
              subtitle: Text('${df.format(p.tx.occurredAt)} · ${p.walletName}'
                  '${(p.tx.note ?? '').isEmpty ? '' : ' · ${p.tx.note}'}'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => openEditor(context, p.tx),
            ),
          if (!loan.isSettled)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: Icon(debtIcon(t.type.paymentType)),
                label: Text(isLend ? s['collect'] : s['repay']),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => PaymentFormScreen(loanId: t.id))),
              ),
            ),
        ]),
      ),
    );
  }
}

// =============================== LOAN FORM =================================
class LoanFormScreen extends ConsumerStatefulWidget {
  const LoanFormScreen({super.key, this.existing, this.initialType = TxType.lend, this.personId});
  final Tx? existing;
  final TxType initialType;
  final String? personId;
  @override
  ConsumerState<LoanFormScreen> createState() => _LoanFormState();
}

class _LoanFormState extends ConsumerState<LoanFormScreen> {
  static const _newPerson = '__new__';
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late TxType _type;
  String? _personId;
  String? _walletId;
  late DateTime _when;
  bool _saving = false;
  int _pickerReset = 0;

  Tx? get _e => widget.existing;

  @override
  void initState() {
    super.initState();
    final lang = ref.read(settingsProvider).lang;
    _amount = TextEditingController(text: _e == null ? '' : formatAmountInput(_e!.amount, lang));
    _note = TextEditingController(text: _e?.note ?? '');
    _type = _e?.type ?? widget.initialType;
    _personId = _e?.personId ?? widget.personId;
    _walletId = _e?.walletId;
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
    final repo = ref.read(debtRepoProvider);
    final amount = parseAmount(_amount.text)!;
    final ok = await runAction(context, ref, () async {
      if (_e == null) {
        await repo.createLoan(
            type: _type, personId: _personId!, walletId: _walletId!, amount: amount,
            occurredAt: _when, note: _note.text);
      } else {
        await repo.updateLoan(_e!.copyWith(
            type: _type, personId: _personId, walletId: _walletId, amount: amount,
            occurredAt: _when, note: _note.text));
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  Future<void> _delete(int paymentCount) async {
    final s = ref.read(stringsProvider);
    final repo = ref.read(debtRepoProvider);
    if (paymentCount == 0) {
      if (!await confirmDialog(context, s, title: s['deleteLoan'], message: s['deleteLoanMsg'])) return;
    } else {
      // Strong confirmation: two dialogs.
      if (!await confirmDialog(context, s,
          title: s['deleteLoan'],
          message: s['deleteLoanWithPaymentsMsg'].replaceAll('{n}', '$paymentCount'),
          confirmLabel: s['continue'])) {
        return;
      }
      if (!mounted) return;
      if (!await confirmDialog(context, s,
          title: s['areYouSure'], message: s['cannotUndo'], confirmLabel: s['deleteAll'])) {
        return;
      }
    }
    if (!mounted) return;
    final ok = await runAction(context, ref, () => repo.deleteLoan(_e!.id, cascade: paymentCount > 0));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final wallets = ref.watch(allWalletsProvider);
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final loan = _e == null
        ? null
        : ref.watch(debtsProvider).value?.loans.where((l) => l.tx.id == _e!.id).firstOrNull;
    final paid = loan?.paid ?? 0;
    final payCount = loan?.payments.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_e == null ? s['addLoan'] : s['editLoan']),
        actions: [
          if (_e != null)
            IconButton(
                tooltip: s['delete'], icon: const Icon(Icons.delete_outline), onPressed: () => _delete(payCount)),
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
          final pickable = people.where((p) => !p.isArchived || p.id == _personId).toList();
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              SegmentedButton<TxType>(
                segments: [
                  ButtonSegment(value: TxType.lend, label: Text(s['lend']), icon: const Icon(Icons.call_made)),
                  ButtonSegment(value: TxType.borrow, label: Text(s['borrow']), icon: const Icon(Icons.call_received)),
                ],
                selected: {_type},
                onSelectionChanged: paid > 0 ? null : (v) => setState(() => _type = v.first),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(s['${_type.name}Hint'], style: Theme.of(context).textTheme.bodySmall),
              ),
              const SizedBox(height: 16),
              AmountField(controller: _amount, s: s, autofocus: _e == null),
              if (paid > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4),
                  child: Text(
                    '${_type == TxType.lend ? s['collected'] : s['repaid']}: '
                    '${formatMoney(paid, defaultCurrency, s.lang)} – ${s['loanMinHint']}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('p$_personId${pickable.length}$_pickerReset'),
                initialValue: pickable.any((p) => p.id == _personId) ? _personId : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: s['person']),
                validator: (v) => v == null || v == _newPerson ? s['err_personRequired'] : null,
                items: [
                  for (final p in pickable) DropdownMenuItem(value: p.id, child: Text(p.name)),
                  DropdownMenuItem(
                    value: _newPerson,
                    child: Row(children: [
                      const Icon(Icons.person_add_alt, size: 20),
                      const SizedBox(width: 8),
                      Text(s['addPerson']),
                    ]),
                  ),
                ],
                onChanged: (v) async {
                  if (v == _newPerson) {
                    final id = await editPersonDialog(context, ref);
                    if (!mounted) return;
                    setState(() {
                      _personId = id ?? _personId;
                      _pickerReset++;
                    });
                  } else {
                    setState(() => _personId = v);
                  }
                },
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
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(s['debtNotInReports'], style: Theme.of(context).textTheme.bodySmall),
              ),
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

// ============================ REPAYMENT FORM ===============================
class PaymentFormScreen extends ConsumerStatefulWidget {
  const PaymentFormScreen({super.key, required this.loanId, this.existing});
  final String loanId;
  final Tx? existing;
  @override
  ConsumerState<PaymentFormScreen> createState() => _PaymentFormState();
}

class _PaymentFormState extends ConsumerState<PaymentFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _note;
  String? _walletId;
  late DateTime _when;
  bool _saving = false;

  Tx? get _e => widget.existing;

  @override
  void initState() {
    super.initState();
    final lang = ref.read(settingsProvider).lang;
    _amount = TextEditingController(text: _e == null ? '' : formatAmountInput(_e!.amount, lang));
    _note = TextEditingController(text: _e?.note ?? '');
    _walletId = _e?.walletId;
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
    final repo = ref.read(debtRepoProvider);
    final amount = parseAmount(_amount.text)!;
    final ok = await runAction(context, ref, () async {
      if (_e == null) {
        await repo.createPayment(
            loanId: widget.loanId, walletId: _walletId!, amount: amount, occurredAt: _when, note: _note.text);
      } else {
        await repo.updatePayment(
            _e!.copyWith(amount: amount, walletId: _walletId, occurredAt: _when, note: _note.text));
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final s = ref.read(stringsProvider);
    if (!await confirmDialog(context, s, title: s['deletePayment'], message: s['deletePaymentMsg'])) return;
    if (!mounted) return;
    final ok = await runAction(context, ref, () => ref.read(debtRepoProvider).deletePayment(_e!.id));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final wallets = ref.watch(allWalletsProvider);
    final debts = ref.watch(debtsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_e == null ? s['addPayment'] : s['editPayment']),
        actions: [
          if (_e != null)
            IconButton(tooltip: s['delete'], icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: debts.when(
        loading: () => const Loading(),
        error: (e, st) => const ErrorView(),
        data: (d) {
          final loan = d.loans.where((l) => l.tx.id == widget.loanId).firstOrNull;
          final ws = wallets.value;
          if (loan == null || ws == null) return const Loading();
          final usable = ws.where((w) => !w.wallet.isArchived || w.wallet.id == _e?.walletId).toList();
          if (usable.isEmpty) return EmptyState(icon: Icons.account_balance_wallet_outlined, message: s['emptyNoWallet']);
          _walletId ??= usable.any((w) => w.wallet.id == loan.tx.walletId) ? loan.tx.walletId : usable.first.wallet.id;
          final isLend = loan.tx.type == TxType.lend;
          final max = loan.remaining + (_e?.amount ?? 0);
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: Icon(debtIcon(loan.tx.type)),
                  title: Text('${isLend ? s['lend'] : s['borrow']} · ${loan.personName}'),
                  subtitle: Text(
                      '${formatMoney(loan.tx.amount, loan.currencyCode, s.lang)} · ${s['remaining']}: '
                      '${formatMoney(loan.remaining, loan.currencyCode, s.lang)}'),
                ),
              ),
              const SizedBox(height: 16),
              Text(isLend ? s['collectHint'] : s['repayHint'], style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              AmountField(controller: _amount, s: s, max: max, autofocus: _e == null),
              if (_e == null && loan.remaining > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _amount.text = formatAmountInput(loan.remaining, s.lang),
                    child: Text(s['payFull']),
                  ),
                ),
              const SizedBox(height: 8),
              WalletDropdown(
                wallets: usable,
                value: _walletId,
                label: isLend ? s['receiveInto'] : s['payFrom'],
                onChanged: (v) => setState(() => _walletId = v),
              ),
              const SizedBox(height: 16),
              DateTimeRow(value: _when, s: s, onChanged: (v) => setState(() => _when = v)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(labelText: s['noteOptional']),
              ),
              const SizedBox(height: 8),
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

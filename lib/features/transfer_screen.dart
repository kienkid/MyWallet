import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/widgets.dart';
import '../core/models.dart';
import '../core/money.dart';
import 'wallet_screens.dart';

/// Moves money between two wallets. Never counted as income or expense.
class TransferFormScreen extends ConsumerStatefulWidget {
  const TransferFormScreen({super.key, this.existing});
  final Tx? existing;
  @override
  ConsumerState<TransferFormScreen> createState() => _TransferFormState();
}

class _TransferFormState extends ConsumerState<TransferFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _note;
  String? _from;
  String? _to;
  late DateTime _when;
  bool _saving = false;

  Tx? get _e => widget.existing;

  @override
  void initState() {
    super.initState();
    final lang = ref.read(settingsProvider).lang;
    _amount = TextEditingController(text: _e == null ? '' : formatAmountInput(_e!.amount, lang));
    _note = TextEditingController(text: _e?.note ?? '');
    _from = _e?.walletId;
    _to = _e?.toWalletId;
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
        await repo.createTransfer(
            fromWalletId: _from!, toWalletId: _to!, amount: amount, occurredAt: _when, note: _note.text);
      } else {
        await repo.updateTransfer(_e!.copyWith(
            amount: amount, walletId: _from, toWalletId: _to, occurredAt: _when, note: _note.text));
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final s = ref.read(stringsProvider);
    if (!await confirmDialog(context, s, title: s['deleteTransfer'], message: s['deleteTransferMsg'])) return;
    if (!mounted) return;
    final ok = await runAction(context, ref, () => ref.read(txRepoProvider).delete(_e!.id));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final wallets = ref.watch(allWalletsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_e == null ? s['addTransfer'] : s['editTransfer']),
        actions: [
          if (_e != null)
            IconButton(tooltip: s['delete'], icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: wallets.when(
        loading: () => const Loading(),
        error: (e, st) => const ErrorView(),
        data: (ws) {
          final keep = {_e?.walletId, _e?.toWalletId};
          final usable = ws.where((w) => !w.wallet.isArchived || keep.contains(w.wallet.id)).toList();
          if (usable.length < 2) {
            return EmptyState(
              icon: Icons.swap_horiz,
              message: s['transferNeedsTwoWallets'],
              action: s['addWallet'],
              onAction: () => openWalletForm(context),
            );
          }
          _from ??= usable.first.wallet.id;
          _to ??= usable.firstWhere((w) => w.wallet.id != _from).wallet.id;
          final balances = {for (final w in ws) w.wallet.id: w};
          final fromBal = balances[_from];
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              AmountField(controller: _amount, s: s, autofocus: _e == null),
              const SizedBox(height: 16),
              WalletDropdown(
                wallets: usable,
                value: _from,
                label: s['fromWallet'],
                onChanged: (v) => setState(() => _from = v),
              ),
              if (fromBal != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4),
                  child: Text(
                    '${s['balance']}: ${formatMoney(fromBal.balance, fromBal.wallet.currencyCode, s.lang)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Center(
                child: IconButton(
                  tooltip: s['swapWallets'],
                  icon: const Icon(Icons.swap_vert),
                  onPressed: () => setState(() {
                    final t = _from;
                    _from = _to;
                    _to = t;
                  }),
                ),
              ),
              WalletDropdown(
                wallets: usable,
                value: _to,
                label: s['toWallet'],
                onChanged: (v) => setState(() => _to = v),
                validator: (v) => v == _from ? s['err_sameWallet'] : null,
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
                child: Text(s['transferHint'], style: Theme.of(context).textTheme.bodySmall),
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

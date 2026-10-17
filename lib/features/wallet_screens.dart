import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/widgets.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/util.dart';

Future<void> openWalletForm(BuildContext context, {WalletWithBalance? existing}) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => WalletFormScreen(existing: existing)));

class WalletsScreen extends ConsumerWidget {
  const WalletsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final wallets = ref.watch(allWalletsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s['wallets'])),
      floatingActionButton: FloatingActionButton(
        tooltip: s['addWallet'],
        onPressed: () => openWalletForm(context),
        child: const Icon(Icons.add),
      ),
      body: wallets.when(
        loading: () => const Loading(),
        error: (e, st) => const ErrorView(),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              message: s['emptyNoWallet'],
              action: s['addWallet'],
              onAction: () => openWalletForm(context),
            );
          }
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            for (final w in list)
              Opacity(
                opacity: w.wallet.isArchived ? 0.6 : 1,
                child: ListTile(
                  leading: ColoredIcon.fromKey(iconKey: w.wallet.iconKey, color: w.wallet.colorValue),
                  title: Text(w.wallet.name),
                  subtitle: Text(w.wallet.isArchived
                      ? s['archived']
                      : '${w.txCount} ${s['transactionsCount']}'),
                  trailing: Text(formatMoney(w.balance, w.wallet.currencyCode, s.lang),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () => openWalletForm(context, existing: w),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class WalletFormScreen extends ConsumerStatefulWidget {
  const WalletFormScreen({super.key, this.existing});
  final WalletWithBalance? existing;
  @override
  ConsumerState<WalletFormScreen> createState() => _WalletFormState();
}

class _WalletFormState extends ConsumerState<WalletFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _opening;
  late String _icon;
  late int _color;
  late String _currency;
  bool _saving = false;

  Wallet? get _w => widget.existing?.wallet;

  @override
  void initState() {
    super.initState();
    final lang = ref.read(settingsProvider).lang;
    _name = TextEditingController(text: _w?.name ?? '');
    _opening = TextEditingController(
        text: _w == null || _w!.openingBalance == 0 ? '' : formatAmountInput(_w!.openingBalance, lang));
    _icon = _w?.iconKey ?? 'wallet';
    _color = _w?.colorValue ?? colorPalette.first;
    _currency = _w?.currencyCode ?? defaultCurrency;
  }

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(walletRepoProvider);
    final opening = _opening.text.trim().isEmpty ? 0 : parseAmount(_opening.text, allowNegative: true)!;
    final ok = await runAction(context, ref, () async {
      if (_w == null) {
        await repo.create(
            name: _name.text, iconKey: _icon, colorValue: _color,
            currencyCode: _currency, openingBalance: opening);
      } else {
        await repo.update(_w!.copyWith(
            name: _name.text, iconKey: _icon, colorValue: _color,
            currencyCode: _currency, openingBalance: opening));
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final s = ref.read(stringsProvider);
    final w = widget.existing!;
    final repo = ref.read(walletRepoProvider);
    final count = await repo.txCount(w.wallet.id);
    if (!mounted) return;
    if (count == 0) {
      if (!await confirmDialog(context, s, title: s['deleteWallet'], message: s['deleteWalletMsg'])) return;
      if (!mounted) return;
      if (await runAction(context, ref, () => repo.delete(w.wallet.id)) && mounted) {
        Navigator.pop(context);
      }
      return;
    }
    // Wallet has movements: offer archive or reassignment, never silent loss.
    final others = (await repo.list())
        .where((o) => o.wallet.id != w.wallet.id && o.wallet.currencyCode == w.wallet.currencyCode)
        .toList();
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(s['walletHasTx'].replaceAll('{n}', '$count')),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'archive'),
            child: ListTile(leading: const Icon(Icons.archive_outlined), title: Text(s['archiveInstead'])),
          ),
          for (final o in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, o.wallet.id),
              child: ListTile(
                leading: const Icon(Icons.move_down),
                title: Text(s['moveTxTo'].replaceAll('{w}', o.wallet.name)),
              ),
            ),
          SimpleDialogOption(onPressed: () => Navigator.pop(c), child: Text(s['cancel'])),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'archive') {
      if (await runAction(context, ref, () => repo.setArchived(w.wallet.id, true)) && mounted) {
        Navigator.pop(context);
      }
      return;
    }
    if (!await confirmDialog(context, s, title: s['deleteWallet'], message: s['moveAndDeleteMsg'])) return;
    if (!mounted) return;
    if (await runAction(context, ref, () => repo.reassignAndDelete(fromId: w.wallet.id, toId: choice)) &&
        mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final hasTx = (widget.existing?.txCount ?? 0) > 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(_w == null ? s['addWallet'] : s['editWallet']),
        actions: [
          if (_w != null)
            IconButton(
              tooltip: _w!.isArchived ? s['unarchive'] : s['archive'],
              icon: Icon(_w!.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
              onPressed: () async {
                final ok = await runAction(context, ref,
                    () => ref.read(walletRepoProvider).setArchived(_w!.id, !_w!.isArchived));
                if (ok && context.mounted) Navigator.pop(context);
              },
            ),
          if (_w != null)
            IconButton(tooltip: s['delete'], icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Semantics(
              button: true,
              label: '${s['icon']} / ${s['color']}',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () async {
                  final r = await pickIconAndColor(context, s, _icon, _color);
                  if (r != null) {
                    setState(() {
                      _icon = r.$1;
                      _color = r.$2;
                    });
                  }
                },
                child: ColoredIcon.fromKey(iconKey: _icon, color: _color, size: 56),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                controller: _name,
                maxLength: 50,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: s['name']),
                validator: (v) => (v == null || v.trim().isEmpty) ? s['err_nameRequired'] : null,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _currency,
            decoration: InputDecoration(
              labelText: s['currency'],
              helperText: hasTx ? s['currencyLockedHint'] : null,
            ),
            items: [
              for (final c in currencies.values)
                DropdownMenuItem(value: c.code, child: Text('${c.code} (${c.symbol})')),
            ],
            onChanged: hasTx ? null : (v) => setState(() => _currency = v ?? defaultCurrency),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _opening,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [ThousandsInputFormatter(s.lang, allowNegative: true)],
            decoration: InputDecoration(
              labelText: s['openingBalance'],
              suffixText: currencies[_currency]?.symbol,
              helperText: s['openingBalanceHint'],
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return null;
              return parseAmount(v, allowNegative: true) == null ? s['err_amountInvalid'] : null;
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(s['save']),
          ),
        ]),
      ),
    );
  }
}

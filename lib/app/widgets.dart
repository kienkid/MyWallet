import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/models.dart';
import '../core/money.dart';
import '../core/util.dart';
import 'providers.dart';
import 'strings.dart';

/// Runs a write action, bumps the data version, and shows a localized error
/// snackbar on failure. Returns true on success. Never logs financial data.
Future<bool> runAction(BuildContext context, WidgetRef ref, Future<void> Function() action) async {
  final s = ref.read(stringsProvider);
  try {
    await action();
    ref.read(dataVersionProvider.notifier).bump();
    return true;
  } on AppException catch (e) {
    if (context.mounted) showSnack(context, s.err(e.code));
  } catch (_) {
    if (context.mounted) showSnack(context, s['err_generic']);
  }
  return false;
}

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

Future<bool> confirmDialog(BuildContext context, S s,
    {required String title, required String message, String? confirmLabel}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s['cancel'])),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmLabel ?? s['delete']),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message, this.action, this.onAction});
  final IconData icon;
  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: cs.outline),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(action!)),
          ],
        ]),
      ),
    );
  }
}

class ErrorView extends ConsumerWidget {
  const ErrorView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    return EmptyState(
      icon: Icons.error_outline,
      message: s['err_load'],
      action: s['retry'],
      onAction: () => ref.read(dataVersionProvider.notifier).bump(),
    );
  }
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator());
}

class ColoredIcon extends StatelessWidget {
  const ColoredIcon({super.key, required this.icon, required this.color, this.size = 40});
  ColoredIcon.fromKey({super.key, required String iconKey, required this.color, this.size = 40})
      : icon = iconFor(iconKey);
  final IconData icon;
  final int color;
  final double size;
  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: size / 2,
        backgroundColor: Color(color),
        child: Icon(icon, color: Colors.white, size: size * 0.55),
      );
}

const int transferColor = 0xFF546E7A;
const int debtColor = 0xFF5E35B1;

Color amountColor(BuildContext context, TxType type) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final cs = Theme.of(context).colorScheme;
  return switch (type) {
    TxType.income => dark ? incomeColorDark : incomeColor,
    TxType.expense => dark ? expenseColorDark : expenseColor,
    TxType.transfer => cs.onSurfaceVariant,
    _ => cs.tertiary,
  };
}

IconData debtIcon(TxType t) => switch (t) {
      TxType.lend => Icons.call_made,
      TxType.borrow => Icons.call_received,
      TxType.collect => Icons.south_west,
      _ => Icons.north_east,
    };

class TxTile extends ConsumerWidget {
  const TxTile({super.key, required this.view, this.onTap});
  final TxView view;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final t = view.tx;
    final isTransfer = t.type == TxType.transfer;
    final amount = isTransfer
        ? formatMoney(t.amount, view.currencyCode, s.lang)
        : formatMoney(t.signed, view.currencyCode, s.lang, signed: true);
    final date = DateFormat.yMd(s.lang).add_Hm().format(t.occurredAt);
    final title = s.txTitle(view);
    final walletText = isTransfer ? '${view.walletName} → ${view.toWalletName ?? ''}' : view.walletName;
    final Widget leading = switch (t.type) {
      TxType.income || TxType.expense when view.category != null =>
        ColoredIcon.fromKey(iconKey: view.category!.iconKey, color: view.category!.colorValue),
      TxType.transfer => const ColoredIcon(icon: Icons.swap_horiz, color: transferColor),
      _ => ColoredIcon(icon: debtIcon(t.type), color: debtColor),
    };
    return Semantics(
      label: '$title, $amount, $walletText, $date',
      button: onTap != null,
      excludeSemantics: true,
      child: ListTile(
        onTap: onTap,
        minVerticalPadding: 8,
        leading: leading,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [walletText, date, if ((t.note ?? '').isNotEmpty) t.note!].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(amount,
            style: TextStyle(fontWeight: FontWeight.w600, color: amountColor(context, t.type))),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
        child: Row(children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(text, style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          ?trailing,
        ]),
      );
}

/// Grid picker for icon + colour. Returns (iconKey, colorValue) or null.
Future<(String, int)?> pickIconAndColor(BuildContext context, S s, String icon, int color) {
  var selIcon = icon;
  var selColor = color;
  return showModalBottomSheet<(String, int)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s['color'], style: Theme.of(c).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final col in colorPalette)
                Semantics(
                  label: '${s['color']} ${colorToHex(col)}',
                  selected: col == selColor,
                  button: true,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => selColor = col),
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: Color(col),
                      child: col == selColor ? const Icon(Icons.check, color: Colors.white) : null,
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 16),
            Text(s['icon'], style: Theme.of(c).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in iconCatalog.keys)
                IconButton.filledTonal(
                  tooltip: k,
                  isSelected: k == selIcon,
                  onPressed: () => setState(() => selIcon = k),
                  icon: Icon(iconFor(k)),
                  selectedIcon: Icon(iconFor(k), color: Color(selColor)),
                ),
            ]),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(c, (selIcon, selColor)),
                child: Text(s['done']),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

/// Grouped, searchable category picker (parents with indented children).
/// Returns the chosen category id, or null if dismissed.
Future<String?> pickCategory(BuildContext context, S s, List<Category> categories, String? selectedId) {
  final ordered = orderTree(categories);
  var query = '';
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(builder: (c, setState) {
      final q = normalizeText(query.trim());
      final parentName = {for (final x in categories) x.id: s.categoryName(x)};
      final visible = q.isEmpty
          ? ordered
          : ordered.where((x) {
              final own = normalizeText(s.categoryName(x));
              final par = x.parentId == null ? '' : normalizeText(parentName[x.parentId] ?? '');
              return own.contains(q) || par.contains(q);
            }).toList();
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.of(c).size.height * 0.75,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: s['searchCategory']),
                onChanged: (v) => setState(() => query = v),
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? Center(child: Text(s['noResults']))
                  : ListView(children: [
                      for (final x in visible)
                        ListTile(
                          contentPadding: EdgeInsets.only(left: x.parentId == null ? 16 : 48, right: 16),
                          leading: ColoredIcon.fromKey(
                              iconKey: x.iconKey, color: x.colorValue, size: x.parentId == null ? 36 : 30),
                          title: Text(
                            s.categoryName(x),
                            style: x.parentId == null ? const TextStyle(fontWeight: FontWeight.w600) : null,
                          ),
                          trailing: x.id == selectedId ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(c, x.id),
                        ),
                    ]),
            ),
          ]),
        ),
      );
    }),
  );
}

/// Bottom sheet with every "add" action. [debtOnly] limits it to lend/borrow.
Future<TxType?> chooseAddType(BuildContext context, S s, {bool debtOnly = false}) {
  final items = <(TxType, IconData, String)>[
    if (!debtOnly) (TxType.expense, Icons.remove_circle_outline, s['expense']),
    if (!debtOnly) (TxType.income, Icons.add_circle_outline, s['income']),
    if (!debtOnly) (TxType.transfer, Icons.swap_horiz, s['transfer']),
    (TxType.lend, Icons.call_made, s['lend']),
    (TxType.borrow, Icons.call_received, s['borrow']),
  ];
  return showModalBottomSheet<TxType>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final it in items)
          ListTile(
            leading: Icon(it.$2),
            title: Text(it.$3),
            subtitle: it.$1.isLoan ? Text(s['${it.$1.name}Hint']) : null,
            onTap: () => Navigator.pop(c, it.$1),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

/// Shared amount field with digit grouping and > 0 validation.
class AmountField extends StatelessWidget {
  const AmountField({super.key, required this.controller, required this.s, this.max, this.autofocus = false});
  final TextEditingController controller;
  final S s;
  final int? max;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        autofocus: autofocus,
        keyboardType: TextInputType.number,
        inputFormatters: [ThousandsInputFormatter(s.lang)],
        style: Theme.of(context).textTheme.headlineSmall,
        decoration: InputDecoration(
          labelText: s['amount'],
          suffixText: '₫',
          helperText: max == null ? null : '${s['maxAmount']}: ${formatMoney(max!, defaultCurrency, s.lang)}',
        ),
        validator: (v) {
          final a = parseAmount(v ?? '');
          if (a == null || a <= 0) return s['err_amountInvalid'];
          if (max != null && a > max!) return s['err_overpayment'];
          return null;
        },
      );
}

/// Date + time row used by every form.
class DateTimeRow extends StatelessWidget {
  const DateTimeRow({super.key, required this.value, required this.s, required this.onChanged});
  final DateTime value;
  final S s;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final future = value.isAfter(DateTime.now().add(const Duration(minutes: 1)));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.event),
      title: Text(DateFormat.yMMMMEEEEd(s.lang).add_Hm().format(value)),
      subtitle: future ? Text(s['futureDateWarning']) : null,
      trailing: TextButton(
        onPressed: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
            locale: Locale(s.lang),
          );
          if (d == null || !context.mounted) return;
          final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(value));
          onChanged(DateTime(d.year, d.month, d.day, t?.hour ?? value.hour, t?.minute ?? value.minute));
        },
        child: Text(s['change']),
      ),
    );
  }
}

/// Wallet dropdown limited to active wallets (+ [keepId] if archived).
class WalletDropdown extends StatelessWidget {
  const WalletDropdown({
    super.key,
    required this.wallets,
    required this.value,
    required this.label,
    required this.onChanged,
    this.validator,
  });
  final List<WalletWithBalance> wallets;
  final String? value;
  final String label;
  final ValueChanged<String?> onChanged;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
        key: ValueKey('wd$label$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        validator: validator,
        items: [
          for (final w in wallets)
            DropdownMenuItem(
              value: w.wallet.id,
              child: Row(children: [
                ColoredIcon.fromKey(iconKey: w.wallet.iconKey, color: w.wallet.colorValue, size: 28),
                const SizedBox(width: 12),
                Expanded(child: Text(w.wallet.name, overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
        onChanged: onChanged,
      );
}

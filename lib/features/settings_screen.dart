import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/providers.dart';
import '../app/widgets.dart';
import '../data/backup_service.dart';
import 'category_screens.dart';
import 'wallet_screens.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider);
    final themeLabel = {
      ThemeMode.system: s['themeSystem'],
      ThemeMode.light: s['themeLight'],
      ThemeMode.dark: s['themeDark'],
    };
    return Scaffold(
      appBar: AppBar(title: Text(s['tabSettings'])),
      body: ListView(children: [
        SectionHeader(s['general']),
        ListTile(
          leading: const Icon(Icons.language),
          title: Text(s['language']),
          subtitle: Text(settings.lang == 'vi' ? 'Tiếng Việt' : 'English'),
          onTap: () async {
            final v = await showDialog<String>(
              context: context,
              builder: (c) => SimpleDialog(title: Text(s['language']), children: [
                for (final e in const {'vi': 'Tiếng Việt', 'en': 'English'}.entries)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, e.key),
                    child: ListTile(
                      title: Text(e.value),
                      trailing: settings.lang == e.key ? const Icon(Icons.check) : null,
                    ),
                  ),
              ]),
            );
            if (v != null) await ref.read(settingsProvider.notifier).setLang(v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: Text(s['theme']),
          subtitle: Text(themeLabel[settings.themeMode]!),
          onTap: () async {
            final v = await showDialog<ThemeMode>(
              context: context,
              builder: (c) => SimpleDialog(title: Text(s['theme']), children: [
                for (final m in ThemeMode.values)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, m),
                    child: ListTile(
                      title: Text(themeLabel[m]!),
                      trailing: settings.themeMode == m ? const Icon(Icons.check) : null,
                    ),
                  ),
              ]),
            );
            if (v != null) await ref.read(settingsProvider.notifier).setTheme(v);
          },
        ),
        SectionHeader(s['data']),
        ListTile(
          leading: const Icon(Icons.account_balance_wallet_outlined),
          title: Text(s['wallets']),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WalletsScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.category_outlined),
          title: Text(s['categories']),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CategoriesScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.upload_file),
          title: Text(s['exportCsv']),
          subtitle: Text(s['exportCsvHint']),
          onTap: () => _export(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.download),
          title: Text(s['importCsv']),
          subtitle: Text(s['importCsvHint']),
          onTap: () => _import(context, ref),
        ),
        SectionHeader(s['about']),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(s['about']),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen())),
        ),
      ]),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final s = ref.read(stringsProvider);
    try {
      final files = await ref.read(exportServiceProvider).buildFiles();
      final n = await ref.read(fileGatewayProvider).saveToFolder(files);
      if (!context.mounted) return;
      showSnack(context, n == null ? s['cancelled'] : s['exportDone'].replaceAll('{n}', '$n'));
    } on PlatformException {
      if (context.mounted) showSnack(context, s['err_fileWrite']);
    } catch (_) {
      if (context.mounted) showSnack(context, s['err_generic']);
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final s = ref.read(stringsProvider);
    try {
      final files = await ref.read(fileGatewayProvider).pickCsvFiles();
      if (files.isEmpty) return;
      final plan = await ref.read(importServiceProvider).analyze(files);
      if (!context.mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ImportPreviewScreen(plan: plan)));
    } on PlatformException {
      if (context.mounted) showSnack(context, s['err_fileRead']);
    } catch (_) {
      if (context.mounted) showSnack(context, s['err_generic']);
    }
  }
}

class ImportPreviewScreen extends ConsumerStatefulWidget {
  const ImportPreviewScreen({super.key, required this.plan});
  final ImportPlan plan;
  @override
  ConsumerState<ImportPreviewScreen> createState() => _ImportPreviewState();
}

class _ImportPreviewState extends ConsumerState<ImportPreviewScreen> {
  DuplicateMode _mode = DuplicateMode.skip;
  bool _busy = false;

  Future<void> _commit() async {
    final s = ref.read(stringsProvider);
    setState(() => _busy = true);
    try {
      final r = await ref.read(importServiceProvider).commit(widget.plan, _mode);
      ref.read(dataVersionProvider.notifier).bump();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(r.dryRun ? s['reportOnlyDone'] : s['importDone']),
          content: Text([
            '${s['imported']}: ${r.imported}',
            '${s['replaced']}: ${r.replaced}',
            '${s['duplicates']}: ${r.duplicates}',
            '${s['skipped']}: ${r.skipped}',
            '${s['failed']}: ${r.failed}',
          ].join('\n')),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(s['done']))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      // Database transaction already rolled back – nothing was changed.
      if (mounted) showSnack(context, s['err_importRolledBack']);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final p = widget.plan;
    final theme = Theme.of(context);
    TableRow row(String label, int a, int b) => TableRow(children: [
          Padding(padding: const EdgeInsets.all(6), child: Text(label)),
          Padding(padding: const EdgeInsets.all(6), child: Text('$a', textAlign: TextAlign.end)),
          Padding(padding: const EdgeInsets.all(6), child: Text('$b', textAlign: TextAlign.end)),
        ]);
    return Scaffold(
      appBar: AppBar(title: Text(s['importPreview'])),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (p.fileErrors.isNotEmpty) ...[
          Text(s['importFileErrors'], style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error)),
          for (final e in p.fileErrors) ListTile(leading: const Icon(Icons.error_outline), title: Text(e)),
          const SizedBox(height: 8),
          Text(s['importFixFiles']),
        ] else ...[
          Text('${s['filesRead']}: ${p.filesRead.join(', ')}'),
          const SizedBox(height: 12),
          Table(columnWidths: const {0: FlexColumnWidth(2)}, children: [
            TableRow(children: [
              const SizedBox(),
              Padding(padding: const EdgeInsets.all(6), child: Text(s['new'], textAlign: TextAlign.end, style: theme.textTheme.labelLarge)),
              Padding(padding: const EdgeInsets.all(6), child: Text(s['duplicates'], textAlign: TextAlign.end, style: theme.textTheme.labelLarge)),
            ]),
            row(s['wallets'], p.newWallets.length, p.dupWallets.length),
            row(s['people'], p.newPeople.length, p.dupPeople.length),
            row(s['categories'], p.newCategories.length, p.dupCategories.length),
            row(s['tabTransactions'], p.newTxs.length, p.dupTxs.length),
          ]),
          const SizedBox(height: 8),
          Text('${s['unchanged']}: ${p.unchanged}   ·   ${s['failed']}: ${p.failedRows}'),
          const SizedBox(height: 16),
          Text(s['duplicateMode'], style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<DuplicateMode>(
            segments: [
              ButtonSegment(value: DuplicateMode.skip, label: Text(s['modeSkip'])),
              ButtonSegment(value: DuplicateMode.replace, label: Text(s['modeReplace'])),
              ButtonSegment(value: DuplicateMode.reportOnly, label: Text(s['modeReport'])),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          const SizedBox(height: 8),
          Text(s['importAtomicHint'], style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy || (!p.canCommit && _mode != DuplicateMode.reportOnly) ? null : _commit,
            child: Text(_mode == DuplicateMode.reportOnly ? s['runReport'] : s['importNow']),
          ),
          if (p.errors.isNotEmpty) ...[
            SectionHeader('${s['rowErrors']} (${p.errors.length})'),
            for (final e in p.errors.take(200))
              ListTile(
                dense: true,
                leading: Icon(Icons.warning_amber, color: theme.colorScheme.error),
                title: Text('${e.file} · ${s['row']} ${e.row}'),
                subtitle: Text(e.message),
              ),
            if (p.errors.length > 200) Text('… +${p.errors.length - 200}'),
          ],
        ],
      ]),
    );
  }
}

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s['about'])),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snap) => ListView(padding: const EdgeInsets.all(24), children: [
          const Icon(Icons.account_balance_wallet, size: 64),
          const SizedBox(height: 12),
          Text(s['appName'], textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          Text(
            snap.hasData ? '${s['version']} ${snap.data!.version} (${snap.data!.buildNumber})' : '…',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(s['aboutText']),
        ]),
      ),
    );
  }
}

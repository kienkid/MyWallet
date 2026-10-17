import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/widgets.dart';
import '../core/models.dart';
import '../core/util.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final all = ref.watch(allCategoriesProvider);
    void open(TxType type, {Category? existing, String? parentId}) => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => CategoryFormScreen(type: type, existing: existing, initialParentId: parentId)));

    return DefaultTabController(
      length: 2,
      child: Builder(builder: (context) {
        return Scaffold(
          appBar: AppBar(
            title: Text(s['categories']),
            bottom: TabBar(tabs: [Tab(text: s['expense']), Tab(text: s['income'])]),
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: s['addCategory'],
            onPressed: () =>
                open(DefaultTabController.of(context).index == 0 ? TxType.expense : TxType.income),
            child: const Icon(Icons.add),
          ),
          body: all.when(
            loading: () => const Loading(),
            error: (e, st) => const ErrorView(),
            data: (list) => TabBarView(children: [
              for (final type in [TxType.expense, TxType.income])
                ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                  for (final c in orderTree(list.where((c) => c.type == type).toList()))
                    Opacity(
                      opacity: c.isArchived ? 0.6 : 1,
                      child: ListTile(
                        contentPadding: EdgeInsets.only(left: c.parentId == null ? 16 : 52, right: 8),
                        leading: ColoredIcon.fromKey(
                            iconKey: c.iconKey, color: c.colorValue, size: c.parentId == null ? 40 : 32),
                        title: Text(
                          s.categoryName(c),
                          style: c.parentId == null ? const TextStyle(fontWeight: FontWeight.w600) : null,
                        ),
                        subtitle: c.isArchived
                            ? Text(s['archived'])
                            : (c.isDefault ? Text(s['defaultCategory']) : null),
                        trailing: c.parentId == null && !c.isArchived
                            ? IconButton(
                                tooltip: s['addSubCategory'],
                                icon: const Icon(Icons.add),
                                onPressed: () => open(type, parentId: c.id),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: () => open(c.type, existing: c),
                      ),
                    ),
                ]),
            ]),
          ),
        );
      }),
    );
  }
}

class CategoryFormScreen extends ConsumerStatefulWidget {
  const CategoryFormScreen({super.key, required this.type, this.existing, this.initialParentId});
  final TxType type;
  final Category? existing;
  final String? initialParentId;
  @override
  ConsumerState<CategoryFormScreen> createState() => _CategoryFormState();
}

class _CategoryFormState extends ConsumerState<CategoryFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late String _icon;
  late int _color;
  String? _parentId;
  late final String _initialName;
  bool _colorTouched = false;

  Category? get _c => widget.existing;

  @override
  void initState() {
    super.initState();
    _initialName = _c == null ? '' : ref.read(stringsProvider).categoryName(_c!);
    _name = TextEditingController(text: _initialName);
    _icon = _c?.iconKey ?? 'category';
    _color = _c?.colorValue ?? colorPalette[3];
    _parentId = _c?.parentId ?? widget.initialParentId;
    // New sub-category inherits the parent's colour by default.
    if (_c == null && _parentId != null) {
      final cats = ref.read(allCategoriesProvider).value ?? const <Category>[];
      final p = cats.where((x) => x.id == _parentId).firstOrNull;
      if (p != null) _color = p.colorValue;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final repo = ref.read(categoryRepoProvider);
    final renamed = _c != null && _name.text.trim() != _initialName;
    final ok = await runAction(context, ref, () async {
      if (_c == null) {
        await repo.create(
            type: widget.type, name: _name.text, iconKey: _icon, colorValue: _color, parentId: _parentId);
      } else {
        await repo.update(
          _c!.copyWith(
            name: renamed ? _name.text : _c!.name,
            iconKey: _icon,
            colorValue: _color,
            parentId: _parentId,
          ),
          renamed: renamed,
        );
      }
    });
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final s = ref.read(stringsProvider);
    if (!await confirmDialog(context, s, title: s['deleteCategory'], message: s['deleteCategoryMsg'])) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(context, ref, () => ref.read(categoryRepoProvider).delete(_c!.id));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final all = ref.watch(allCategoriesProvider).value ?? const <Category>[];
    final hasChildren = _c != null && all.any((x) => x.parentId == _c!.id);
    // Possible parents: top-level, same type, not itself.
    final parents = all
        .where((x) => x.type == widget.type && x.parentId == null && x.id != _c?.id && (!x.isArchived || x.id == _parentId))
        .toList();
    final typeLabel = widget.type == TxType.income ? s['income'] : s['expense'];
    return Scaffold(
      appBar: AppBar(
        title: Text('${_c == null ? s['addCategory'] : s['editCategory']} · $typeLabel'),
        actions: [
          if (_c != null)
            IconButton(
              tooltip: _c!.isArchived ? s['unarchive'] : s['archive'],
              icon: Icon(_c!.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
              onPressed: () async {
                final ok = await runAction(context, ref,
                    () => ref.read(categoryRepoProvider).setArchived(_c!.id, !_c!.isArchived));
                if (ok && context.mounted) Navigator.pop(context);
              },
            ),
          if (_c != null && !_c!.isDefault)
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
                      _colorTouched = true;
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
                maxLength: 40,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: s['name']),
                validator: (v) => (v == null || v.trim().isEmpty) ? s['err_nameRequired'] : null,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: ValueKey('parent$_parentId${parents.length}'),
            initialValue: parents.any((p) => p.id == _parentId) ? _parentId : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: s['parentCategory'],
              helperText: hasChildren ? s['hasChildrenHint'] : s['parentHint'],
              helperMaxLines: 2,
            ),
            items: [
              DropdownMenuItem(value: null, child: Text(s['noParent'])),
              for (final p in parents)
                DropdownMenuItem(
                  value: p.id,
                  child: Row(children: [
                    ColoredIcon.fromKey(iconKey: p.iconKey, color: p.colorValue, size: 24),
                    const SizedBox(width: 8),
                    Expanded(child: Text(s.categoryName(p), overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ],
            onChanged: hasChildren
                ? null
                : (v) => setState(() {
                      _parentId = v;
                      if (_c == null && !_colorTouched && v != null) {
                        final p = parents.where((x) => x.id == v).firstOrNull;
                        if (p != null) _color = p.colorValue;
                      }
                    }),
          ),
          if (_c?.isDefault ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(s['defaultCategoryHint'], style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(s['save']),
          ),
        ]),
      ),
    );
  }
}

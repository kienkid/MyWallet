import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../core/csv_codec.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/util.dart';

/// Exact CSV contracts. Export uses this column order; import accepts any order.
/// `optional` columns were added in v2 – files exported by v1 still import.
class CsvSchema {
  const CsvSchema(this.file, this.required, [this.optional = const []]);
  final String file;
  final List<String> required;
  final List<String> optional;
  List<String> get exportColumns => [...required, ...optional];
}

class CsvSchemas {
  static const wallets = CsvSchema('wallets.csv', [
    'id', 'name', 'icon_key', 'color_hex', 'currency_code', 'opening_balance',
    'is_archived', 'created_at', 'updated_at',
  ]);
  static const people = CsvSchema('people.csv', [
    'id', 'name', 'note', 'is_archived', 'created_at', 'updated_at',
  ]);
  static const categories = CsvSchema('categories.csv', [
    'id', 'type', 'name', 'name_key', 'icon_key', 'color_hex', 'is_default',
    'is_archived', 'created_at', 'updated_at',
  ], [
    'parent_id',
  ]);
  static const transactions = CsvSchema('transactions.csv', [
    'id', 'type', 'amount', 'currency_code', 'wallet_id', 'category_id',
    'occurred_at', 'note', 'created_at', 'updated_at',
  ], [
    'to_wallet_id', 'person_id', 'loan_id',
  ]);
}

Uint8List _utf8WithBom(String s) => Uint8List.fromList(utf8.encode('\uFEFF$s'));

// ================================ EXPORT ===================================
class ExportService {
  ExportService(this.db);
  final Database db;

  Future<Map<String, Uint8List>> buildFiles() async {
    final wallets = (await db.query('wallets', orderBy: 'created_at')).map(Wallet.fromMap);
    final people = (await db.query('people', orderBy: 'created_at')).map(Person.fromMap);
    // Parents before children so the file is readable top-down.
    final cats = (await db.query('categories',
            orderBy: 'type, (parent_id IS NOT NULL), sort_order, created_at'))
        .map(Category.fromMap);
    final txRows = await db.rawQuery('''
      SELECT t.*, w.currency_code AS w_currency
      FROM transactions t JOIN wallets w ON w.id = t.wallet_id
      ORDER BY (t.loan_id IS NOT NULL), t.occurred_at''');

    final w = <List<String>>[CsvSchemas.wallets.exportColumns];
    for (final x in wallets) {
      w.add([
        x.id, x.name, x.iconKey, colorToHex(x.colorValue), x.currencyCode,
        '${x.openingBalance}', x.isArchived ? '1' : '0',
        isoWithOffset(x.createdAt), isoWithOffset(x.updatedAt),
      ]);
    }
    final p = <List<String>>[CsvSchemas.people.exportColumns];
    for (final x in people) {
      p.add([
        x.id, x.name, x.note ?? '', x.isArchived ? '1' : '0',
        isoWithOffset(x.createdAt), isoWithOffset(x.updatedAt),
      ]);
    }
    final c = <List<String>>[CsvSchemas.categories.exportColumns];
    for (final x in cats) {
      c.add([
        x.id, x.type.name, x.name, x.nameKey ?? '', x.iconKey, colorToHex(x.colorValue),
        x.isDefault ? '1' : '0', x.isArchived ? '1' : '0',
        isoWithOffset(x.createdAt), isoWithOffset(x.updatedAt), x.parentId ?? '',
      ]);
    }
    final t = <List<String>>[CsvSchemas.transactions.exportColumns];
    for (final r in txRows) {
      final x = Tx.fromMap(r);
      t.add([
        x.id, x.type.name, '${x.amount}', r['w_currency'] as String, x.walletId,
        x.categoryId ?? '', isoWithOffset(x.occurredAt), x.note ?? '',
        isoWithOffset(x.createdAt), isoWithOffset(x.updatedAt),
        x.toWalletId ?? '', x.personId ?? '', x.loanId ?? '',
      ]);
    }
    return {
      'wallets.csv': _utf8WithBom(encodeCsv(w)),
      'people.csv': _utf8WithBom(encodeCsv(p)),
      'categories.csv': _utf8WithBom(encodeCsv(c)),
      'transactions.csv': _utf8WithBom(encodeCsv(t)),
    };
  }
}

// ================================ IMPORT ===================================
enum DuplicateMode { skip, replace, reportOnly }

class RowIssue {
  const RowIssue(this.file, this.row, this.message);
  final String file;
  final int row; // CSV record number; header = 1, first data row = 2
  final String message;
  @override
  String toString() => '$file · row $row: $message';
}

class ImportPlan {
  final newWallets = <Wallet>[];
  final dupWallets = <Wallet>[];
  final newPeople = <Person>[];
  final dupPeople = <Person>[];
  final newCategories = <Category>[];
  final dupCategories = <Category>[];
  final newTxs = <Tx>[];
  final dupTxs = <Tx>[];
  var unchanged = 0;
  final errors = <RowIssue>[];
  final fileErrors = <String>[];
  final filesRead = <String>[];

  int get failedRows => errors.map((e) => '${e.file}:${e.row}').toSet().length;
  int get newCount => newWallets.length + newPeople.length + newCategories.length + newTxs.length;
  int get dupCount => dupWallets.length + dupPeople.length + dupCategories.length + dupTxs.length;
  bool get canCommit => fileErrors.isEmpty && (newCount + dupCount) > 0;
}

class ImportResult {
  const ImportResult({
    required this.imported,
    required this.replaced,
    required this.duplicates,
    required this.skipped,
    required this.failed,
    this.dryRun = false,
  });
  final int imported, replaced, duplicates, skipped, failed;
  final bool dryRun;
}

class _Table {
  _Table(this.file, this.header, this.rows);
  final String file;
  final Map<String, int> header;
  final List<List<String>> rows;
  String cell(List<String> r, String col, {bool trim = true}) {
    final i = header[col];
    if (i == null || i >= r.length) return '';
    return trim ? r[i].trim() : r[i];
  }
}

/// A validated row waiting for cross-row checks.
class _Pending<T> {
  _Pending(this.row, this.value);
  final int row;
  final T value;
}

class ImportService {
  ImportService(this.db);
  final Database db;

  static DateTime? _date(String s) {
    try {
      return DateTime.parse(s).toLocal();
    } on FormatException {
      return null;
    }
  }

  static bool? _flag(String s) => s == '1' ? true : (s == '0' ? false : null);

  /// Pure validation – reads the DB but never writes.
  Future<ImportPlan> analyze(Map<String, Uint8List> files) async {
    final plan = ImportPlan();
    final tables = <CsvSchema, _Table>{};

    for (final e in files.entries) {
      final lower = e.key.toLowerCase();
      final schema = lower.contains('transaction')
          ? CsvSchemas.transactions
          : lower.contains('categor')
              ? CsvSchemas.categories
              : lower.contains('wallet')
                  ? CsvSchemas.wallets
                  : (lower.contains('people') || lower.contains('person'))
                      ? CsvSchemas.people
                      : null;
      if (schema == null) {
        plan.fileErrors.add(
            '${e.key}: unrecognized file name (expected wallets/people/categories/transactions)');
        continue;
      }
      if (tables.containsKey(schema)) {
        plan.fileErrors.add('${e.key}: more than one ${schema.file} selected');
        continue;
      }
      String text;
      try {
        text = utf8.decode(e.value);
      } on FormatException {
        plan.fileErrors.add('${e.key}: file is not valid UTF-8');
        continue;
      }
      List<List<String>> rows;
      try {
        rows = decodeCsv(text);
      } on CsvParseException catch (x) {
        plan.fileErrors.add('${e.key}: malformed CSV near record ${x.record} (${x.code})');
        continue;
      }
      if (rows.isEmpty) {
        plan.fileErrors.add('${e.key}: file is empty');
        continue;
      }
      final header = <String, int>{};
      for (var i = 0; i < rows.first.length; i++) {
        header[rows.first[i].trim().toLowerCase()] = i;
      }
      final missing = schema.required.where((c) => !header.containsKey(c)).toList();
      if (missing.isNotEmpty) {
        plan.fileErrors.add('${e.key}: missing column(s) ${missing.join(', ')}');
        continue;
      }
      tables[schema] = _Table(e.key, header, rows.sublist(1));
      plan.filesRead.add(e.key);
    }
    if (plan.fileErrors.isNotEmpty) return plan;

    void fail(_Table t, int row, String msg) => plan.errors.add(RowIssue(t.file, row, msg));

    // ---- DB snapshot ----
    final dbWallets = {for (final r in await db.query('wallets')) r['id'] as String: Wallet.fromMap(r)};
    final dbPeople = {for (final r in await db.query('people')) r['id'] as String: Person.fromMap(r)};
    final dbCats = {for (final r in await db.query('categories')) r['id'] as String: Category.fromMap(r)};
    final walletTxCount = <String, int>{
      for (final r in await db.rawQuery(
          'SELECT wallet_id AS id, COUNT(*) AS n FROM transactions GROUP BY wallet_id '
          'UNION ALL SELECT to_wallet_id, COUNT(*) FROM transactions '
          'WHERE to_wallet_id IS NOT NULL GROUP BY to_wallet_id'))
        r['id'] as String: r['n'] as int
    };
    final catTxCount = <String, int>{
      for (final r in await db.rawQuery(
          'SELECT category_id AS id, COUNT(*) AS n FROM transactions '
          'WHERE category_id IS NOT NULL GROUP BY category_id'))
        r['id'] as String: r['n'] as int
    };

    final effWallets = Map<String, Wallet>.of(dbWallets);
    final effPeople = Map<String, Person>.of(dbPeople);
    final effCats = Map<String, Category>.of(dbCats);

    // ---- wallets ----
    final wt = tables[CsvSchemas.wallets];
    if (wt != null) {
      final seen = <String>{};
      for (var i = 0; i < wt.rows.length; i++) {
        final r = wt.rows[i];
        final rowNo = i + 2;
        final errs = <String>[];
        final id = wt.cell(r, 'id');
        final name = wt.cell(r, 'name');
        final icon = wt.cell(r, 'icon_key');
        final color = hexToColor(wt.cell(r, 'color_hex'));
        final cur = wt.cell(r, 'currency_code').toUpperCase();
        final opening = int.tryParse(wt.cell(r, 'opening_balance'));
        final archived = _flag(wt.cell(r, 'is_archived'));
        final created = _date(wt.cell(r, 'created_at'));
        final updated = _date(wt.cell(r, 'updated_at'));
        if (id.isEmpty || id.length > 64) errs.add('id is required (max 64 chars)');
        if (!seen.add(id)) errs.add('duplicate id within file');
        if (name.isEmpty || name.length > 50) errs.add('name must be 1–50 characters');
        if (!iconCatalog.containsKey(icon)) errs.add('unknown icon_key "$icon"');
        if (color == null) errs.add('color_hex must look like #FF00796B');
        if (!currencies.containsKey(cur)) errs.add('unsupported currency_code "$cur"');
        if (opening == null || opening.abs() > maxAmount) errs.add('opening_balance must be an integer');
        if (archived == null) errs.add('is_archived must be 0 or 1');
        if (created == null || updated == null) errs.add('created_at/updated_at must be ISO 8601');
        final existing = dbWallets[id];
        if (errs.isEmpty && existing != null && existing.currencyCode != cur &&
            (walletTxCount[id] ?? 0) > 0) {
          errs.add('cannot change currency of a wallet that has transactions');
        }
        if (errs.isNotEmpty) {
          for (final m in errs) {
            fail(wt, rowNo, m);
          }
          continue;
        }
        final w = Wallet(
          id: id, name: name, iconKey: icon, colorValue: color!, currencyCode: cur,
          openingBalance: opening!, isArchived: archived!, sortOrder: existing?.sortOrder ?? 0,
          createdAt: created!, updatedAt: updated!,
        );
        if (existing == null) {
          plan.newWallets.add(w);
        } else if (existing.sameContent(w)) {
          plan.unchanged++;
        } else {
          plan.dupWallets.add(w);
        }
        effWallets[id] = w;
      }
    }

    // ---- people ----
    final pt = tables[CsvSchemas.people];
    if (pt != null) {
      final seen = <String>{};
      final names = <String, String>{
        for (final p in dbPeople.values) p.name.toLowerCase(): p.id
      };
      for (var i = 0; i < pt.rows.length; i++) {
        final r = pt.rows[i];
        final rowNo = i + 2;
        final errs = <String>[];
        final id = pt.cell(r, 'id');
        final name = pt.cell(r, 'name');
        final note = pt.cell(r, 'note');
        final archived = _flag(pt.cell(r, 'is_archived'));
        final created = _date(pt.cell(r, 'created_at'));
        final updated = _date(pt.cell(r, 'updated_at'));
        if (id.isEmpty || id.length > 64) errs.add('id is required (max 64 chars)');
        if (!seen.add(id)) errs.add('duplicate id within file');
        if (name.isEmpty || name.length > 60) errs.add('name must be 1–60 characters');
        if (note.length > 200) errs.add('note longer than 200 characters');
        if (archived == null) errs.add('is_archived must be 0 or 1');
        if (created == null || updated == null) errs.add('created_at/updated_at must be ISO 8601');
        final owner = names[name.toLowerCase()];
        if (name.isNotEmpty && owner != null && owner != id) {
          errs.add('another person already uses the name "$name"');
        }
        if (errs.isNotEmpty) {
          for (final m in errs) {
            fail(pt, rowNo, m);
          }
          continue;
        }
        names[name.toLowerCase()] = id;
        final p = Person(
          id: id, name: name, note: note.isEmpty ? null : note, isArchived: archived!,
          createdAt: created!, updatedAt: updated!,
        );
        final existing = dbPeople[id];
        if (existing == null) {
          plan.newPeople.add(p);
        } else if (existing.sameContent(p)) {
          plan.unchanged++;
        } else {
          plan.dupPeople.add(p);
        }
        effPeople[id] = p;
      }
    }

    // ---- categories (pass 1: fields; pass 2: parents + unique names) ----
    final ct = tables[CsvSchemas.categories];
    if (ct != null) {
      final seen = <String>{};
      final pending = <_Pending<Category>>[];
      for (var i = 0; i < ct.rows.length; i++) {
        final r = ct.rows[i];
        final rowNo = i + 2;
        final errs = <String>[];
        final id = ct.cell(r, 'id');
        TxType? type;
        try {
          type = TxType.parse(ct.cell(r, 'type'));
          if (!type.isCategorized) {
            errs.add('type must be income or expense');
            type = null;
          }
        } on FormatException {
          errs.add('type must be income or expense');
        }
        final name = ct.cell(r, 'name');
        final nameKey = ct.cell(r, 'name_key');
        final parentId = ct.cell(r, 'parent_id');
        final icon = ct.cell(r, 'icon_key');
        final color = hexToColor(ct.cell(r, 'color_hex'));
        final isDefault = _flag(ct.cell(r, 'is_default'));
        final archived = _flag(ct.cell(r, 'is_archived'));
        final created = _date(ct.cell(r, 'created_at'));
        final updated = _date(ct.cell(r, 'updated_at'));
        if (id.isEmpty || id.length > 64) errs.add('id is required (max 64 chars)');
        if (!seen.add(id)) errs.add('duplicate id within file');
        if (name.isEmpty || name.length > 40) errs.add('name must be 1–40 characters');
        if (!iconCatalog.containsKey(icon)) errs.add('unknown icon_key "$icon"');
        if (color == null) errs.add('color_hex must look like #FFE53935');
        if (isDefault == null || archived == null) errs.add('is_default/is_archived must be 0 or 1');
        if (created == null || updated == null) errs.add('created_at/updated_at must be ISO 8601');
        if (parentId.isNotEmpty && parentId == id) errs.add('a category cannot be its own parent');
        final existing = dbCats[id];
        if (errs.isEmpty && existing != null && existing.type != type &&
            (catTxCount[id] ?? 0) > 0) {
          errs.add('cannot change type of a category that has transactions');
        }
        if (errs.isNotEmpty) {
          for (final m in errs) {
            fail(ct, rowNo, m);
          }
          continue;
        }
        pending.add(_Pending(
          rowNo,
          Category(
            id: id, type: type!, name: name, nameKey: nameKey.isEmpty ? null : nameKey,
            parentId: parentId.isEmpty ? null : parentId,
            iconKey: icon, colorValue: color!, isDefault: isDefault!, isArchived: archived!,
            sortOrder: existing?.sortOrder ?? 100, createdAt: created!, updatedAt: updated!,
          ),
        ));
      }
      // Effective state assuming every pending row is accepted.
      for (final p in pending) {
        effCats[p.value.id] = p.value;
      }
      final accepted = <Category>[];
      // Top-level rows first, so children see their final parents.
      pending.sort((a, b) => (a.value.parentId == null ? 0 : 1) - (b.value.parentId == null ? 0 : 1));
      for (final p in pending) {
        final c = p.value;
        String? err;
        if (c.parentId != null) {
          final parent = effCats[c.parentId];
          if (parent == null) {
            err = 'parent_id "${c.parentId}" not found in database or categories.csv';
          } else if (parent.type != c.type) {
            err = 'parent category has a different type';
          } else if (parent.parentId != null) {
            err = 'parent must be a top-level category (max 2 levels)';
          } else if (effCats.values.any((x) => x.parentId == c.id)) {
            err = 'a category with sub-categories cannot become a sub-category';
          }
        }
        if (err != null) {
          fail(ct, p.row, err);
          final old = dbCats[c.id];
          if (old == null) {
            effCats.remove(c.id);
          } else {
            effCats[c.id] = old;
          }
          continue;
        }
        accepted.add(c);
      }
      // Unique name within (type, parent).
      final acceptedIds = accepted.map((c) => c.id).toSet();
      final owners = <String, String>{
        for (final c in dbCats.values.where((c) => !acceptedIds.contains(c.id)))
          '${c.type.name}|${c.parentId ?? ''}|${c.name.toLowerCase()}': c.id
      };
      final rowOf = {for (final p in pending) p.value.id: p.row};
      for (final c in accepted) {
        final key = '${c.type.name}|${c.parentId ?? ''}|${c.name.toLowerCase()}';
        final owner = owners[key];
        if (owner != null && owner != c.id) {
          fail(ct, rowOf[c.id]!, 'another ${c.type.name} category with the same parent uses this name');
          final old = dbCats[c.id];
          if (old == null) {
            effCats.remove(c.id);
          } else {
            effCats[c.id] = old;
          }
          continue;
        }
        owners[key] = c.id;
        final existing = dbCats[c.id];
        if (existing == null) {
          plan.newCategories.add(c);
        } else if (existing.sameContent(c)) {
          plan.unchanged++;
        } else {
          plan.dupCategories.add(c);
        }
      }
      plan.newCategories.sort((a, b) => (a.parentId == null ? 0 : 1) - (b.parentId == null ? 0 : 1));
    }

    // ---- transactions ----
    final tt = tables[CsvSchemas.transactions];
    if (tt != null) {
      final ids = tt.rows.map((r) => tt.cell(r, 'id')).where((s) => s.isNotEmpty).toList();
      final dbTx = <String, Tx>{};
      for (var k = 0; k < ids.length; k += 500) {
        final chunk = ids.sublist(k, k + 500 > ids.length ? ids.length : k + 500);
        final rows = await db.query('transactions',
            where: 'id IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk);
        for (final r in rows) {
          dbTx[r['id'] as String] = Tx.fromMap(r);
        }
      }
      final dbLoans = <String, Tx>{
        for (final r in await db.query('transactions', where: "type IN ('lend','borrow')"))
          r['id'] as String: Tx.fromMap(r)
      };
      final dbPayments = <Tx>[
        for (final r in await db.query('transactions', where: 'loan_id IS NOT NULL')) Tx.fromMap(r)
      ];

      final seen = <String>{};
      final parsed = <_Pending<Tx>>[];
      for (var i = 0; i < tt.rows.length; i++) {
        final r = tt.rows[i];
        final rowNo = i + 2;
        final errs = <String>[];
        final id = tt.cell(r, 'id');
        TxType? type;
        try {
          type = TxType.parse(tt.cell(r, 'type'));
        } on FormatException {
          errs.add('type must be one of ${TxType.values.map((e) => e.name).join('/')}');
        }
        final amountStr = tt.cell(r, 'amount');
        final amount = RegExp(r'^\d{1,15}$').hasMatch(amountStr) ? int.parse(amountStr) : null;
        final cur = tt.cell(r, 'currency_code').toUpperCase();
        final walletId = tt.cell(r, 'wallet_id');
        final categoryId = tt.cell(r, 'category_id');
        final toWalletId = tt.cell(r, 'to_wallet_id');
        final personId = tt.cell(r, 'person_id');
        final loanId = tt.cell(r, 'loan_id');
        final occurred = _date(tt.cell(r, 'occurred_at'));
        final note = tt.cell(r, 'note', trim: false);
        final created = _date(tt.cell(r, 'created_at'));
        final updated = _date(tt.cell(r, 'updated_at'));
        if (id.isEmpty || id.length > 64) errs.add('id is required (max 64 chars)');
        if (!seen.add(id)) errs.add('duplicate id within file');
        if (amount == null || amount <= 0 || amount > maxAmount) {
          errs.add('amount must be a positive whole number without separators');
        }
        if (occurred == null) errs.add('occurred_at must be ISO 8601, e.g. 2026-09-03T07:45:00+07:00');
        if (created == null || updated == null) errs.add('created_at/updated_at must be ISO 8601');
        if (note.length > 500) errs.add('note longer than 500 characters');
        final w = effWallets[walletId];
        if (w == null) errs.add('wallet_id "$walletId" not found in database or wallets.csv');
        if (w != null && w.currencyCode != cur) {
          errs.add('currency_code $cur does not match wallet currency ${w.currencyCode}');
        }
        if (type != null) {
          // Columns that must be filled / empty for each type.
          bool need(String col, String v, bool required) {
            if (required && v.isEmpty) {
              errs.add('$col is required for type ${type!.name}');
              return false;
            }
            if (!required && v.isNotEmpty) {
              errs.add('$col must be empty for type ${type!.name}');
              return false;
            }
            return required;
          }

          if (need('category_id', categoryId, type.isCategorized)) {
            final c = effCats[categoryId];
            if (c == null) {
              errs.add('category_id "$categoryId" not found in database or categories.csv');
            } else if (c.type != type) {
              errs.add('transaction type does not match category type');
            }
          }
          if (need('to_wallet_id', toWalletId, type == TxType.transfer)) {
            final tw = effWallets[toWalletId];
            if (tw == null) {
              errs.add('to_wallet_id "$toWalletId" not found in database or wallets.csv');
            } else if (toWalletId == walletId) {
              errs.add('to_wallet_id must differ from wallet_id');
            } else if (w != null && tw.currencyCode != w.currencyCode) {
              errs.add('transfer wallets must use the same currency');
            }
          }
          if (need('person_id', personId, type.isDebt) && effPeople[personId] == null) {
            errs.add('person_id "$personId" not found in database or people.csv');
          }
          need('loan_id', loanId, type.isPayment);
          // Changing a DB loan that already has DB repayments.
          final old = dbLoans[id];
          if (old != null && type != old.type &&
              dbPayments.any((p) => p.loanId == id && !ids.contains(p.id))) {
            errs.add('cannot change type of a loan that already has repayments');
          }
        }
        if (errs.isNotEmpty) {
          for (final m in errs) {
            fail(tt, rowNo, m);
          }
          continue;
        }
        parsed.add(_Pending(
          rowNo,
          Tx(
            id: id, type: type!, amount: amount!, walletId: walletId,
            categoryId: categoryId.isEmpty ? null : categoryId,
            toWalletId: toWalletId.isEmpty ? null : toWalletId,
            personId: personId.isEmpty ? null : personId,
            loanId: loanId.isEmpty ? null : loanId,
            occurredAt: occurred!, note: note.trim().isEmpty ? null : note.trim(),
            createdAt: created!, updatedAt: updated!,
          ),
        ));
      }

      // Loans available to repayments: DB loans overridden by file loans.
      final effLoans = Map<String, Tx>.of(dbLoans);
      for (final p in parsed) {
        if (p.value.type.isLoan) effLoans[p.value.id] = p.value;
        if (!p.value.type.isLoan) effLoans.remove(p.value.id); // a DB loan replaced by a non-loan
      }
      final valid = <_Pending<Tx>>[];
      for (final p in parsed) {
        final t = p.value;
        if (t.type.isPayment) {
          final loan = effLoans[t.loanId];
          if (loan == null) {
            fail(tt, p.row, 'loan_id "${t.loanId}" not found (must be a lend/borrow row)');
            continue;
          }
          if (loan.type.paymentType != t.type) {
            fail(tt, p.row, '${t.type.name} must link to a ${t.type == TxType.collect ? 'lend' : 'borrow'} row');
            continue;
          }
          if (loan.personId != t.personId) {
            fail(tt, p.row, 'person_id must match the loan\'s person');
            continue;
          }
        }
        valid.add(p);
      }

      // Repayments must not exceed the loan amount.
      final filePayIds = valid.where((p) => p.value.type.isPayment).map((p) => p.value.id).toSet();
      final rejected = <String>{};
      for (final loan in effLoans.values) {
        final dbPaid = dbPayments
            .where((x) => x.loanId == loan.id && !filePayIds.contains(x.id) && !ids.contains(x.id))
            .fold<int>(0, (a, x) => a + x.amount);
        final filePays = valid.where((p) => p.value.loanId == loan.id).toList();
        final filePaid = filePays.fold<int>(0, (a, p) => a + p.value.amount);
        if (dbPaid + filePaid <= loan.amount) continue;
        for (final p in filePays) {
          fail(tt, p.row, 'repayments exceed the remaining amount of loan ${loan.id}');
          rejected.add(p.value.id);
        }
        if (dbPaid > loan.amount) {
          final lp = valid.where((p) => p.value.id == loan.id);
          for (final p in lp) {
            fail(tt, p.row, 'amount is below what has already been repaid');
            rejected.add(p.value.id);
          }
        }
      }

      for (final p in valid) {
        final t = p.value;
        if (rejected.contains(t.id)) continue;
        if (t.type.isPayment && rejected.contains(t.loanId)) {
          fail(tt, p.row, 'its loan row failed validation');
          continue;
        }
        final existing = dbTx[t.id];
        if (existing == null) {
          plan.newTxs.add(t);
        } else if (existing.sameContent(t)) {
          plan.unchanged++;
        } else {
          plan.dupTxs.add(t);
        }
      }
      // Loans before repayments (foreign key order).
      int rank(Tx t) => t.type.isPayment ? 1 : 0;
      plan.newTxs.sort((a, b) => rank(a) - rank(b));
      plan.dupTxs.sort((a, b) => rank(a) - rank(b));
    }
    return plan;
  }

  /// All-or-nothing write. Any exception rolls the whole import back.
  Future<ImportResult> commit(ImportPlan plan, DuplicateMode mode) async {
    final dupSkipped = mode == DuplicateMode.replace ? 0 : plan.dupCount;
    if (mode == DuplicateMode.reportOnly) {
      return ImportResult(
        imported: 0, replaced: 0, duplicates: plan.dupCount,
        skipped: plan.unchanged + plan.dupCount + plan.newCount, failed: plan.failedRows,
        dryRun: true,
      );
    }
    if (plan.fileErrors.isNotEmpty) throw const AppException('importInvalid');
    final replace = mode == DuplicateMode.replace;
    await db.transaction((txn) async {
      Future<void> put(String table, List<Map<String, Object?>> news,
          List<({String id, Map<String, Object?> map})> dups) async {
        for (final m in news) {
          await txn.insert(table, m);
        }
        if (replace) {
          for (final d in dups) {
            await txn.update(table, d.map, where: 'id = ?', whereArgs: [d.id]);
          }
        }
      }

      await put('wallets', [for (final x in plan.newWallets) x.toMap()],
          [for (final x in plan.dupWallets) (id: x.id, map: x.toMap())]);
      await put('people', [for (final x in plan.newPeople) x.toMap()],
          [for (final x in plan.dupPeople) (id: x.id, map: x.toMap())]);
      await put('categories', [for (final x in plan.newCategories) x.toMap()],
          [for (final x in plan.dupCategories) (id: x.id, map: x.toMap())]);
      // Non-repayment rows first, then repayments.
      for (final pass in [false, true]) {
        await put(
          'transactions',
          [for (final x in plan.newTxs.where((t) => t.type.isPayment == pass)) x.toMap()],
          [for (final x in plan.dupTxs.where((t) => t.type.isPayment == pass)) (id: x.id, map: x.toMap())],
        );
      }
    });
    return ImportResult(
      imported: plan.newCount,
      replaced: replace ? plan.dupCount : 0,
      duplicates: plan.dupCount,
      skipped: plan.unchanged + dupSkipped,
      failed: plan.failedRows,
    );
  }
}

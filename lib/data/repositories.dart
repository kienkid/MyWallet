import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/money.dart';
import '../core/util.dart';

typedef Clock = DateTime Function();

String validName(String raw, int max) {
  final n = raw.trim();
  if (n.isEmpty) throw const AppException('nameRequired');
  if (n.length > max) throw const AppException('nameTooLong');
  return n;
}

String? cleanNote(String? note, {int max = 500}) {
  final n = note?.trim();
  if (n == null || n.isEmpty) return null;
  if (n.length > max) throw const AppException('noteTooLong');
  return n;
}

void checkAmount(int amount) {
  if (amount <= 0 || amount > maxAmount) throw const AppException('amountInvalid');
}

Future<int> countRows(DatabaseExecutor db, String sql, List<Object?> args) async =>
    Sqflite.firstIntValue(await db.rawQuery(sql, args)) ?? 0;

/// Loads a wallet and checks it can receive a new/edited transaction.
/// An archived wallet is only accepted if the row already used it.
Future<Wallet> loadUsableWallet(DatabaseExecutor db, String id, {Set<String> previous = const {}}) async {
  final w = await db.query('wallets', where: 'id = ?', whereArgs: [id], limit: 1);
  if (w.isEmpty) throw const AppException('walletMissing');
  final wallet = Wallet.fromMap(w.first);
  if (wallet.isArchived && !previous.contains(id)) throw const AppException('walletArchived');
  return wallet;
}

/// SQL fragment: wallet balance = opening + signed movements + incoming transfers.
const walletBalanceSql = '''
  w.opening_balance
  + COALESCE((SELECT SUM(CASE WHEN t.type IN ('income','borrow','collect')
                              THEN t.amount ELSE -t.amount END)
              FROM transactions t WHERE t.wallet_id = w.id), 0)
  + COALESCE((SELECT SUM(t.amount) FROM transactions t WHERE t.to_wallet_id = w.id), 0)''';

// =============================== WALLETS ===================================
class WalletRepository {
  WalletRepository(this.db, {Clock? clock, Uuid? uuid})
      : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();
  final Database db;
  final Clock _clock;
  final Uuid _uuid;

  /// Balances are computed on read (never stored), so edits/deletes can't corrupt them.
  Future<List<WalletWithBalance>> list({bool includeArchived = false}) async {
    final rows = await db.rawQuery('''
      SELECT w.*,
        (SELECT COUNT(*) FROM transactions t
          WHERE t.wallet_id = w.id OR t.to_wallet_id = w.id) AS tx_count,
        $walletBalanceSql AS balance
      FROM wallets w
      ${includeArchived ? '' : 'WHERE w.is_archived = 0'}
      ORDER BY w.is_archived, w.sort_order, w.created_at''');
    return rows
        .map((r) => WalletWithBalance(Wallet.fromMap(r), r['balance'] as int, r['tx_count'] as int))
        .toList();
  }

  Future<Wallet?> findById(String id) async {
    final r = await db.query('wallets', where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : Wallet.fromMap(r.first);
  }

  Future<int> txCount(String id) => countRows(
      db, 'SELECT COUNT(*) FROM transactions WHERE wallet_id = ? OR to_wallet_id = ?', [id, id]);

  void _checkOpening(int v) {
    if (v.abs() > maxAmount) throw const AppException('amountInvalid');
  }

  Future<Wallet> create({
    required String name,
    required String iconKey,
    required int colorValue,
    String currencyCode = defaultCurrency,
    int openingBalance = 0,
  }) async {
    final n = validName(name, 50);
    _checkOpening(openingBalance);
    if (!currencies.containsKey(currencyCode)) throw const AppException('currencyInvalid');
    final now = _clock();
    final w = Wallet(
      id: _uuid.v4(),
      name: n,
      iconKey: iconKey,
      colorValue: colorValue,
      currencyCode: currencyCode,
      openingBalance: openingBalance,
      isArchived: false,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('wallets', w.toMap());
    return w;
  }

  Future<void> update(Wallet w) async {
    final n = validName(w.name, 50);
    _checkOpening(w.openingBalance);
    final existing = await findById(w.id);
    if (existing == null) throw const AppException('notFound');
    if (existing.currencyCode != w.currencyCode && await txCount(w.id) > 0) {
      throw const AppException('currencyLocked');
    }
    await db.update('wallets', w.copyWith(name: n, updatedAt: _clock()).toMap(),
        where: 'id = ?', whereArgs: [w.id]);
  }

  Future<void> setArchived(String id, bool archived) async {
    await db.update('wallets',
        {'is_archived': archived ? 1 : 0, 'updated_at': _clock().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Only allowed when nothing references the wallet.
  Future<void> delete(String id) async {
    if (await txCount(id) > 0) throw const AppException('walletInUse');
    await db.delete('wallets', where: 'id = ?', whereArgs: [id]);
  }

  /// Moves every movement of [fromId] to [toId], then deletes [fromId] – atomically.
  /// Transfers between the two wallets become internal and are removed
  /// (balance-neutral for the combined total).
  Future<void> reassignAndDelete({required String fromId, required String toId}) async {
    if (fromId == toId) throw const AppException('sameWallet');
    await db.transaction((txn) async {
      final rows = await txn.query('wallets', where: 'id IN (?, ?)', whereArgs: [fromId, toId]);
      if (rows.length != 2) throw const AppException('notFound');
      final ws = {for (final r in rows) r['id'] as String: Wallet.fromMap(r)};
      if (ws[fromId]!.currencyCode != ws[toId]!.currencyCode) {
        throw const AppException('currencyMismatch');
      }
      final now = _clock().millisecondsSinceEpoch;
      await txn.delete('transactions',
          where: "type = 'transfer' AND ((wallet_id = ? AND to_wallet_id = ?) "
              'OR (wallet_id = ? AND to_wallet_id = ?))',
          whereArgs: [fromId, toId, toId, fromId]);
      await txn.update('transactions', {'wallet_id': toId, 'updated_at': now},
          where: 'wallet_id = ?', whereArgs: [fromId]);
      await txn.update('transactions', {'to_wallet_id': toId, 'updated_at': now},
          where: 'to_wallet_id = ?', whereArgs: [fromId]);
      await txn.delete('wallets', where: 'id = ?', whereArgs: [fromId]);
    });
  }
}

// ============================== CATEGORIES =================================
class CategoryRepository {
  CategoryRepository(this.db, {Clock? clock, Uuid? uuid})
      : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();
  final Database db;
  final Clock _clock;
  final Uuid _uuid;

  Future<List<Category>> list({TxType? type, bool includeArchived = false}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (type != null) {
      where.add('type = ?');
      args.add(type.name);
    }
    if (!includeArchived) where.add('is_archived = 0');
    final rows = await db.query('categories',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args,
        orderBy: 'is_archived, sort_order, created_at');
    return rows.map(Category.fromMap).toList();
  }

  Future<Category?> findById(String id) async {
    final r = await db.query('categories', where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : Category.fromMap(r.first);
  }

  Future<int> txCount(String id) =>
      countRows(db, 'SELECT COUNT(*) FROM transactions WHERE category_id = ?', [id]);

  Future<int> childCount(String id) =>
      countRows(db, 'SELECT COUNT(*) FROM categories WHERE parent_id = ?', [id]);

  /// Max 2 levels: parent must be top-level, same type, not itself,
  /// and a category that has children cannot become a child.
  Future<void> _checkParent(TxType type, String? parentId, {String? selfId}) async {
    if (parentId == null) return;
    if (parentId == selfId) throw const AppException('parentInvalid');
    final p = await findById(parentId);
    if (p == null) throw const AppException('categoryMissing');
    if (p.type != type || p.parentId != null) throw const AppException('parentInvalid');
    if (selfId != null && await childCount(selfId) > 0) {
      throw const AppException('hasChildren');
    }
  }

  /// Names are unique within the same parent and type.
  Future<void> _checkUniqueName(TxType type, String? parentId, String name, {String? exceptId}) async {
    final all = await list(type: type, includeArchived: true);
    final lower = name.toLowerCase();
    if (all.any((c) => c.id != exceptId && c.parentId == parentId && c.name.toLowerCase() == lower)) {
      throw const AppException('nameDuplicate');
    }
  }

  Future<Category> create({
    required TxType type,
    required String name,
    required String iconKey,
    required int colorValue,
    String? parentId,
  }) async {
    if (!type.isCategorized) throw const AppException('parentInvalid');
    final n = validName(name, 40);
    await _checkParent(type, parentId);
    await _checkUniqueName(type, parentId, n);
    final now = _clock();
    final c = Category(
      id: _uuid.v4(),
      type: type,
      name: n,
      parentId: parentId,
      iconKey: iconKey,
      colorValue: colorValue,
      isDefault: false,
      isArchived: false,
      sortOrder: 100,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('categories', c.toMap());
    return c;
  }

  /// Renaming a default category drops its translation key (user text wins).
  Future<void> update(Category c, {bool renamed = false}) async {
    final existing = await findById(c.id);
    if (existing == null) throw const AppException('notFound');
    if (existing.type != c.type) throw const AppException('parentInvalid');
    final n = validName(c.name, 40);
    if (c.parentId != existing.parentId) await _checkParent(c.type, c.parentId, selfId: c.id);
    await _checkUniqueName(c.type, c.parentId, n, exceptId: c.id);
    final updated = c.copyWith(name: n, updatedAt: _clock(), clearNameKey: renamed);
    await db.update('categories', updated.toMap(), where: 'id = ?', whereArgs: [c.id]);
  }

  /// Archiving/restoring a parent also archives/restores its children.
  Future<void> setArchived(String id, bool archived) async {
    final c = await findById(id);
    if (c == null) throw const AppException('notFound');
    if (!archived && c.parentId != null) {
      final p = await findById(c.parentId!);
      if (p != null && p.isArchived) throw const AppException('parentArchived');
    }
    final values = {'is_archived': archived ? 1 : 0, 'updated_at': _clock().millisecondsSinceEpoch};
    await db.transaction((txn) async {
      await txn.update('categories', values, where: 'id = ?', whereArgs: [id]);
      await txn.update('categories', values, where: 'parent_id = ?', whereArgs: [id]);
    });
  }

  Future<void> delete(String id) async {
    final c = await findById(id);
    if (c == null) return;
    if (c.isDefault) throw const AppException('defaultCannotDelete');
    if (await childCount(id) > 0) throw const AppException('hasChildren');
    if (await txCount(id) > 0) throw const AppException('categoryInUse');
    await db.delete('categories', where: 'id = ?', whereArgs: [id]);
  }
}

// ============================= TRANSACTIONS ================================
class TransactionRepository {
  TransactionRepository(this.db, {Clock? clock, Uuid? uuid})
      : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();
  final Database db;
  final Clock _clock;
  final Uuid _uuid;

  static const _select = '''
    SELECT t.*, w.name AS w_name, w.currency_code AS w_currency,
      tw.name AS tw_name, pe.name AS p_name,
      c.id AS c_id, c.type AS c_type, c.name AS c_name, c.name_key AS c_name_key,
      c.parent_id AS c_parent_id, c.icon_key AS c_icon_key, c.color_value AS c_color_value,
      c.is_default AS c_is_default, c.is_archived AS c_is_archived, c.sort_order AS c_sort_order,
      c.created_at AS c_created_at, c.updated_at AS c_updated_at,
      pc.name AS pc_name, pc.name_key AS pc_name_key
    FROM transactions t
    JOIN wallets w ON w.id = t.wallet_id
    LEFT JOIN wallets tw ON tw.id = t.to_wallet_id
    LEFT JOIN people pe ON pe.id = t.person_id
    LEFT JOIN categories c ON c.id = t.category_id
    LEFT JOIN categories pc ON pc.id = c.parent_id''';

  TxView _view(Map<String, Object?> r) => TxView(
        tx: Tx.fromMap(r),
        walletName: r['w_name'] as String,
        currencyCode: r['w_currency'] as String,
        category: r['c_id'] == null ? null : Category.fromMap(r, p: 'c_'),
        parentName: r['pc_name'] as String?,
        parentNameKey: r['pc_name_key'] as String?,
        toWalletName: r['tw_name'] as String?,
        personName: r['p_name'] as String?,
      );

  /// Structured filters run in SQL; free-text search runs in the provider
  /// (it needs localized category names and accent-insensitive matching).
  Future<List<TxView>> query(TxFilter f, {int? limit}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (f.group != null) {
      final types = f.group!.types;
      where.add('t.type IN (${List.filled(types.length, '?').join(',')})');
      args.addAll(types.map((e) => e.name));
    }
    if (f.walletId != null) {
      where.add('(t.wallet_id = ? OR t.to_wallet_id = ?)');
      args.addAll([f.walletId, f.walletId]);
    }
    if (f.categoryId != null) {
      where.add('(t.category_id = ? OR c.parent_id = ?)');
      args.addAll([f.categoryId, f.categoryId]);
    }
    if (f.from != null) {
      where.add('t.occurred_at >= ?');
      args.add(f.from!.millisecondsSinceEpoch);
    }
    if (f.to != null) {
      where.add('t.occurred_at < ?');
      args.add(f.to!.millisecondsSinceEpoch);
    }
    final sql = StringBuffer(_select);
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(' ORDER BY t.occurred_at DESC, t.created_at DESC');
    if (limit != null) sql.write(' LIMIT $limit');
    final rows = await db.rawQuery(sql.toString(), args);
    return rows.map(_view).toList();
  }

  Future<Tx?> findById(String id) async {
    final r = await db.query('transactions', where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : Tx.fromMap(r.first);
  }

  // ---- income / expense ----
  Future<void> _validateCategorized(Tx t, {Tx? old}) async {
    if (!t.type.isCategorized) throw const AppException('typeInvalid');
    checkAmount(t.amount);
    await loadUsableWallet(db, t.walletId, previous: {if (old != null) old.walletId});
    if (t.categoryId == null) throw const AppException('categoryRequired');
    final c = await db.query('categories', where: 'id = ?', whereArgs: [t.categoryId], limit: 1);
    if (c.isEmpty) throw const AppException('categoryMissing');
    if (c.first['type'] != t.type.name) throw const AppException('categoryTypeMismatch');
  }

  Future<Tx> create({
    required TxType type,
    required int amount,
    required String walletId,
    required String categoryId,
    required DateTime occurredAt,
    String? note,
  }) async {
    final now = _clock();
    final tx = Tx(
      id: _uuid.v4(),
      type: type,
      amount: amount,
      walletId: walletId,
      categoryId: categoryId,
      occurredAt: occurredAt,
      note: cleanNote(note),
      createdAt: now,
      updatedAt: now,
    );
    await _validateCategorized(tx);
    await db.insert('transactions', tx.toMap());
    return tx;
  }

  Future<void> update(Tx tx) async {
    final old = await findById(tx.id);
    if (old == null) throw const AppException('notFound');
    if (!old.type.isCategorized) throw const AppException('typeInvalid');
    final updated = tx.copyWith(
      note: cleanNote(tx.note),
      toWalletId: null,
      personId: null,
      loanId: null,
      createdAt: old.createdAt,
      updatedAt: _clock(),
    );
    await _validateCategorized(updated, old: old);
    await db.update('transactions', updated.toMap(), where: 'id = ?', whereArgs: [tx.id]);
  }

  // ---- transfers (never counted as income/expense) ----
  Future<void> _validateTransfer(Tx t, {Tx? old}) async {
    checkAmount(t.amount);
    if (t.toWalletId == null || t.toWalletId == t.walletId) {
      throw const AppException('sameWallet');
    }
    final prev = {if (old != null) old.walletId, if (old?.toWalletId != null) old!.toWalletId!};
    final a = await loadUsableWallet(db, t.walletId, previous: prev);
    final b = await loadUsableWallet(db, t.toWalletId!, previous: prev);
    if (a.currencyCode != b.currencyCode) throw const AppException('currencyMismatch');
  }

  Future<Tx> createTransfer({
    required String fromWalletId,
    required String toWalletId,
    required int amount,
    required DateTime occurredAt,
    String? note,
  }) async {
    final now = _clock();
    final tx = Tx(
      id: _uuid.v4(),
      type: TxType.transfer,
      amount: amount,
      walletId: fromWalletId,
      toWalletId: toWalletId,
      occurredAt: occurredAt,
      note: cleanNote(note),
      createdAt: now,
      updatedAt: now,
    );
    await _validateTransfer(tx);
    await db.insert('transactions', tx.toMap());
    return tx;
  }

  Future<void> updateTransfer(Tx tx) async {
    final old = await findById(tx.id);
    if (old == null) throw const AppException('notFound');
    if (old.type != TxType.transfer) throw const AppException('typeInvalid');
    final updated = tx.copyWith(
      type: TxType.transfer,
      note: cleanNote(tx.note),
      categoryId: null,
      personId: null,
      loanId: null,
      createdAt: old.createdAt,
      updatedAt: _clock(),
    );
    await _validateTransfer(updated, old: old);
    await db.update('transactions', updated.toMap(), where: 'id = ?', whereArgs: [tx.id]);
  }

  /// Deletes any single movement. A loan with repayments must be deleted via
  /// DebtRepository.deleteLoan(cascade: true).
  Future<void> delete(String id) async {
    final n = await countRows(db, 'SELECT COUNT(*) FROM transactions WHERE loan_id = ?', [id]);
    if (n > 0) throw const AppException('loanHasPayments');
    await db.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }
}

// ================================ REPORTS ==================================
/// Reports only ever read income/expense rows: transfers and loans are
/// excluded by design.
class ReportRepository {
  ReportRepository(this.db);
  final Database db;

  ({String where, List<Object?> args}) _where(ReportFilter f, {DateTime? from, DateTime? to}) {
    final w = <String>[
      "t.type IN ('income','expense')",
      't.occurred_at >= ?',
      't.occurred_at < ?',
      'w.currency_code = ?',
    ];
    final a = <Object?>[
      (from ?? f.from).millisecondsSinceEpoch,
      (to ?? f.to).millisecondsSinceEpoch,
      f.currencyCode,
    ];
    if (f.walletId != null) {
      w.add('t.wallet_id = ?');
      a.add(f.walletId);
    }
    if (f.categoryId != null) {
      w.add('(t.category_id = ? OR t.category_id IN (SELECT id FROM categories WHERE parent_id = ?))');
      a.addAll([f.categoryId, f.categoryId]);
    }
    return (where: w.join(' AND '), args: a);
  }

  Future<({int income, int expense})> totals(ReportFilter f, {DateTime? from, DateTime? to}) async {
    final q = _where(f, from: from, to: to);
    final r = await db.rawQuery('''
      SELECT COALESCE(SUM(CASE WHEN t.type = 'income'  THEN t.amount END), 0) AS inc,
             COALESCE(SUM(CASE WHEN t.type = 'expense' THEN t.amount END), 0) AS exp
      FROM transactions t JOIN wallets w ON w.id = t.wallet_id
      WHERE ${q.where}''', q.args);
    return (income: r.first['inc'] as int, expense: r.first['exp'] as int);
  }

  /// Without [parentId]: totals grouped by top-level category (children roll up).
  /// With [parentId]: breakdown of that parent – itself + each child.
  Future<List<CategorySlice>> byCategory(ReportFilter f, TxType type, {String? parentId}) async {
    final q = _where(f);
    final List<Map<String, Object?>> rows;
    if (parentId == null) {
      rows = await db.rawQuery('''
        SELECT g.*, SUM(t.amount) AS total, COUNT(*) AS n
        FROM transactions t
        JOIN categories c ON c.id = t.category_id
        JOIN categories g ON g.id = COALESCE(c.parent_id, c.id)
        JOIN wallets w ON w.id = t.wallet_id
        WHERE ${q.where} AND t.type = ?
        GROUP BY g.id
        ORDER BY total DESC''', [...q.args, type.name]);
    } else {
      rows = await db.rawQuery('''
        SELECT c.*, SUM(t.amount) AS total, COUNT(*) AS n
        FROM transactions t
        JOIN categories c ON c.id = t.category_id
        JOIN wallets w ON w.id = t.wallet_id
        WHERE ${q.where} AND t.type = ? AND (c.id = ? OR c.parent_id = ?)
        GROUP BY c.id
        ORDER BY total DESC''', [...q.args, type.name, parentId, parentId]);
    }
    return rows
        .map((r) => CategorySlice(Category.fromMap(r), r['total'] as int, r['n'] as int))
        .toList();
  }

  /// One bucket per month inside the range (max 12 most recent); empty months = 0.
  Future<List<MonthlyTotal>> monthly(ReportFilter f) async {
    final months = <DateTime>[];
    var m = startOfMonth(f.from);
    while (m.isBefore(f.to)) {
      months.add(m);
      m = addMonths(m, 1);
    }
    final recent = months.length > 12 ? months.sublist(months.length - 12) : months;
    final out = <MonthlyTotal>[];
    for (final start in recent) {
      final end = addMonths(start, 1);
      final from = start.isBefore(f.from) ? f.from : start;
      final to = end.isAfter(f.to) ? f.to : end;
      final t = await totals(f, from: from, to: to);
      out.add(MonthlyTotal(start, t.income, t.expense));
    }
    return out;
  }

  Future<List<WalletSpending>> byWallet(ReportFilter f) async {
    final q = _where(f);
    final rows = await db.rawQuery('''
      SELECT w.id, w.name,
        COALESCE(SUM(CASE WHEN t.type = 'income'  THEN t.amount END), 0) AS inc,
        COALESCE(SUM(CASE WHEN t.type = 'expense' THEN t.amount END), 0) AS exp
      FROM transactions t JOIN wallets w ON w.id = t.wallet_id
      WHERE ${q.where}
      GROUP BY w.id
      ORDER BY exp DESC''', q.args);
    return rows
        .map((r) => WalletSpending(
            r['id'] as String, r['name'] as String, r['inc'] as int, r['exp'] as int))
        .toList();
  }
}

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/util.dart';
import 'repositories.dart';

// ================================ PEOPLE ===================================
class PeopleRepository {
  PeopleRepository(this.db, {Clock? clock, Uuid? uuid})
      : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();
  final Database db;
  final Clock _clock;
  final Uuid _uuid;

  Future<List<Person>> list({bool includeArchived = false}) async {
    final rows = await db.query('people',
        where: includeArchived ? null : 'is_archived = 0',
        orderBy: 'is_archived, name COLLATE NOCASE');
    return rows.map(Person.fromMap).toList();
  }

  Future<Person?> findById(String id) async {
    final r = await db.query('people', where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : Person.fromMap(r.first);
  }

  Future<void> _checkUnique(String name, {String? exceptId}) async {
    final n = await countRows(
        db,
        'SELECT COUNT(*) FROM people WHERE name = ? COLLATE NOCASE AND id <> ?',
        [name, exceptId ?? '']);
    if (n > 0) throw const AppException('personDuplicate');
  }

  Future<Person> create({required String name, String? note}) async {
    final n = validName(name, 60);
    await _checkUnique(n);
    final now = _clock();
    final p = Person(
      id: _uuid.v4(),
      name: n,
      note: cleanNote(note, max: 200),
      isArchived: false,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('people', p.toMap());
    return p;
  }

  Future<void> update(Person p) async {
    final n = validName(p.name, 60);
    await _checkUnique(n, exceptId: p.id);
    await db.update(
        'people',
        {'name': n, 'note': cleanNote(p.note, max: 200), 'updated_at': _clock().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [p.id]);
  }

  Future<void> setArchived(String id, bool archived) async {
    await db.update('people',
        {'is_archived': archived ? 1 : 0, 'updated_at': _clock().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(String id) async {
    final n = await countRows(db, 'SELECT COUNT(*) FROM transactions WHERE person_id = ?', [id]);
    if (n > 0) throw const AppException('personInUse');
    await db.delete('people', where: 'id = ?', whereArgs: [id]);
  }
}

// ================================= DEBTS ===================================
/// Loans are `lend`/`borrow` rows; repayments are `collect`/`repay` rows linked
/// by `loan_id`. Remaining = loan amount − Σ repayments (computed, never stored).
class DebtRepository {
  DebtRepository(this.db, {Clock? clock, Uuid? uuid})
      : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();
  final Database db;
  final Clock _clock;
  final Uuid _uuid;

  Future<List<Loan>> listLoans() async {
    final loans = await db.rawQuery('''
      SELECT t.*, p.name AS p_name, w.name AS w_name, w.currency_code AS w_currency
      FROM transactions t
      JOIN people p ON p.id = t.person_id
      JOIN wallets w ON w.id = t.wallet_id
      WHERE t.type IN ('lend','borrow')
      ORDER BY t.occurred_at DESC, t.created_at DESC''');
    final pays = await db.rawQuery('''
      SELECT t.*, w.name AS w_name
      FROM transactions t JOIN wallets w ON w.id = t.wallet_id
      WHERE t.type IN ('collect','repay')
      ORDER BY t.occurred_at, t.created_at''');
    final byLoan = <String, List<PaymentView>>{};
    for (final r in pays) {
      final tx = Tx.fromMap(r);
      byLoan.putIfAbsent(tx.loanId!, () => []).add(PaymentView(tx, r['w_name'] as String));
    }
    return loans.map((r) {
      final tx = Tx.fromMap(r);
      return Loan(
        tx: tx,
        personName: r['p_name'] as String,
        walletName: r['w_name'] as String,
        currencyCode: r['w_currency'] as String,
        payments: byLoan[tx.id] ?? const [],
      );
    }).toList();
  }

  Future<int> _paid(DatabaseExecutor ex, String loanId, {String? exceptPaymentId}) async {
    final r = await ex.rawQuery(
        'SELECT COALESCE(SUM(amount), 0) AS s FROM transactions WHERE loan_id = ? AND id <> ?',
        [loanId, exceptPaymentId ?? '']);
    return r.first['s'] as int;
  }

  Future<Tx> _loadLoan(DatabaseExecutor ex, String id) async {
    final r = await ex.query('transactions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (r.isEmpty) throw const AppException('notFound');
    final t = Tx.fromMap(r.first);
    if (!t.type.isLoan) throw const AppException('typeInvalid');
    return t;
  }

  Future<void> _checkPerson(DatabaseExecutor ex, String personId) async {
    final n = await countRows(ex, 'SELECT COUNT(*) FROM people WHERE id = ?', [personId]);
    if (n == 0) throw const AppException('personMissing');
  }

  // ---- loans ----
  Future<Tx> createLoan({
    required TxType type, // lend | borrow
    required String personId,
    required String walletId,
    required int amount,
    required DateTime occurredAt,
    String? note,
  }) async {
    if (!type.isLoan) throw const AppException('typeInvalid');
    checkAmount(amount);
    await _checkPerson(db, personId);
    await loadUsableWallet(db, walletId);
    final now = _clock();
    final tx = Tx(
      id: _uuid.v4(),
      type: type,
      amount: amount,
      walletId: walletId,
      personId: personId,
      occurredAt: occurredAt,
      note: cleanNote(note),
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('transactions', tx.toMap());
    return tx;
  }

  /// Amount can't go below what's already repaid. Lend/borrow can only be
  /// switched while there are no repayments. Changing the person also moves
  /// the repayments to that person.
  Future<void> updateLoan(Tx loan) async {
    if (!loan.type.isLoan) throw const AppException('typeInvalid');
    checkAmount(loan.amount);
    await db.transaction((txn) async {
      final old = await _loadLoan(txn, loan.id);
      final paid = await _paid(txn, loan.id);
      if (loan.amount < paid) throw const AppException('loanBelowPaid');
      if (loan.type != old.type && paid > 0) throw const AppException('loanTypeLocked');
      await _checkPerson(txn, loan.personId!);
      await loadUsableWallet(txn, loan.walletId, previous: {old.walletId});
      final now = _clock().millisecondsSinceEpoch;
      final updated = loan.copyWith(
        note: cleanNote(loan.note),
        categoryId: null,
        toWalletId: null,
        loanId: null,
        createdAt: old.createdAt,
        updatedAt: _clock(),
      );
      await txn.update('transactions', updated.toMap(), where: 'id = ?', whereArgs: [loan.id]);
      if (loan.personId != old.personId) {
        await txn.update('transactions', {'person_id': loan.personId, 'updated_at': now},
            where: 'loan_id = ?', whereArgs: [loan.id]);
      }
    });
  }

  /// Without [cascade], a loan that has repayments cannot be deleted.
  Future<void> deleteLoan(String id, {bool cascade = false}) async {
    await db.transaction((txn) async {
      await _loadLoan(txn, id);
      final n = await countRows(txn, 'SELECT COUNT(*) FROM transactions WHERE loan_id = ?', [id]);
      if (n > 0 && !cascade) throw const AppException('loanHasPayments');
      await txn.delete('transactions', where: 'loan_id = ?', whereArgs: [id]);
      await txn.delete('transactions', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---- repayments ----
  /// Type is derived from the loan (lend -> collect, borrow -> repay).
  /// Overpayment is blocked. The wallet may differ from the loan's wallet.
  Future<Tx> createPayment({
    required String loanId,
    required String walletId,
    required int amount,
    required DateTime occurredAt,
    String? note,
  }) async {
    checkAmount(amount);
    final cleaned = cleanNote(note);
    late Tx tx;
    await db.transaction((txn) async {
      final loan = await _loadLoan(txn, loanId);
      final paid = await _paid(txn, loanId);
      if (amount > loan.amount - paid) throw const AppException('overpayment');
      await loadUsableWallet(txn, walletId);
      final now = _clock();
      tx = Tx(
        id: _uuid.v4(),
        type: loan.type.paymentType,
        amount: amount,
        walletId: walletId,
        personId: loan.personId,
        loanId: loanId,
        occurredAt: occurredAt,
        note: cleaned,
        createdAt: now,
        updatedAt: now,
      );
      await txn.insert('transactions', tx.toMap());
    });
    return tx;
  }

  Future<void> updatePayment(Tx payment) async {
    checkAmount(payment.amount);
    final cleaned = cleanNote(payment.note);
    await db.transaction((txn) async {
      final r = await txn.query('transactions', where: 'id = ?', whereArgs: [payment.id], limit: 1);
      if (r.isEmpty) throw const AppException('notFound');
      final old = Tx.fromMap(r.first);
      if (!old.type.isPayment) throw const AppException('typeInvalid');
      final loan = await _loadLoan(txn, old.loanId!);
      final paidOthers = await _paid(txn, loan.id, exceptPaymentId: old.id);
      if (payment.amount > loan.amount - paidOthers) throw const AppException('overpayment');
      await loadUsableWallet(txn, payment.walletId, previous: {old.walletId});
      final updated = old.copyWith(
        amount: payment.amount,
        walletId: payment.walletId,
        occurredAt: payment.occurredAt,
        note: cleaned,
        updatedAt: _clock(),
      );
      await txn.update('transactions', updated.toMap(), where: 'id = ?', whereArgs: [old.id]);
    });
  }

  Future<void> deletePayment(String id) async {
    await db.delete('transactions',
        where: "id = ? AND type IN ('collect','repay')", whereArgs: [id]);
  }
}

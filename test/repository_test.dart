import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/core/models.dart';
import 'package:pocket_ledger/core/util.dart';
import 'package:pocket_ledger/data/backup_service.dart';
import 'package:pocket_ledger/data/debt_repository.dart';
import 'package:pocket_ledger/data/repositories.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

void main() {
  late Database db;
  late WalletRepository wallets;
  late TransactionRepository txs;
  late CategoryRepository cats;
  late ReportRepository reports;
  late PeopleRepository people;
  late DebtRepository debts;

  setUp(() async {
    db = await openTestDb();
    wallets = WalletRepository(db);
    txs = TransactionRepository(db);
    cats = CategoryRepository(db);
    reports = ReportRepository(db);
    people = PeopleRepository(db);
    debts = DebtRepository(db);
  });
  tearDown(() => db.close());

  Future<Wallet> cash() => wallets.create(
      name: 'Ví tiền mặt', iconKey: 'wallet', colorValue: 0xFF00796B, openingBalance: 100000);
  Future<Wallet> bank() => wallets.create(name: 'Bank', iconKey: 'bank', colorValue: 0xFF1E88E5);
  Future<int> balanceOf(String id) async =>
      (await wallets.list(includeArchived: true)).firstWhere((w) => w.wallet.id == id).balance;
  final month = ReportFilter(from: DateTime(2026, 9), to: DateTime(2026, 10));

  test('seeds 13 default categories + 12 default sub-categories', () async {
    final all = await cats.list();
    expect(all.where((c) => c.parentId == null).length, 13);
    expect(all.where((c) => c.parentId == 'exp_bills').length, 6);
    expect(all.length, 25);
  });

  test('balance follows create, edit and delete', () async {
    final w = await cash();
    final t = await txs.create(
        type: TxType.expense, amount: 30000, walletId: w.id,
        categoryId: 'exp_food', occurredAt: DateTime(2026, 9, 3));
    await txs.create(
        type: TxType.income, amount: 50000, walletId: w.id,
        categoryId: 'inc_salary', occurredAt: DateTime(2026, 9, 4));
    expect(await balanceOf(w.id), 120000);
    await txs.update(t.copyWith(amount: 10000));
    expect(await balanceOf(w.id), 140000);
    await txs.delete(t.id);
    expect(await balanceOf(w.id), 150000);
  });

  test('rejects zero amount and type/category mismatch', () async {
    final w = await cash();
    await expectLater(
        () => txs.create(type: TxType.expense, amount: 0, walletId: w.id,
            categoryId: 'exp_food', occurredAt: DateTime.now()),
        throwsA(isA<AppException>()));
    await expectLater(
        () => txs.create(type: TxType.income, amount: 1, walletId: w.id,
            categoryId: 'exp_food', occurredAt: DateTime.now()),
        throwsA(isA<AppException>()));
  });

  test('wallet with transactions cannot be deleted; reassign works', () async {
    final a = await cash();
    final b = await bank();
    await txs.create(type: TxType.expense, amount: 1000, walletId: a.id,
        categoryId: 'exp_food', occurredAt: DateTime.now());
    await txs.createTransfer(fromWalletId: a.id, toWalletId: b.id, amount: 500, occurredAt: DateTime.now());
    await expectLater(() => wallets.delete(a.id), throwsA(isA<AppException>()));
    await wallets.reassignAndDelete(fromId: a.id, toId: b.id);
    final list = await wallets.list();
    expect(list.single.wallet.id, b.id);
    // 100000 opening is lost with wallet A; B keeps -1000 expense, internal transfer removed.
    expect(list.single.balance, -1000);
  });

  group('transfers', () {
    test('move balances but never appear in reports', () async {
      final a = await cash();
      final b = await bank();
      await txs.createTransfer(
          fromWalletId: a.id, toWalletId: b.id, amount: 40000, occurredAt: DateTime(2026, 9, 5));
      expect(await balanceOf(a.id), 60000);
      expect(await balanceOf(b.id), 40000);
      final t = await reports.totals(month);
      expect(t.income, 0);
      expect(t.expense, 0);
      expect(await reports.byWallet(month), isEmpty);
    });
    test('same wallet is rejected', () async {
      final a = await cash();
      await expectLater(
          () => txs.createTransfer(fromWalletId: a.id, toWalletId: a.id, amount: 1, occurredAt: DateTime.now()),
          throwsA(isA<AppException>()));
    });
  });

  group('sub-categories', () {
    test('report groups children under parent; drill-down splits them', () async {
      final w = await cash();
      await txs.create(type: TxType.expense, amount: 300000, walletId: w.id,
          categoryId: 'exp_bills_electricity', occurredAt: DateTime(2026, 9, 2));
      await txs.create(type: TxType.expense, amount: 100000, walletId: w.id,
          categoryId: 'exp_bills_water', occurredAt: DateTime(2026, 9, 2));
      await txs.create(type: TxType.expense, amount: 50000, walletId: w.id,
          categoryId: 'exp_bills', occurredAt: DateTime(2026, 9, 2));
      final top = await reports.byCategory(month, TxType.expense);
      expect(top.single.category.id, 'exp_bills');
      expect(top.single.total, 450000);
      final drill = await reports.byCategory(month, TxType.expense, parentId: 'exp_bills');
      expect(drill.map((e) => e.total), [300000, 100000, 50000]);
      // Filtering by the parent includes its children.
      final filtered = await txs.query(const TxFilter(categoryId: 'exp_bills'));
      expect(filtered.length, 3);
    });

    test('2-level rule, same-parent unique names, archive cascades', () async {
      final child = await cats.create(
          type: TxType.expense, name: 'Trash fee', iconKey: 'receipt', colorValue: 1, parentId: 'exp_bills');
      // grandchild not allowed
      await expectLater(
          () => cats.create(type: TxType.expense, name: 'X', iconKey: 'receipt', colorValue: 1, parentId: child.id),
          throwsA(isA<AppException>()));
      // same name under same parent not allowed, under another parent allowed
      await expectLater(
          () => cats.create(type: TxType.expense, name: 'trash FEE', iconKey: 'receipt', colorValue: 1, parentId: 'exp_bills'),
          throwsA(isA<AppException>()));
      await cats.create(type: TxType.expense, name: 'Trash fee', iconKey: 'receipt', colorValue: 1, parentId: 'exp_food');
      // income parent for expense child not allowed
      await expectLater(
          () => cats.create(type: TxType.expense, name: 'Y', iconKey: 'receipt', colorValue: 1, parentId: 'inc_salary'),
          throwsA(isA<AppException>()));
      // a parent with children cannot be moved under another parent
      final bills = (await cats.findById('exp_bills'))!;
      await expectLater(() => cats.update(bills.copyWith(parentId: 'exp_food')), throwsA(isA<AppException>()));
      await cats.setArchived('exp_bills', true);
      expect((await cats.findById('exp_bills_water'))!.isArchived, isTrue);
      await expectLater(() => cats.setArchived('exp_bills_water', false), throwsA(isA<AppException>()));
      await cats.setArchived('exp_bills', false);
      expect((await cats.findById('exp_bills_water'))!.isArchived, isFalse);
      await expectLater(() => cats.delete('exp_bills'), throwsA(isA<AppException>()));
    });
  });

  group('loans', () {
    test('lend + partial collect, auto-settle, overpay blocked, not in reports', () async {
      final a = await cash();
      final b = await bank();
      final an = await people.create(name: 'An');
      final loan = await debts.createLoan(
          type: TxType.lend, personId: an.id, walletId: a.id, amount: 60000, occurredAt: DateTime(2026, 9, 1));
      expect(await balanceOf(a.id), 40000);
      await debts.createPayment(loanId: loan.id, walletId: b.id, amount: 20000, occurredAt: DateTime(2026, 9, 2));
      expect(await balanceOf(b.id), 20000);
      var l = (await debts.listLoans()).single;
      expect(l.remaining, 40000);
      expect(l.isSettled, isFalse);
      await expectLater(
          () => debts.createPayment(loanId: loan.id, walletId: a.id, amount: 40001, occurredAt: DateTime.now()),
          throwsA(isA<AppException>()));
      await debts.createPayment(loanId: loan.id, walletId: a.id, amount: 40000, occurredAt: DateTime(2026, 9, 3));
      l = (await debts.listLoans()).single;
      expect(l.isSettled, isTrue);
      final t = await reports.totals(month);
      expect(t.income + t.expense, 0);
    });

    test('borrow + repay; amount cannot drop below repaid; delete needs cascade', () async {
      final a = await cash();
      final binh = await people.create(name: 'Bình');
      final loan = await debts.createLoan(
          type: TxType.borrow, personId: binh.id, walletId: a.id, amount: 50000, occurredAt: DateTime.now());
      expect(await balanceOf(a.id), 150000);
      await debts.createPayment(loanId: loan.id, walletId: a.id, amount: 30000, occurredAt: DateTime.now());
      expect(await balanceOf(a.id), 120000);
      await expectLater(() => debts.updateLoan(loan.copyWith(amount: 20000)), throwsA(isA<AppException>()));
      await expectLater(() => debts.updateLoan(loan.copyWith(type: TxType.lend)), throwsA(isA<AppException>()));
      await expectLater(() => debts.deleteLoan(loan.id), throwsA(isA<AppException>()));
      await expectLater(() => txs.delete(loan.id), throwsA(isA<AppException>()));
      await expectLater(() => people.delete(binh.id), throwsA(isA<AppException>()));
      await debts.deleteLoan(loan.id, cascade: true);
      expect(await balanceOf(a.id), 100000);
      await people.delete(binh.id);
    });

    test('person names are unique (case-insensitive)', () async {
      await people.create(name: 'An');
      await expectLater(() => people.create(name: 'an'), throwsA(isA<AppException>()));
    });
  });

  group('csv', () {
    test('export -> import into fresh DB round-trips all types; second import adds nothing', () async {
      final a = await cash();
      final b = await bank();
      final an = await people.create(name: 'An', note: 'Bạn đại học');
      await txs.create(type: TxType.expense, amount: 45000, walletId: a.id,
          categoryId: 'exp_food_coffee', occurredAt: DateTime(2026, 9, 3, 7, 45),
          note: 'Bánh mì "sáng", cà phê\nmang đi');
      await txs.createTransfer(fromWalletId: a.id, toWalletId: b.id, amount: 1000, occurredAt: DateTime(2026, 9, 4));
      final loan = await debts.createLoan(
          type: TxType.lend, personId: an.id, walletId: a.id, amount: 5000, occurredAt: DateTime(2026, 9, 5));
      await debts.createPayment(loanId: loan.id, walletId: b.id, amount: 2000, occurredAt: DateTime(2026, 9, 6));
      final custom = await cats.create(
          type: TxType.expense, name: 'Phí rác', iconKey: 'receipt', colorValue: 1, parentId: 'exp_bills');
      final files = await ExportService(db).buildFiles();
      expect(files.keys.toSet(), {'wallets.csv', 'people.csv', 'categories.csv', 'transactions.csv'});

      final db2 = await openTestDb();
      final svc = ImportService(db2);
      final plan = await svc.analyze(files);
      expect(plan.fileErrors, isEmpty);
      expect(plan.errors, isEmpty);
      final r = await svc.commit(plan, DuplicateMode.skip);
      // 2 wallets + 1 person + 1 custom category + 4 transactions (defaults are identical)
      expect(r.imported, 8);
      expect((await svc.analyze(files)).newCount, 0);
      final w2 = WalletRepository(db2);
      final bal = {for (final w in await w2.list()) w.wallet.name: w.balance};
      expect(bal['Ví tiền mặt'], 100000 - 45000 - 1000 - 5000);
      expect(bal['Bank'], 1000 + 2000);
      expect((await CategoryRepository(db2).findById(custom.id))!.parentId, 'exp_bills');
      final rows = await db2.query('transactions', where: "type = 'expense'");
      expect(rows.single['note'], 'Bánh mì "sáng", cà phê\nmang đi');
      await db2.close();
    });

    test('v1 CSV files (no people.csv / new columns) still import', () async {
      final v1 = {
        'wallets.csv': Uint8List.fromList(utf8.encode(
            'id,name,icon_key,color_hex,currency_code,opening_balance,is_archived,created_at,updated_at\n'
            'w1,Ví,wallet,#FF00796B,VND,1000,0,2026-09-01T08:00:00+07:00,2026-09-01T08:00:00+07:00\n')),
        'transactions.csv': Uint8List.fromList(utf8.encode(
            'id,type,amount,currency_code,wallet_id,category_id,occurred_at,note,created_at,updated_at\n'
            't1,expense,500,VND,w1,exp_food,2026-09-03T07:45:00+07:00,,2026-09-03T07:45:00+07:00,2026-09-03T07:45:00+07:00\n')),
      };
      final plan = await ImportService(db).analyze(v1);
      expect(plan.fileErrors, isEmpty);
      expect(plan.errors, isEmpty);
      expect(plan.newCount, 2);
    });

    test('import reports bad rows: missing refs, overpayment, wrong columns per type', () async {
      final a = await cash();
      final an = await people.create(name: 'An');
      final loan = await debts.createLoan(
          type: TxType.lend, personId: an.id, walletId: a.id, amount: 1000, occurredAt: DateTime.now());
      const h = 'id,type,amount,currency_code,wallet_id,to_wallet_id,category_id,person_id,loan_id,occurred_at,note,created_at,updated_at\n';
      const d = '2026-09-03T07:45:00+07:00';
      final csv = '$h'
          'x1,expense,100,VND,nope,,exp_food,,,$d,,$d,$d\n' // missing wallet
          'x2,collect,5000,VND,${a.id},,,${an.id},${loan.id},$d,,$d,$d\n' // overpayment
          'x3,transfer,100,VND,${a.id},,exp_food,,,$d,,$d,$d\n'; // transfer w/o to_wallet, with category
      final plan = await ImportService(db).analyze({'transactions.csv': Uint8List.fromList(utf8.encode(csv))});
      expect(plan.failedRows, 3);
      expect(plan.newCount, 0);
    });

    test('bad header is rejected', () async {
      final plan = await ImportService(db)
          .analyze({'wallets.csv': Uint8List.fromList(utf8.encode('id,name\n'))});
      expect(plan.fileErrors.single, contains('missing column'));
    });
  });
}

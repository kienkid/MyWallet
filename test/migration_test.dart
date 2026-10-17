import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/data/app_database.dart';
import 'package:pocket_ledger/data/repositories.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('v1 database upgrades to v2 and keeps data', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('pl_mig');
    final path = '${dir.path}/test.db';

    final v1 = await AppDatabase.open(path: path, factory: databaseFactoryFfi, singleInstance: false, version: 1);
    await v1.insert('wallets', {
      'id': 'w1', 'name': 'Ví', 'icon_key': 'wallet', 'color_value': 1, 'currency_code': 'VND',
      'opening_balance': 1000, 'is_archived': 0, 'sort_order': 0, 'created_at': 0, 'updated_at': 0,
    });
    await v1.insert('transactions', {
      'id': 't1', 'type': 'expense', 'amount': 300, 'wallet_id': 'w1', 'category_id': 'exp_bills',
      'occurred_at': 0, 'note': 'Tiền điện', 'created_at': 0, 'updated_at': 0,
    });
    await v1.close();

    final v2 = await AppDatabase.open(path: path, factory: databaseFactoryFfi, singleInstance: false);
    expect(await v2.getVersion(), 2);
    expect((await WalletRepository(v2).list()).single.balance, 700);
    final tx = (await v2.query('transactions')).single;
    expect(tx['note'], 'Tiền điện');
    expect(tx['to_wallet_id'], isNull);
    expect((await v2.query('categories', where: 'parent_id = ?', whereArgs: ['exp_bills'])).length, 6);
    expect(await v2.query('people'), isEmpty);
    await v2.close();
    await dir.delete(recursive: true);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/app/app.dart';
import 'package:pocket_ledger/app/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  testWidgets('first launch shows empty state, 5 tabs', (tester) async {
    SharedPreferences.setMockInitialValues({'lang': 'en'});
    final prefs = await SharedPreferences.getInstance();
    final db = await tester.runAsync(openTestDb);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db!),
        prefsProvider.overrideWithValue(prefs),
      ],
      child: const PocketLedgerApp(),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('Add wallet'), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Debts'), findsWidgets);
    await tester.runAsync(() => db.close());
  });
}

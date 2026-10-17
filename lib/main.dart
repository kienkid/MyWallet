import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'data/app_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting(); // en + vi date names
  final prefs = await SharedPreferences.getInstance();
  final Database db;
  try {
    db = await AppDatabase.open(); // runs v1 -> v2 migration on first start after update
  } catch (_) {
    runApp(const _StartupError()); // never log details: may contain data paths
    return;
  }
  runApp(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      prefsProvider.overrideWithValue(prefs),
    ],
    child: const PocketLedgerApp(),
  ));
}

class _StartupError extends StatelessWidget {
  const _StartupError();
  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Could not open the local database. Free up storage and restart the app.\n\n'
                'Không thể mở cơ sở dữ liệu. Hãy giải phóng bộ nhớ và mở lại ứng dụng.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
}

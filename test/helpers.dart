import 'package:pocket_ledger/data/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fresh, isolated in-memory database (singleInstance: false so every call
/// returns a NEW database instead of reusing the previous one).
Future<Database> openTestDb() {
  sqfliteFfiInit();
  return AppDatabase.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfi, singleInstance: false);
}

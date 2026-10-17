import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite is the single source of truth. Schema changes go through numbered
/// migrations below – never edit a migration that has already been released.
class AppDatabase {
  static const int schemaVersion = 2;
  static const String fileName = 'pocket_ledger.db';

  static Future<Database> open({
    String? path,
    DatabaseFactory? factory,
    bool singleInstance = true,
    int version = schemaVersion, // tests can open an older version
  }) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), fileName);
    return f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: version,
        singleInstance: singleInstance,
        onConfigure: (db) async {
          // Must be enabled on every connection; SQLite defaults it to OFF.
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, v) async {
          for (var i = 1; i <= v; i++) {
            await _migrations[i]!(db);
          }
        },
        onUpgrade: (db, from, to) async {
          for (var i = from + 1; i <= to; i++) {
            await _migrations[i]!(db);
          }
        },
      ),
    );
  }

  /// Each entry upgrades the schema from (key - 1) to (key).
  static final Map<int, Future<void> Function(Database)> _migrations = {
    1: _v1,
    2: _v2,
  };

  // ------------------------------------------------------------------ v1 --
  static Future<void> _v1(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE wallets (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 50),
        icon_key        TEXT NOT NULL,
        color_value     INTEGER NOT NULL,
        currency_code   TEXT NOT NULL DEFAULT 'VND' CHECK (length(currency_code) = 3),
        opening_balance INTEGER NOT NULL DEFAULT 0
                        CHECK (opening_balance BETWEEN -999999999999999 AND 999999999999999),
        is_archived     INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0,1)),
        sort_order      INTEGER NOT NULL DEFAULT 0,
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL
      )''');
    batch.execute('''
      CREATE TABLE categories (
        id          TEXT PRIMARY KEY NOT NULL,
        type        TEXT NOT NULL CHECK (type IN ('income','expense')),
        name        TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 40),
        name_key    TEXT,
        icon_key    TEXT NOT NULL,
        color_value INTEGER NOT NULL,
        is_default  INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0,1)),
        sort_order  INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      )''');
    batch.execute(
        'CREATE UNIQUE INDEX ux_categories_type_name ON categories(type, name COLLATE NOCASE)');
    batch.execute('''
      CREATE TABLE transactions (
        id          TEXT PRIMARY KEY NOT NULL,
        type        TEXT NOT NULL CHECK (type IN ('income','expense')),
        amount      INTEGER NOT NULL CHECK (amount > 0 AND amount <= 999999999999999),
        wallet_id   TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
        category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
        occurred_at INTEGER NOT NULL,
        note        TEXT CHECK (note IS NULL OR length(note) <= 500),
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      )''');
    batch.execute('CREATE INDEX ix_tx_occurred ON transactions(occurred_at)');
    batch.execute('CREATE INDEX ix_tx_wallet_date ON transactions(wallet_id, occurred_at)');
    batch.execute('CREATE INDEX ix_tx_category_date ON transactions(category_id, occurred_at)');
    batch.execute('CREATE INDEX ix_tx_type_date ON transactions(type, occurred_at)');
    for (final op in ['INSERT', 'UPDATE']) {
      batch.execute('''
        CREATE TRIGGER trg_tx_type_${op.toLowerCase()} BEFORE $op ON transactions
        WHEN (SELECT type FROM categories WHERE id = NEW.category_id) <> NEW.type
        BEGIN SELECT RAISE(ABORT, 'category_type_mismatch'); END''');
    }
    await batch.commit(noResult: true);
    await _seedDefaultCategories(db);
  }

  static Future<void> _seedDefaultCategories(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    const defaults = [
      ['exp_food', 'expense', 'cat_food', 'Food', 'restaurant', 0xFFE53935],
      ['exp_transport', 'expense', 'cat_transport', 'Transportation', 'directions_car', 0xFF1E88E5],
      ['exp_shopping', 'expense', 'cat_shopping', 'Shopping', 'shopping_bag', 0xFFD81B60],
      ['exp_bills', 'expense', 'cat_bills', 'Bills', 'receipt', 0xFFF4511E],
      ['exp_health', 'expense', 'cat_health', 'Health', 'health', 0xFF2E7D32],
      ['exp_family', 'expense', 'cat_family', 'Family', 'family', 0xFF283593],
      ['exp_education', 'expense', 'cat_education', 'Education', 'school', 0xFF3949AB],
      ['exp_entertainment', 'expense', 'cat_entertainment', 'Entertainment', 'movie', 0xFF8E24AA],
      ['exp_donations', 'expense', 'cat_donations', 'Donations', 'gift', 0xFF6A1B9A],
      ['exp_relationship', 'expense', 'cat_relationship', 'Relationship', 'person', 0xFFAD1457],
      ['exp_other', 'expense', 'cat_other', 'Other', 'category', 0xFF546E7A],
      ['inc_salary', 'income', 'cat_salary', 'Salary', 'work', 0xFF00796B],
      ['inc_bonus', 'income', 'cat_bonus', 'Bonus', 'star', 0xFFF4511E],
      ['inc_investment', 'income', 'cat_investment', 'Investment', 'trending_up', 0xFF1E88E5],
      ['inc_gift', 'income', 'cat_gift', 'Gift', 'gift', 0xFFD81B60],
      ['inc_sale', 'income', 'cat_sale', 'Sale', 'point_of_sale', 0xFF4E342E],
      ['inc_other', 'income', 'cat_other', 'Other', 'category', 0xFF546E7A],
    ];
    final batch = db.batch();
    for (var i = 0; i < defaults.length; i++) {
      final d = defaults[i];
      batch.insert(
        'categories',
        {
          'id': d[0],
          'type': d[1],
          'name_key': d[2],
          'name': d[3],
          'icon_key': d[4],
          'color_value': d[5],
          'is_default': 1,
          'is_archived': 0,
          'sort_order': i,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  // ------------------------------------------------------------------ v2 --
  // Adds: sub-categories, people, transfers, loans/repayments.
  static Future<void> _v2(Database db) async {
    // 1. Sub-categories: nullable self-reference (2 levels enforced in Dart).
    await db.execute(
        'ALTER TABLE categories ADD COLUMN parent_id TEXT REFERENCES categories(id) ON DELETE RESTRICT');
    await db.execute('DROP INDEX IF EXISTS ux_categories_type_name');
    await db.execute('CREATE UNIQUE INDEX ux_categories_name '
        "ON categories(type, COALESCE(parent_id, ''), name COLLATE NOCASE)");
    await db.execute('CREATE INDEX ix_categories_parent ON categories(parent_id)');

    // 2. People (who I lend to / borrow from).
    await db.execute('''
      CREATE TABLE people (
        id          TEXT PRIMARY KEY NOT NULL,
        name        TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 60),
        note        TEXT CHECK (note IS NULL OR length(note) <= 200),
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0,1)),
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      )''');
    await db.execute('CREATE UNIQUE INDEX ux_people_name ON people(name COLLATE NOCASE)');

    // 3. Rebuild transactions (SQLite cannot change CHECK constraints in place).
    //    Nothing references the v1 table, so rename -> create -> copy -> drop is safe.
    await db.execute('ALTER TABLE transactions RENAME TO transactions_v1');
    await db.execute('''
      CREATE TABLE transactions (
        id           TEXT PRIMARY KEY NOT NULL,
        type         TEXT NOT NULL CHECK (type IN
                       ('income','expense','transfer','lend','borrow','collect','repay')),
        amount       INTEGER NOT NULL CHECK (amount > 0 AND amount <= 999999999999999),
        wallet_id    TEXT NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
        category_id  TEXT REFERENCES categories(id) ON DELETE RESTRICT,
        to_wallet_id TEXT REFERENCES wallets(id) ON DELETE RESTRICT,
        person_id    TEXT REFERENCES people(id) ON DELETE RESTRICT,
        loan_id      TEXT REFERENCES transactions(id) ON DELETE RESTRICT,
        occurred_at  INTEGER NOT NULL,
        note         TEXT CHECK (note IS NULL OR length(note) <= 500),
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL,
        CHECK ((type IN ('income','expense')) = (category_id IS NOT NULL)),
        CHECK ((type = 'transfer') = (to_wallet_id IS NOT NULL)),
        CHECK (to_wallet_id IS NULL OR to_wallet_id <> wallet_id),
        CHECK ((type IN ('lend','borrow','collect','repay')) = (person_id IS NOT NULL)),
        CHECK ((type IN ('collect','repay')) = (loan_id IS NOT NULL))
      )''');
    await db.execute('''
      INSERT INTO transactions
        (id, type, amount, wallet_id, category_id, occurred_at, note, created_at, updated_at)
      SELECT id, type, amount, wallet_id, category_id, occurred_at, note, created_at, updated_at
      FROM transactions_v1''');
    await db.execute('DROP TABLE transactions_v1'); // also drops its old indexes/triggers

    final batch = db.batch();
    batch.execute('CREATE INDEX ix_tx_occurred ON transactions(occurred_at)');
    batch.execute('CREATE INDEX ix_tx_wallet_date ON transactions(wallet_id, occurred_at)');
    batch.execute('CREATE INDEX ix_tx_to_wallet ON transactions(to_wallet_id)');
    batch.execute('CREATE INDEX ix_tx_category_date ON transactions(category_id, occurred_at)');
    batch.execute('CREATE INDEX ix_tx_type_date ON transactions(type, occurred_at)');
    batch.execute('CREATE INDEX ix_tx_person ON transactions(person_id)');
    batch.execute('CREATE INDEX ix_tx_loan ON transactions(loan_id)');
    for (final op in ['INSERT', 'UPDATE']) {
      final o = op.toLowerCase();
      // Category type must equal transaction type.
      batch.execute('''
        CREATE TRIGGER trg_tx_cat_$o BEFORE $op ON transactions
        WHEN NEW.category_id IS NOT NULL
         AND (SELECT type FROM categories WHERE id = NEW.category_id) <> NEW.type
        BEGIN SELECT RAISE(ABORT, 'category_type_mismatch'); END''');
      // collect -> lend, repay -> borrow.
      batch.execute('''
        CREATE TRIGGER trg_tx_loan_$o BEFORE $op ON transactions
        WHEN NEW.loan_id IS NOT NULL
         AND (SELECT type FROM transactions WHERE id = NEW.loan_id)
             IS NOT (CASE NEW.type WHEN 'collect' THEN 'lend' ELSE 'borrow' END)
        BEGIN SELECT RAISE(ABORT, 'loan_type_mismatch'); END''');
    }
    await batch.commit(noResult: true);

    await _seedDefaultSubCategories(db);
  }

  static Future<void> _seedDefaultSubCategories(Database db) async {
    const subs = {
      'exp_bills': [
        ['exp_bills_electricity', 'sub_electricity', 'Electricity', 'bolt'],
        ['exp_bills_water', 'sub_water', 'Water', 'water'],
        ['exp_bills_internet', 'sub_internet', 'Internet', 'wifi'],
        ['exp_bills_phone', 'sub_phone', 'Phone', 'phone'],
        ['exp_bills_rent', 'sub_rent', 'Rent', 'home'],
        ['exp_bills_gas', 'sub_gas', 'Gas', 'fire'],
      ],
      'exp_transport': [
        ['exp_transport_fuel', 'sub_fuel', 'Fuel', 'fuel'],
        ['exp_transport_parking', 'sub_parking', 'Parking', 'parking'],
        ['exp_transport_ride', 'sub_ride', 'Ride-hailing', 'motorbike'],
      ],
      'exp_food': [
        ['exp_food_groceries', 'sub_groceries', 'Groceries', 'cart'],
        ['exp_food_eating_out', 'sub_eating_out', 'Eating out', 'restaurant'],
        ['exp_food_coffee', 'sub_coffee', 'Coffee', 'local_cafe'],
      ],
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in subs.entries) {
      final parent = await db.query('categories',
          where: 'id = ? AND parent_id IS NULL', whereArgs: [entry.key], limit: 1);
      if (parent.isEmpty) continue;
      final p = parent.first;
      for (var i = 0; i < entry.value.length; i++) {
        final s = entry.value[i];
        await db.insert(
          'categories',
          {
            'id': s[0],
            'type': p['type'],
            'name_key': s[1],
            'name': s[2],
            'parent_id': entry.key,
            'icon_key': s[3],
            'color_value': p['color_value'],
            'is_default': 1,
            'is_archived': p['is_archived'],
            'sort_order': i,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }
}

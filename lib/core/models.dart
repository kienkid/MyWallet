// Immutable domain models. No Flutter widgets, no SQL here.
import 'package:flutter/foundation.dart';

/// Every money movement is one row in `transactions`.
/// Only income/expense appear in reports; the others only move wallet balances.
enum TxType {
  income,
  expense,
  transfer, // wallet_id -> to_wallet_id
  lend, // I lend money to a person (wallet -)
  borrow, // a person lends me money (wallet +)
  collect, // a person repays my loan (wallet +), links to a `lend`
  repay; // I repay a person (wallet -), links to a `borrow`

  static TxType parse(String s) => TxType.values.firstWhere(
        (e) => e.name == s,
        orElse: () => throw FormatException('Invalid type: $s'),
      );

  bool get isCategorized => this == TxType.income || this == TxType.expense;
  bool get isLoan => this == TxType.lend || this == TxType.borrow;
  bool get isPayment => this == TxType.collect || this == TxType.repay;
  bool get isDebt => isLoan || isPayment;

  /// +1 when money enters `wallet_id`, -1 when it leaves.
  int get walletSign => switch (this) {
        TxType.income || TxType.borrow || TxType.collect => 1,
        _ => -1,
      };

  /// Repayment type for a loan type (lend -> collect, borrow -> repay).
  TxType get paymentType => this == TxType.lend ? TxType.collect : TxType.repay;

  TxGroup get group => switch (this) {
        TxType.income => TxGroup.income,
        TxType.expense => TxGroup.expense,
        TxType.transfer => TxGroup.transfer,
        _ => TxGroup.debt,
      };
}

enum TxGroup {
  income,
  expense,
  transfer,
  debt;

  List<TxType> get types => switch (this) {
        TxGroup.income => const [TxType.income],
        TxGroup.expense => const [TxType.expense],
        TxGroup.transfer => const [TxType.transfer],
        TxGroup.debt => const [TxType.lend, TxType.borrow, TxType.collect, TxType.repay],
      };
}

DateTime _ms(Object? v) => DateTime.fromMillisecondsSinceEpoch(v as int);
const _keep = Object();

@immutable
class Wallet {
  const Wallet({
    required this.id,
    required this.name,
    required this.iconKey,
    required this.colorValue,
    required this.currencyCode,
    required this.openingBalance,
    required this.isArchived,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String iconKey;
  final int colorValue;
  final String currencyCode;
  final int openingBalance; // minor units (VND: 1 = 1 ₫)
  final bool isArchived;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Wallet.fromMap(Map<String, Object?> m) => Wallet(
        id: m['id'] as String,
        name: m['name'] as String,
        iconKey: m['icon_key'] as String,
        colorValue: m['color_value'] as int,
        currencyCode: m['currency_code'] as String,
        openingBalance: m['opening_balance'] as int,
        isArchived: (m['is_archived'] as int) == 1,
        sortOrder: m['sort_order'] as int,
        createdAt: _ms(m['created_at']),
        updatedAt: _ms(m['updated_at']),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'icon_key': iconKey,
        'color_value': colorValue,
        'currency_code': currencyCode,
        'opening_balance': openingBalance,
        'is_archived': isArchived ? 1 : 0,
        'sort_order': sortOrder,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  Wallet copyWith({
    String? name,
    String? iconKey,
    int? colorValue,
    String? currencyCode,
    int? openingBalance,
    bool? isArchived,
    DateTime? updatedAt,
  }) =>
      Wallet(
        id: id,
        name: name ?? this.name,
        iconKey: iconKey ?? this.iconKey,
        colorValue: colorValue ?? this.colorValue,
        currencyCode: currencyCode ?? this.currencyCode,
        openingBalance: openingBalance ?? this.openingBalance,
        isArchived: isArchived ?? this.isArchived,
        sortOrder: sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  bool sameContent(Wallet o) =>
      name == o.name &&
      iconKey == o.iconKey &&
      colorValue == o.colorValue &&
      currencyCode == o.currencyCode &&
      openingBalance == o.openingBalance &&
      isArchived == o.isArchived;
}

@immutable
class WalletWithBalance {
  const WalletWithBalance(this.wallet, this.balance, this.txCount);
  final Wallet wallet;
  final int balance; // computed on read, never stored
  final int txCount;
}

@immutable
class Category {
  const Category({
    required this.id,
    required this.type,
    required this.name,
    this.nameKey,
    this.parentId,
    required this.iconKey,
    required this.colorValue,
    required this.isDefault,
    required this.isArchived,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final TxType type; // income | expense
  final String name;
  final String? nameKey; // localization key for default categories
  final String? parentId; // null = top-level (max 2 levels)
  final String iconKey;
  final int colorValue;
  final bool isDefault;
  final bool isArchived;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isChild => parentId != null;

  factory Category.fromMap(Map<String, Object?> m, {String p = ''}) => Category(
        id: m['${p}id'] as String,
        type: TxType.parse(m['${p}type'] as String),
        name: m['${p}name'] as String,
        nameKey: m['${p}name_key'] as String?,
        parentId: m['${p}parent_id'] as String?,
        iconKey: m['${p}icon_key'] as String,
        colorValue: m['${p}color_value'] as int,
        isDefault: (m['${p}is_default'] as int) == 1,
        isArchived: (m['${p}is_archived'] as int) == 1,
        sortOrder: m['${p}sort_order'] as int,
        createdAt: _ms(m['${p}created_at']),
        updatedAt: _ms(m['${p}updated_at']),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'type': type.name,
        'name': name,
        'name_key': nameKey,
        'parent_id': parentId,
        'icon_key': iconKey,
        'color_value': colorValue,
        'is_default': isDefault ? 1 : 0,
        'is_archived': isArchived ? 1 : 0,
        'sort_order': sortOrder,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  Category copyWith({
    String? name,
    String? iconKey,
    int? colorValue,
    bool? isArchived,
    Object? parentId = _keep,
    DateTime? updatedAt,
    bool clearNameKey = false,
  }) =>
      Category(
        id: id,
        type: type,
        name: name ?? this.name,
        nameKey: clearNameKey ? null : nameKey,
        parentId: identical(parentId, _keep) ? this.parentId : parentId as String?,
        iconKey: iconKey ?? this.iconKey,
        colorValue: colorValue ?? this.colorValue,
        isDefault: isDefault,
        isArchived: isArchived ?? this.isArchived,
        sortOrder: sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  bool sameContent(Category o) =>
      type == o.type &&
      name == o.name &&
      nameKey == o.nameKey &&
      parentId == o.parentId &&
      iconKey == o.iconKey &&
      colorValue == o.colorValue &&
      isDefault == o.isDefault &&
      isArchived == o.isArchived;
}

@immutable
class Person {
  const Person({
    required this.id,
    required this.name,
    this.note,
    required this.isArchived,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? note;
  final bool isArchived;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Person.fromMap(Map<String, Object?> m) => Person(
        id: m['id'] as String,
        name: m['name'] as String,
        note: m['note'] as String?,
        isArchived: (m['is_archived'] as int) == 1,
        createdAt: _ms(m['created_at']),
        updatedAt: _ms(m['updated_at']),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'note': note,
        'is_archived': isArchived ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  bool sameContent(Person o) =>
      name == o.name && (note ?? '') == (o.note ?? '') && isArchived == o.isArchived;
}

@immutable
class Tx {
  const Tx({
    required this.id,
    required this.type,
    required this.amount,
    required this.walletId,
    this.categoryId,
    this.toWalletId,
    this.personId,
    this.loanId,
    required this.occurredAt,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final TxType type;
  final int amount; // always > 0; direction comes from type
  final String walletId; // source wallet for transfers
  final String? categoryId; // income/expense only
  final String? toWalletId; // transfer only
  final String? personId; // lend/borrow/collect/repay
  final String? loanId; // collect/repay -> the lend/borrow row
  final DateTime occurredAt;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Effect on `walletId` (transfers: negative for the source wallet).
  int get signed => amount * type.walletSign;

  factory Tx.fromMap(Map<String, Object?> m) => Tx(
        id: m['id'] as String,
        type: TxType.parse(m['type'] as String),
        amount: m['amount'] as int,
        walletId: m['wallet_id'] as String,
        categoryId: m['category_id'] as String?,
        toWalletId: m['to_wallet_id'] as String?,
        personId: m['person_id'] as String?,
        loanId: m['loan_id'] as String?,
        occurredAt: _ms(m['occurred_at']),
        note: m['note'] as String?,
        createdAt: _ms(m['created_at']),
        updatedAt: _ms(m['updated_at']),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'type': type.name,
        'amount': amount,
        'wallet_id': walletId,
        'category_id': categoryId,
        'to_wallet_id': toWalletId,
        'person_id': personId,
        'loan_id': loanId,
        'occurred_at': occurredAt.millisecondsSinceEpoch,
        'note': note,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  Tx copyWith({
    TxType? type,
    int? amount,
    String? walletId,
    Object? categoryId = _keep,
    Object? toWalletId = _keep,
    Object? personId = _keep,
    Object? loanId = _keep,
    DateTime? occurredAt,
    Object? note = _keep,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Tx(
        id: id,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        walletId: walletId ?? this.walletId,
        categoryId: identical(categoryId, _keep) ? this.categoryId : categoryId as String?,
        toWalletId: identical(toWalletId, _keep) ? this.toWalletId : toWalletId as String?,
        personId: identical(personId, _keep) ? this.personId : personId as String?,
        loanId: identical(loanId, _keep) ? this.loanId : loanId as String?,
        occurredAt: occurredAt ?? this.occurredAt,
        note: identical(note, _keep) ? this.note : note as String?,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  bool sameContent(Tx o) =>
      type == o.type &&
      amount == o.amount &&
      walletId == o.walletId &&
      categoryId == o.categoryId &&
      toWalletId == o.toWalletId &&
      personId == o.personId &&
      loanId == o.loanId &&
      occurredAt.millisecondsSinceEpoch == o.occurredAt.millisecondsSinceEpoch &&
      (note ?? '') == (o.note ?? '');
}

/// A transaction joined with display data for lists.
@immutable
class TxView {
  const TxView({
    required this.tx,
    required this.walletName,
    required this.currencyCode,
    this.category,
    this.parentName,
    this.parentNameKey,
    this.toWalletName,
    this.personName,
  });
  final Tx tx;
  final String walletName;
  final String currencyCode;
  final Category? category;
  final String? parentName;
  final String? parentNameKey;
  final String? toWalletName;
  final String? personName;
}

@immutable
class PaymentView {
  const PaymentView(this.tx, this.walletName);
  final Tx tx;
  final String walletName;
}

/// A lend/borrow row with its repayments. Remaining is always computed.
@immutable
class Loan {
  const Loan({
    required this.tx,
    required this.personName,
    required this.walletName,
    required this.currencyCode,
    required this.payments,
  });
  final Tx tx;
  final String personName;
  final String walletName;
  final String currencyCode;
  final List<PaymentView> payments;

  int get paid => payments.fold(0, (a, p) => a + p.tx.amount);
  int get remaining => tx.amount - paid;
  bool get isSettled => remaining <= 0;
}

@immutable
class PersonDebt {
  const PersonDebt(this.person, this.owedToMe, this.iOwe, this.loans);
  final Person person;
  final int owedToMe; // remaining on my `lend` loans
  final int iOwe; // remaining on my `borrow` loans
  final List<Loan> loans;
  int get net => owedToMe - iOwe;
  bool get hasActive => owedToMe > 0 || iOwe > 0;
}

@immutable
class TxFilter {
  const TxFilter({
    this.query = '',
    this.group,
    this.walletId,
    this.categoryId,
    this.from,
    this.to,
  });

  final String query;
  final TxGroup? group;
  final String? walletId; // matches source OR destination wallet
  final String? categoryId; // includes its sub-categories
  final DateTime? from; // inclusive
  final DateTime? to; // exclusive

  bool get hasStructuredFilters =>
      group != null || walletId != null || categoryId != null || from != null;

  TxFilter copyWith({
    String? query,
    Object? group = _keep,
    Object? walletId = _keep,
    Object? categoryId = _keep,
    Object? from = _keep,
    Object? to = _keep,
  }) =>
      TxFilter(
        query: query ?? this.query,
        group: identical(group, _keep) ? this.group : group as TxGroup?,
        walletId: identical(walletId, _keep) ? this.walletId : walletId as String?,
        categoryId:
            identical(categoryId, _keep) ? this.categoryId : categoryId as String?,
        from: identical(from, _keep) ? this.from : from as DateTime?,
        to: identical(to, _keep) ? this.to : to as DateTime?,
      );
}

@immutable
class ReportFilter {
  const ReportFilter({
    required this.from,
    required this.to,
    this.walletId,
    this.categoryId,
    this.currencyCode = 'VND',
  });
  final DateTime from; // inclusive
  final DateTime to; // exclusive
  final String? walletId;
  final String? categoryId; // includes its sub-categories
  final String currencyCode;

  ReportFilter copyWith({
    DateTime? from,
    DateTime? to,
    Object? walletId = _keep,
    Object? categoryId = _keep,
  }) =>
      ReportFilter(
        from: from ?? this.from,
        to: to ?? this.to,
        walletId: identical(walletId, _keep) ? this.walletId : walletId as String?,
        categoryId:
            identical(categoryId, _keep) ? this.categoryId : categoryId as String?,
        currencyCode: currencyCode,
      );

  @override
  bool operator ==(Object other) =>
      other is ReportFilter &&
      other.from == from &&
      other.to == to &&
      other.walletId == walletId &&
      other.categoryId == categoryId &&
      other.currencyCode == currencyCode;

  @override
  int get hashCode => Object.hash(from, to, walletId, categoryId, currencyCode);
}

@immutable
class CategorySlice {
  const CategorySlice(this.category, this.total, this.count);
  final Category category;
  final int total;
  final int count;
}

@immutable
class MonthlyTotal {
  const MonthlyTotal(this.monthStart, this.income, this.expense);
  final DateTime monthStart;
  final int income;
  final int expense;
}

@immutable
class WalletSpending {
  const WalletSpending(this.walletId, this.walletName, this.income, this.expense);
  final String walletId;
  final String walletName;
  final int income;
  final int expense;
}

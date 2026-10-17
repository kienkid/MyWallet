import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/core/csv_codec.dart';
import 'package:pocket_ledger/core/money.dart';
import 'package:pocket_ledger/core/util.dart';

void main() {
  group('parseAmount', () {
    test('accepts grouped VND', () {
      expect(parseAmount('1.250.000'), 1250000);
      expect(parseAmount('1,250,000 ₫'), 1250000);
    });
    test('rejects empty, letters, negatives, too large', () {
      expect(parseAmount(''), isNull);
      expect(parseAmount('abc'), isNull);
      expect(parseAmount('-5'), isNull);
      expect(parseAmount('9999999999999999'), isNull);
    });
    test('allows negative opening balance when enabled', () {
      expect(parseAmount('-500.000', allowNegative: true), -500000);
    });
  });

  test('formatMoney uses no decimals for VND', () {
    expect(formatMoney(1250000, 'VND', 'vi'), contains('1.250.000'));
    expect(formatMoney(1250000, 'VND', 'en'), contains('1,250,000'));
    expect(formatMoney(1250000, 'VND', 'en').contains('.00'), isFalse);
  });

  test('basisPoints always sums to 100%', () {
    final bp = basisPoints([1, 1, 1]);
    expect(bp.reduce((a, b) => a + b), 10000);
    expect(basisPoints([0, 0]), [0, 0]);
  });

  test('normalizeText removes Vietnamese diacritics', () {
    expect(normalizeText('Cà Phê Đường'), 'ca phe duong');
  });

  group('csv codec', () {
    test('round-trips commas, quotes, line breaks and Vietnamese', () {
      final rows = [
        ['id', 'note'],
        ['1', 'Bánh mì "sáng", cà phê\nmang đi'],
        ['2', ' khoảng trắng '],
      ];
      expect(decodeCsv(encodeCsv(rows)), rows);
    });
    test('strips BOM and accepts LF', () {
      expect(decodeCsv('\uFEFFa,b\n1,2\n'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });
    test('keeps empty trailing field', () {
      expect(decodeCsv('a,b\r\n1,\r\n'), [
        ['a', 'b'],
        ['1', ''],
      ]);
    });
    test('throws on unterminated quote', () {
      expect(() => decodeCsv('a\n"oops'), throwsA(isA<CsvParseException>()));
    });
  });

  test('ISO date with offset parses back to same instant', () {
    final d = DateTime(2026, 9, 3, 7, 45);
    expect(DateTime.parse(isoWithOffset(d)).toLocal(), d);
  });
}

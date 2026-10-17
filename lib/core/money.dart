import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Upper bound for any stored amount (15 digits) – far below int64 limits.
const int maxAmount = 999999999999999;

class Currency {
  const Currency(this.code, this.symbol, this.decimals);
  final String code;
  final String symbol;
  final int decimals; // VND = 0. Add e.g. Currency('USD', r'$', 2) later.
}

/// Registry of supported currencies. MVP: VND only.
const Map<String, Currency> currencies = {
  'VND': Currency('VND', '₫', 0),
};
const String defaultCurrency = 'VND';

String _localeFor(String lang) => lang == 'vi' ? 'vi_VN' : 'en_US';

/// Formats integer minor units for display. Never use for storage.
String formatMoney(int minor, String code, String lang, {bool signed = false}) {
  final c = currencies[code] ?? Currency(code, code, 0);
  final f = NumberFormat.currency(
    locale: _localeFor(lang),
    symbol: c.symbol,
    decimalDigits: c.decimals,
  );
  final abs = minor.abs();
  final num value = c.decimals == 0 ? abs : abs / _pow10(c.decimals);
  final body = f.format(value);
  if (minor < 0) return '−$body';
  if (signed && minor > 0) return '+$body';
  return body;
}

int _pow10(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

/// Parses user input such as "1.250.000", "1,250,000" or "1250000 ₫".
/// Returns null when invalid. Integers only (VND has no decimals).
int? parseAmount(String input, {bool allowNegative = false}) {
  var s = input.trim();
  var negative = false;
  if (s.startsWith('-') || s.startsWith('−')) {
    if (!allowNegative) return null;
    negative = true;
    s = s.substring(1);
  }
  s = s.replaceAll(RegExp(r'[.,\s₫]'), '');
  if (s.isEmpty || !RegExp(r'^\d+$').hasMatch(s) || s.length > 15) return null;
  final v = int.parse(s);
  if (v > maxAmount) return null;
  return negative ? -v : v;
}

/// Groups digits while typing: "1250000" -> "1.250.000" (vi) / "1,250,000" (en).
class ThousandsInputFormatter extends TextInputFormatter {
  ThousandsInputFormatter(this.lang, {this.allowNegative = false});
  final String lang;
  final bool allowNegative;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    final negative = allowNegative && raw.startsWith('-');
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 15) digits = digits.substring(0, 15);
    digits = digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final text = '${negative ? '-' : ''}${_group(digits, lang)}';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

String _group(String digits, String lang) {
  final sep = lang == 'vi' ? '.' : ',';
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(sep);
    b.write(digits[i]);
  }
  return b.toString();
}

String formatAmountInput(int value, String lang) =>
    '${value < 0 ? '-' : ''}${_group(value.abs().toString(), lang)}';

/// Largest-remainder percentages in basis points (sum = 10000 exactly).
List<int> basisPoints(List<int> values) {
  final total = values.fold<int>(0, (a, b) => a + b);
  if (total <= 0) return List.filled(values.length, 0);
  final floors = <int>[];
  final rema = <MapEntry<int, int>>[];
  for (var i = 0; i < values.length; i++) {
    final scaled = values[i] * 10000;
    floors.add(scaled ~/ total);
    rema.add(MapEntry(i, scaled % total));
  }
  final left = 10000 - floors.fold<int>(0, (a, b) => a + b);
  rema.sort((a, b) => b.value.compareTo(a.value));
  for (var k = 0; k < left; k++) {
    floors[rema[k].key]++;
  }
  return floors;
}

String formatPercent(int bp) => '${(bp / 100).toStringAsFixed(1)}%';

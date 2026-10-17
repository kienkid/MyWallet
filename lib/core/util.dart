import 'package:flutter/material.dart';

/// Typed error raised by repositories/services. `code` maps to `err_<code>` strings.
class AppException implements Exception {
  const AppException(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => 'AppException($code)'; // never include amounts or notes
}

/// Lowercase + remove Vietnamese diacritics, so "ca phe" matches "Cà phê".
String normalizeText(String s) {
  const groups = {
    'a': 'àáạảãâầấậẩẫăằắặẳẵ',
    'e': 'èéẹẻẽêềếệểễ',
    'i': 'ìíịỉĩ',
    'o': 'òóọỏõôồốộổỗơờớợởỡ',
    'u': 'ùúụủũưừứựửữ',
    'y': 'ỳýỵỷỹ',
    'd': 'đ',
  };
  final map = <String, String>{};
  groups.forEach((base, chars) {
    for (final c in chars.split('')) {
      map[c] = base;
    }
  });
  final b = StringBuffer();
  for (final rune in s.toLowerCase().runes) {
    if (rune >= 0x0300 && rune <= 0x036F) continue; // combining marks (NFD)
    final ch = String.fromCharCode(rune);
    b.write(map[ch] ?? ch);
  }
  return b.toString();
}

/// ISO 8601 with the local offset, e.g. 2026-09-03T07:45:00+07:00
String isoWithOffset(DateTime d) {
  final l = d.toLocal();
  final o = l.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final h = o.inHours.abs().toString().padLeft(2, '0');
  final m = (o.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return '${l.toIso8601String().split('.').first}$sign$h:$m';
}

String colorToHex(int argb) => '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';

int? hexToColor(String s) {
  if (!RegExp(r'^#[0-9A-Fa-f]{8}$').hasMatch(s)) return null;
  return int.parse(s.substring(1), radix: 16);
}

DateTime startOfMonth(DateTime d) => DateTime(d.year, d.month);
DateTime addMonths(DateTime d, int n) => DateTime(d.year, d.month + n);
DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

// ---- Icon & color catalog (original Material icons, no third-party assets) ----
const Map<String, IconData> iconCatalog = {
  'wallet': Icons.account_balance_wallet,
  'bank': Icons.account_balance,
  'card': Icons.credit_card,
  'savings': Icons.savings,
  'cash': Icons.payments,
  'restaurant': Icons.restaurant,
  'local_cafe': Icons.local_cafe,
  'cart': Icons.shopping_cart,
  'directions_car': Icons.directions_car,
  'fuel': Icons.local_gas_station,
  'parking': Icons.local_parking,
  'motorbike': Icons.two_wheeler,
  'shopping_bag': Icons.shopping_bag,
  'receipt': Icons.receipt_long,
  'bolt': Icons.bolt,
  'water': Icons.water_drop,
  'wifi': Icons.wifi,
  'fire': Icons.local_fire_department,
  'health': Icons.local_hospital,
  'school': Icons.school,
  'movie': Icons.movie,
  'category': Icons.category,
  'work': Icons.work,
  'star': Icons.star,
  'trending_up': Icons.trending_up,
  'gift': Icons.card_giftcard,
  'home': Icons.home,
  'pets': Icons.pets,
  'phone': Icons.phone_android,
  'sports': Icons.sports_soccer,
  'travel': Icons.flight,
  'child': Icons.child_care,
  'groceries': Icons.local_grocery_store,
  'clothing': Icons.checkroom,
  'beauty': Icons.spa,
  'fitness': Icons.fitness_center,
  'medical_services': Icons.medical_services,
  'pharmacy': Icons.medication,
  'baby': Icons.child_friendly,
  'books': Icons.menu_book,
  'computer': Icons.computer,
  'electronics': Icons.devices,
  'home_repair': Icons.handyman,
  'furniture': Icons.weekend,
  'insurance': Icons.security,
  'rent': Icons.key,
  'utilities': Icons.electrical_services,
  'bus': Icons.directions_bus,
  'hotel': Icons.hotel,
  'donation': Icons.volunteer_activism,
  'loan': Icons.request_quote,
  'tax': Icons.calculate,
  'bakery': Icons.bakery_dining,
  'luggage': Icons.luggage,
  'train': Icons.directions_railway,
  'taxi': Icons.local_taxi,
  'bicycle': Icons.directions_bike,
  'boat': Icons.directions_boat,
  'subscriptions': Icons.subscriptions,
  'television': Icons.live_tv,
  'music': Icons.music_note,
  'photography': Icons.camera_alt,
  'gaming': Icons.sports_esports,
  'garden': Icons.yard,
  'cleaning': Icons.cleaning_services,
  'laundry': Icons.local_laundry_service,
  'business': Icons.business_center,
  'currency_exchange': Icons.currency_exchange,
  'cashback': Icons.price_check,
  'real_estate': Icons.real_estate_agent,
  'construction': Icons.construction,
  'recycling': Icons.recycling,
  'family': Icons.family_restroom,
  'person': Icons.person,
};

IconData iconFor(String key) => iconCatalog[key] ?? Icons.help_outline;

/// All palette colours keep >= 4.5:1 contrast against white icons.
const List<int> colorPalette = [
  0xFF00796B, 0xFF1E88E5, 0xFF3949AB, 0xFF8E24AA, 0xFFD81B60, 0xFFE53935,
  0xFFF4511E, 0xFF6D4C41, 0xFF2E7D32, 0xFF546E7A, 0xFF00838F, 0xFF5E35B1,
  0xFF283593, 0xFF6A1B9A, 0xFFAD1457, 0xFFBF360C, 0xFF4E342E, 0xFF1B5E20,
  0xFF37474F, 0xFF006064, 0xFF4527A0, 0xFF827717, 0xFF01579B, 0xFF263238,
];

const Color incomeColor = Color(0xFF2E7D32);
const Color expenseColor = Color(0xFFC62828);
const Color incomeColorDark = Color(0xFF81C784);
const Color expenseColorDark = Color(0xFFEF9A9A);

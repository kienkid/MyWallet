import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/dashboard_screen.dart';
import '../features/debt_screens.dart';
import '../features/reports_screen.dart';
import '../features/settings_screen.dart';
import '../features/transactions_screens.dart';
import 'providers.dart';

const _seed = Color(0xFF00796B); // original deep-teal brand seed

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded, // >= 48dp targets
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    cardTheme: const CardThemeData(margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6)),
  );
}

class PocketLedgerApp extends ConsumerWidget {
  const PocketLedgerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final s = ref.watch(stringsProvider);
    return MaterialApp(
      title: s['appName'],
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      locale: Locale(settings.lang),
      supportedLocales: const [Locale('en'), Locale('vi')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final index = ref.watch(tabIndexProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: const [
        DashboardScreen(),
        TransactionsScreen(),
        DebtsScreen(),
        ReportsScreen(),
        SettingsScreen(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => ref.read(tabIndexProvider.notifier).set(i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home), label: s['tabHome']),
          NavigationDestination(icon: const Icon(Icons.receipt_long_outlined), selectedIcon: const Icon(Icons.receipt_long), label: s['tabTransactions']),
          NavigationDestination(icon: const Icon(Icons.handshake_outlined), selectedIcon: const Icon(Icons.handshake), label: s['tabDebts']),
          NavigationDestination(icon: const Icon(Icons.pie_chart_outline), selectedIcon: const Icon(Icons.pie_chart), label: s['tabReports']),
          NavigationDestination(icon: const Icon(Icons.settings_outlined), selectedIcon: const Icon(Icons.settings), label: s['tabSettings']),
        ],
      ),
    );
  }
}

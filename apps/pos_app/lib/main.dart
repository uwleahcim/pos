import 'package:flutter/material.dart';

import 'api.dart';
import 'outbox.dart';
import 'screens/orders_screen.dart';
import 'screens/settings_screen.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final api = PosApi(settings);
  final outbox = Outbox(api, settings);
  await outbox.restore();
  runApp(PosApp(settings: settings, api: api, outbox: outbox));
}

class PosApp extends StatelessWidget {
  const PosApp({super.key, required this.settings, required this.api, required this.outbox});

  final Settings settings;
  final PosApi api;
  final Outbox outbox;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'POS',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFB3261E), useMaterial3: true),
      home: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => settings.isConfigured
            ? OrdersScreen(api: api, outbox: outbox, settings: settings)
            : SettingsScreen(settings: settings, firstRun: true),
      ),
    );
  }
}

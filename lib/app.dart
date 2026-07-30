import 'package:flutter/material.dart';

import 'models/store_map.dart';
import 'services/ble_scanner_service.dart';
import 'services/navigation_controller.dart';
import 'services/store_data_repository.dart';
import 'ui/screens/map_screen.dart';

class IndoorNavApp extends StatelessWidget {
  const IndoorNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Indoor Navigation',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: FutureBuilder<StoreMap>(
        future: StoreDataRepository().loadStoreMap(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _ErrorScreen(error: snapshot.error.toString());
          }
          final storeMap = snapshot.data;
          if (storeMap == null) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final controller = NavigationController(
            storeMap: storeMap,
            bleScanner: BleScannerService(),
          );
          return MapScreen(controller: controller);
        },
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('Failed to load store map:\n$error')),
    );
  }
}

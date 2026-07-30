import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class _TimedRssi {
  final DateTime time;
  final int rssi;
  _TimedRssi(this.time, this.rssi);
}

/// Scans for nearby BLE beacons and emits a rolling 3s average RSSI per
/// device id. Consumers (see [ZoneSnapService]) turn this into a location.
class BleScannerService {
  BleScannerService({
    FlutterReactiveBle? ble,
    this.rollingWindow = const Duration(seconds: 3),
  }) : _ble = ble ?? FlutterReactiveBle();

  final FlutterReactiveBle _ble;
  final Duration rollingWindow;

  final Map<String, List<_TimedRssi>> _readings = {};
  final _rssiController = StreamController<Map<String, double>>.broadcast();
  StreamSubscription<DiscoveredDevice>? _scanSub;

  /// Averaged RSSI per BLE device id, updated on every scan result.
  Stream<Map<String, double>> get rssiStream => _rssiController.stream;

  void startScan() {
    _scanSub?.cancel();
    _scanSub = _ble.scanForDevices(withServices: []).listen(_onDeviceSeen);
  }

  void _onDeviceSeen(DiscoveredDevice device) {
    final now = DateTime.now();
    final history = _readings.putIfAbsent(device.id, () => []);
    history.add(_TimedRssi(now, device.rssi));
    history.removeWhere((r) => now.difference(r.time) > rollingWindow);

    _rssiController.add(_averagedRssi());
  }

  Map<String, double> _averagedRssi() {
    final now = DateTime.now();
    final result = <String, double>{};
    for (final entry in _readings.entries) {
      final recent = entry.value
          .where((r) => now.difference(r.time) <= rollingWindow)
          .toList();
      if (recent.isEmpty) continue;
      final avg = recent.map((r) => r.rssi).reduce((a, b) => a + b) / recent.length;
      result[entry.key] = avg;
    }
    return result;
  }

  void stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
  }

  void dispose() {
    stopScan();
    _rssiController.close();
  }
}

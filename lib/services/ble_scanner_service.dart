import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class _TimedRssi {
  final DateTime time;
  final int rssi;
  _TimedRssi(this.time, this.rssi);
}

/// Scans for nearby iBeacons and emits a rolling 3s average RSSI per
/// iBeacon proximity UUID. Consumers (see [ZoneSnapService]) turn this into
/// a location.
///
/// Beacons are matched by the proximity UUID carried inside the BLE
/// advertisement's manufacturer data, NOT by [DiscoveredDevice.id] — that id
/// is the scanning OS's address for the radio (a MAC on Android, an
/// OS-assigned identifier on iOS), which has no relationship to the iBeacon
/// UUID configured on the physical beacon.
class BleScannerService {
  BleScannerService({
    FlutterReactiveBle? ble,
    this.rollingWindow = const Duration(seconds: 3),
  }) : _ble = ble;

  FlutterReactiveBle? _ble;
  final Duration rollingWindow;

  final Map<String, List<_TimedRssi>> _readings = {};
  final _rssiController = StreamController<Map<String, double>>.broadcast();
  StreamSubscription<DiscoveredDevice>? _scanSub;

  /// Averaged RSSI per iBeacon proximity UUID, updated on every scan result.
  Stream<Map<String, double>> get rssiStream => _rssiController.stream;

  void startScan() {
    if (_ble == null && (Platform.isAndroid || Platform.isIOS)) {
      _ble = FlutterReactiveBle();
    }
    if (_ble == null) return;
    _scanSub?.cancel();
    _scanSub = _ble!.scanForDevices(withServices: []).listen(_onDeviceSeen);
  }

  void _onDeviceSeen(DiscoveredDevice device) {
    final uuid = parseIBeaconUuid(device.manufacturerData);
    if (uuid == null) return; // Not an iBeacon advertisement — ignore.

    final now = DateTime.now();
    final history = _readings.putIfAbsent(uuid, () => []);
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

/// Extracts the proximity UUID from an iBeacon advertisement's manufacturer
/// data (Apple company id 0x004C, iBeacon type 0x02), or null if [data]
/// isn't a valid iBeacon payload. Returns a lowercase, hyphenated UUID
/// string, e.g. "01020304-0506-0708-090a-0b0c0d0e0f10".
String? parseIBeaconUuid(Uint8List data) {
  if (data.length < 24) return null;
  final isAppleCompanyId = data[0] == 0x4C && data[1] == 0x00;
  final isIBeaconType = data[2] == 0x02 && data[3] == 0x15;
  if (!isAppleCompanyId || !isIBeaconType) return null;

  final uuidBytes = data.sublist(4, 20);
  final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
}
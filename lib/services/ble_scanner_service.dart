import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final _errorController = StreamController<String>.broadcast();
  StreamSubscription<DiscoveredDevice>? _scanSub;

  /// Averaged RSSI per iBeacon proximity UUID, updated on every scan result.
  Stream<Map<String, double>> get rssiStream => _rssiController.stream;

  /// Human-readable reasons scanning couldn't start or was interrupted —
  /// e.g. a denied permission or disabled Bluetooth adapter. Surfaced here
  /// instead of failing silently, since a scan that finds nothing looks
  /// identical to a scan that never started.
  Stream<String> get errors => _errorController.stream;

  Future<void> startScan() async {
    if (_ble == null && (Platform.isAndroid || Platform.isIOS)) {
      _ble = FlutterReactiveBle();
    }
    if (_ble == null) return;

    final permissionError = await _ensurePermissions();
    if (permissionError != null) {
      _errorController.add(permissionError);
      return;
    }

    _scanSub?.cancel();
    _scanSub = _ble!.scanForDevices(withServices: []).listen(
          _onDeviceSeen,
          onError: (Object e) => _errorController.add('BLE scan error: $e'),
        );
  }

  /// Requests the permissions BLE scanning needs on this platform. Returns
  /// null if everything required is granted, otherwise a message describing
  /// what's missing.
  Future<String?> _ensurePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      final denied = statuses.entries.where((e) => !e.value.isGranted).map((e) => e.key.toString());
      if (denied.isNotEmpty) {
        return 'Missing permissions: ${denied.join(', ')}. Grant them in system settings.';
      }
      return null;
    }
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      if (!status.isGranted) {
        return 'Bluetooth permission denied. Grant it in Settings > Privacy > Bluetooth.';
      }
      return null;
    }
    return null;
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
    _errorController.close();
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
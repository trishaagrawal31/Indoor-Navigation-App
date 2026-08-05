import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

class _TimedRssi {
  final DateTime time;
  final int rssi;
  _TimedRssi(this.time, this.rssi);
}

/// Scans for nearby beacons and emits a rolling 3s average RSSI per beacon
/// identity. Consumers (see [ZoneSnapService]) turn this into a location.
///
/// A beacon's identity is derived in [_onDeviceSeen], preferring (in order):
/// 1. iBeacon proximity UUID + major + minor, parsed from the
///    advertisement's manufacturer data — the standard for dedicated beacon
///    hardware, and unique even across a fleet sharing one UUID.
/// 2. The first advertised 128-bit service UUID, for devices that
///    advertise a distinctive service UUID but aren't iBeacon-formatted
///    (e.g. as a stand-in beacon during testing, or hardware using a
///    GATT-service-based scheme instead of iBeacon).
/// Never [DiscoveredDevice.id] — that's the scanning radio's own address
/// (a MAC on Android), unrelated to how a beacon identifies itself.
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

  /// Averaged RSSI per beacon identity ("uuid:major:minor"), updated on
  /// every scan result.
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
    // lowLatency maximizes scan duty cycle (vs the balanced/lowPower
    // defaults), which matters for beacons with a sparse advertising
    // interval — nRF Connect and similar dedicated scanner apps tend to
    // scan more aggressively by default, which is why they can see a
    // beacon our previous default scan mode missed.
    _scanSub = _ble!.scanForDevices(withServices: [], scanMode: ScanMode.lowLatency).listen(
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
    final beacon = parseIBeacon(device.manufacturerData);
    final key = beacon?.key ??
        (device.serviceUuids.isNotEmpty ? device.serviceUuids.first.toString().toLowerCase() : null);

    // TEMPORARY DIAGNOSTIC LOGGING — remove once detection is confirmed
    // working end-to-end. Dumps every BLE advertisement seen, regardless of
    // whether it resolved to a beacon identity, so you can see in
    // `flutter run`'s console exactly what's nearby (id, rssi, raw
    // manufacturer data, and any service data / advertised service UUIDs).
    debugPrint(
      '[BLE] id=${device.id} name="${device.name}" rssi=${device.rssi} '
      'manufacturerData=${_hex(device.manufacturerData)} '
      'serviceUuids=${device.serviceUuids} '
      'serviceData=${device.serviceData.map((k, v) => MapEntry(k, _hex(v)))} '
      'parsedIBeacon=$beacon resolvedKey=$key',
    );

    if (key == null) return; // No iBeacon data and no service UUID to key on.

    final now = DateTime.now();
    final history = _readings.putIfAbsent(key, () => []);
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

String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

class IBeacon {
  final String uuid;
  final int major;
  final int minor;
  const IBeacon({required this.uuid, required this.major, required this.minor});

  /// Store-data-compatible identity string, e.g.
  /// "01020304-0506-0708-090a-0b0c0d0e0f10:256:1".
  String get key => '$uuid:$major:$minor';

  @override
  String toString() => key;
}

/// Parses an iBeacon advertisement's manufacturer data (Apple company id
/// 0x004C, iBeacon type 0x02) into its proximity UUID, major, and minor, or
/// null if [data] isn't a valid iBeacon payload.
IBeacon? parseIBeacon(Uint8List data) {
  if (data.length < 24) return null;
  final isAppleCompanyId = data[0] == 0x4C && data[1] == 0x00;
  final isIBeaconType = data[2] == 0x02 && data[3] == 0x15;
  if (!isAppleCompanyId || !isIBeaconType) return null;

  final uuidBytes = data.sublist(4, 20);
  final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  final major = (data[20] << 8) | data[21];
  final minor = (data[22] << 8) | data[23];
  return IBeacon(uuid: uuid, major: major, minor: minor);
}
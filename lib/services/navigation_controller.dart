import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/beacon.dart';
import '../models/store_map.dart';
import 'ble_scanner_service.dart';
import 'pathfinding_service.dart';
import 'zone_snap_service.dart';

/// Central MVP state: current zone (from BLE), chosen destination, and the
/// resulting route. Rebuilds the UI via [ChangeNotifier] whenever any of
/// those change.
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.storeMap,
    required this.bleScanner,
    ZoneSnapService? zoneSnap,
    PathfindingService? pathfinder,
  })  : _zoneSnap = zoneSnap ?? ZoneSnapService(),
        _pathfinder = pathfinder ?? PathfindingService() {
    _rssiSub = bleScanner.rssiStream.listen(_onRssiUpdate);
  }

  final StoreMap storeMap;
  final BleScannerService bleScanner;
  final ZoneSnapService _zoneSnap;
  final PathfindingService _pathfinder;
  StreamSubscription<Map<String, double>>? _rssiSub;

  Beacon? currentBeacon;
  Beacon? destinationBeacon;
  List<Beacon> currentPath = [];

  void start() => bleScanner.startScan();

  void setDestination(Beacon beacon) {
    destinationBeacon = beacon;
    _recomputePath();
    notifyListeners();
  }

  void clearDestination() {
    destinationBeacon = null;
    currentPath = [];
    notifyListeners();
  }

  void _onRssiUpdate(Map<String, double> rssiByBleId) {
    final nearest = _zoneSnap.nearestBeacon(rssiByBleId, storeMap);
    if (nearest == null || nearest.id == currentBeacon?.id) return;

    currentBeacon = nearest;
    _recomputePath();
    notifyListeners();
  }

  void _recomputePath() {
    final start = currentBeacon;
    final end = destinationBeacon;
    currentPath = (start != null && end != null)
        ? _pathfinder.findPath(storeMap, start.id, end.id)
        : [];
  }

  @override
  void dispose() {
    _rssiSub?.cancel();
    bleScanner.dispose();
    super.dispose();
  }
}

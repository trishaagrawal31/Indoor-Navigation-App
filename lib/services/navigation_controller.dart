import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../models/beacon.dart';
import '../models/store_map.dart';
import 'ble_scanner_service.dart';
import 'motion_service.dart';
import 'pathfinding_service.dart';
import 'zone_snap_service.dart';

/// Central MVP state: current zone (from BLE), chosen destination, the
/// resulting route, and the live PDR-tracked position. Rebuilds the UI via
/// [ChangeNotifier] whenever any of those change.
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.storeMap,
    required this.bleScanner,
    required this.motionService,
    ZoneSnapService? zoneSnap,
    PathfindingService? pathfinder,
  })  : _zoneSnap = zoneSnap ?? ZoneSnapService(),
        _pathfinder = pathfinder ?? PathfindingService() {
    _rssiSub = bleScanner.rssiStream.listen(_onRssiUpdate);
    _stepSub = motionService.positionDeltas.listen(_onStepDelta);
    _headingSub = motionService.headingStream.listen(_onHeading);
  }

  final StoreMap storeMap;
  final BleScannerService bleScanner;
  final MotionService motionService;
  final ZoneSnapService _zoneSnap;
  final PathfindingService _pathfinder;
  StreamSubscription<Map<String, double>>? _rssiSub;
  StreamSubscription<Offset>? _stepSub;
  StreamSubscription<double>? _headingSub;

  Beacon? currentBeacon;
  Beacon? destinationBeacon;
  List<Beacon> currentPath = [];

  /// Live PDR-tracked position (map units) — reset to the current beacon's
  /// position on every new zone-snap fix, and nudged forward by each
  /// detected step in between. Null until the first beacon fix or step.
  Offset? liveUserPosition;

  /// Live compass heading (degrees, 0 = North), for arrow rotation.
  double? headingDegrees;

  void start() {
    bleScanner.startScan();
    motionService.start();
  }

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
    liveUserPosition = nearest.position; // Anchor PDR drift back to the new fix.
    _recomputePath();
    notifyListeners();
  }

  void _onStepDelta(Offset delta) {
    final base = liveUserPosition ?? currentBeacon?.position;
    if (base == null) return; // No fix yet to walk from.
    liveUserPosition = base + delta;
    notifyListeners();
  }

  void _onHeading(double heading) {
    headingDegrees = heading;
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
    _stepSub?.cancel();
    _headingSub?.cancel();
    bleScanner.dispose();
    motionService.dispose();
    super.dispose();
  }
}

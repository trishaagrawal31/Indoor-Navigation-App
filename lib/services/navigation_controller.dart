import 'dart:async';
import 'dart:math' as math;
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

  /// Only a beacon fix at least this strong (dBm) is trusted to
  /// **recalibrate** the PDR position — i.e. actually snap
  /// [liveUserPosition] to the beacon's exact location. `currentBeacon`
  /// itself (used for the "You are near" text and as the pathfinding
  /// start) still updates on any change, weak or not; this only gates the
  /// harder "teleport the live arrow" behavior, which is what was making
  /// the arrow visibly jump whenever two weak, similar-strength beacons
  /// flapped back and forth as "nearest".
  static const double _recalibrationMinRssi = -70.0;

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

  /// Total distance of [currentPath], in meters. Null when there's no route.
  double? currentDistanceMeters;

  /// Live PDR-tracked position (map units) — reset to the current beacon's
  /// position whenever a *strong* zone-snap fix comes in (see
  /// [_recalibrationMinRssi]), and nudged forward by each detected step in
  /// between. Null until the first fix or step.
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
    currentDistanceMeters = null;
    notifyListeners();
  }

  void _onRssiUpdate(Map<String, double> rssiByBleId) {
    final nearest = _zoneSnap.nearestBeacon(rssiByBleId, storeMap);
    if (nearest == null || nearest.id == currentBeacon?.id) return;

    currentBeacon = nearest;
    _recomputePath();

    final strongestRssi = rssiByBleId.values.fold<double>(double.negativeInfinity, math.max);
    if (strongestRssi >= _recalibrationMinRssi) {
      liveUserPosition = nearest.position; // Anchor PDR drift back to a confident fix.
    }

    notifyListeners();
  }

  void _onStepDelta(Offset delta) {
    final base = liveUserPosition ?? currentBeacon?.position;
    if (base == null) return; // No fix yet to walk from.
    // Clamp onto the corridor graph — free 2D dead reckoning would
    // otherwise happily drift into room interiors, which have no edges.
    liveUserPosition = storeMap.snapToGraph(base + delta);
    notifyListeners();
  }

  void _onHeading(double heading) {
    headingDegrees = heading;
    notifyListeners();
  }

  void _recomputePath() {
    final start = currentBeacon;
    final end = destinationBeacon;
    if (start == null || end == null) {
      currentPath = [];
      currentDistanceMeters = null;
      return;
    }
    final result = _pathfinder.findPath(storeMap, start.id, end.id);
    currentPath = result.path;
    currentDistanceMeters = result.path.length >= 2 ? result.distanceUnits * storeMap.metersPerUnit : null;
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

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

  /// How far (0-1) each new BLE position estimate (see
  /// [ZoneSnapService.estimatePosition]) pulls [liveUserPosition] toward
  /// it, rather than snapping straight to it. Weak/noisy estimates already
  /// carry little weight in the centroid itself, so this just keeps the
  /// *correction* gradual too — reads as continuously walking with drift
  /// being nudged out, not a teleport, every time a fix arrives.
  static const double _bleCorrectionFactor = 0.35;

  /// A newly-"nearest" beacon must win this many consecutive RSSI updates
  /// before it's actually committed to [currentBeacon] — a single noisy
  /// reading was enough to flip zones (and misreport which beacon you were
  /// near) without this.
  static const int _requiredConsecutiveReadings = 2;

  final StoreMap storeMap;
  final BleScannerService bleScanner;
  final MotionService motionService;
  final ZoneSnapService _zoneSnap;
  final PathfindingService _pathfinder;
  StreamSubscription<Map<String, double>>? _rssiSub;
  StreamSubscription<Offset>? _stepSub;
  StreamSubscription<double>? _headingSub;

  String? _pendingBeaconId;
  int _pendingBeaconCount = 0;
  Edge? _lastSnappedEdge;

  Beacon? currentBeacon;
  Beacon? destinationBeacon;
  List<Beacon> currentPath = [];

  /// Total distance of [currentPath], in meters. Null when there's no route.
  double? currentDistanceMeters;

  /// Live PDR-tracked position (map units) — eased toward each new BLE
  /// position estimate (see [_bleCorrectionFactor]) to correct drift, and
  /// nudged forward by each detected step in between. Null until the
  /// first fix or step.
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
    if (nearest == null) return;

    var beaconChanged = false;
    if (nearest.id == currentBeacon?.id) {
      _pendingBeaconId = null;
      _pendingBeaconCount = 0;
    } else {
      // Require a candidate to win this many consecutive updates before
      // committing to it — a single noisy RSSI reading was enough to flip
      // zones otherwise.
      if (nearest.id == _pendingBeaconId) {
        _pendingBeaconCount++;
      } else {
        _pendingBeaconId = nearest.id;
        _pendingBeaconCount = 1;
      }
      if (_pendingBeaconCount >= _requiredConsecutiveReadings) {
        currentBeacon = nearest;
        _pendingBeaconId = null;
        _pendingBeaconCount = 0;
        beaconChanged = true;
      }
    }
    if (beaconChanged) _recomputePath();

    // Blend toward the multi-beacon position estimate every update — not
    // just on a zone flip — so BLE correction and PDR stepping both feed
    // one continuously-moving position instead of PDR-drift-then-teleport.
    final estimate = _zoneSnap.estimatePosition(rssiByBleId, storeMap);
    if (estimate != null) {
      final snapped = storeMap.snapToGraph(estimate, preferredEdge: _lastSnappedEdge);
      liveUserPosition = liveUserPosition == null
          ? snapped.point
          : Offset.lerp(liveUserPosition, snapped.point, _bleCorrectionFactor);
      _lastSnappedEdge = snapped.edge;
    }

    notifyListeners();
  }

  void _onStepDelta(Offset delta) {
    final base = liveUserPosition ?? currentBeacon?.position;
    if (base == null) return; // No fix yet to walk from.
    // Clamp onto the corridor graph — free 2D dead reckoning would
    // otherwise happily drift into room interiors, which have no edges.
    final snapped = storeMap.snapToGraph(base + delta, preferredEdge: _lastSnappedEdge);
    liveUserPosition = snapped.point;
    _lastSnappedEdge = snapped.edge;
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
    // >= 1, not >= 2: a 1-beacon path means "arrived" (start == destination)
    // and should show 0 m, not disappear — a null here previously made
    // MapPainter hide the distance/pin/everything, as if there were no
    // route at all.
    currentDistanceMeters = result.path.isNotEmpty ? result.distanceUnits * storeMap.metersPerUnit : null;
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

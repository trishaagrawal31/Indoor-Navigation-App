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
    _stepSub = motionService.stepDistances.listen(_onStepDistance);
    _headingSub = motionService.headingStream.listen(_onHeading);
  }

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
  StreamSubscription<double>? _stepSub;
  StreamSubscription<double>? _headingSub;

  String? _pendingBeaconId;
  int _pendingBeaconCount = 0;
  Edge? _lastSnappedEdge;

  Beacon? currentBeacon;
  Beacon? destinationBeacon;
  List<Beacon> currentPath = [];

  /// Total distance of [currentPath], in meters. Null when there's no route.
  double? currentDistanceMeters;

  /// Live PDR-tracked position (map units) — reset to the current beacon's
  /// position whenever a confirmed zone-snap fix comes in, and nudged
  /// forward by each detected step in between. Null until the first fix
  /// or step.
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
    // nearestBeacon is the beacon closest to the RSSI-weighted centroid of
    // every visible beacon (see ZoneSnapService), not just whichever one
    // reads loudest — that's what makes the *node it jumps to* accurate.
    final nearest = _zoneSnap.nearestBeacon(rssiByBleId, storeMap);
    if (nearest == null) return;

    if (nearest.id == currentBeacon?.id) {
      _pendingBeaconId = null;
      _pendingBeaconCount = 0;
      return;
    }

    // Require a candidate to win this many consecutive updates before
    // committing to it — a single noisy RSSI reading was enough to flip
    // zones otherwise.
    if (nearest.id == _pendingBeaconId) {
      _pendingBeaconCount++;
    } else {
      _pendingBeaconId = nearest.id;
      _pendingBeaconCount = 1;
    }
    if (_pendingBeaconCount < _requiredConsecutiveReadings) return;

    currentBeacon = nearest;
    _pendingBeaconId = null;
    _pendingBeaconCount = 0;
    _recomputePath();

    // Jump straight to the confirmed beacon's node. A blended/interpolated
    // position (tried previously) overshot toward whatever beacon was
    // merely in range — including the destination's — rather than
    // reflecting the node debouncing actually confirmed you'd reached.
    liveUserPosition = nearest.position;
    _lastSnappedEdge = null; // Fresh anchor — let the next step pick a natural starting edge.

    notifyListeners();
  }

  void _onStepDistance(double distanceMeters) {
    final base = liveUserPosition ?? currentBeacon?.position;
    if (base == null) return; // No fix yet to walk from.

    final distanceUnits = distanceMeters / storeMap.metersPerUnit;
    final delta = _stepDirection(base, distanceUnits);
    if (delta == null) return; // No route, and no heading yet either — nothing to go on.

    // Clamp onto the corridor graph — even path-aimed movement can cut a
    // straight-line corner through a room interior, which has no edges.
    final snapped = storeMap.snapToGraph(base + delta, preferredEdge: _lastSnappedEdge);
    liveUserPosition = snapped.point;
    _lastSnappedEdge = snapped.edge;
    notifyListeners();
  }

  /// Which way to advance this step. Indoor compass headings are noisy
  /// (see [MotionService]) — when there's an active route, walking toward
  /// the next waypoint on it is far more reliable than trusting raw
  /// heading, and it's what keeps the pin moving along the path the user
  /// actually asked to follow. Falls back to compass/gyro heading only
  /// when there's no route to aim at.
  Offset? _stepDirection(Offset base, double distanceUnits) {
    final target = _nextRouteWaypoint();
    if (target != null) {
      final toTarget = target - base;
      final distance = toTarget.distance;
      return distance == 0 ? Offset.zero : toTarget / distance * distanceUnits;
    }

    final heading = headingDegrees;
    if (heading == null) return null;
    final theta = (heading - storeMap.mapNorthOffsetDegrees) * math.pi / 180;
    return Offset(distanceUnits * math.sin(theta), -distanceUnits * math.cos(theta));
  }

  /// The beacon immediately after [currentBeacon] on [currentPath] — null
  /// if there's no active route, or [currentBeacon] isn't on it, or it's
  /// already the destination (nothing further to walk toward).
  Offset? _nextRouteWaypoint() {
    final path = currentPath;
    final cb = currentBeacon;
    if (path.length < 2 || cb == null) return null;
    final index = path.indexWhere((b) => b.id == cb.id);
    if (index == -1 || index >= path.length - 1) return null;
    return path[index + 1].position;
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

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

  /// Assumed walking pace (m/s) [liveUserPosition] glides toward
  /// [_targetPosition] at, instead of teleporting straight to it whenever
  /// PDR steps or a confirmed beacon fix move the target. This is what
  /// makes movement read as continuous walking rather than discrete jumps
  /// — between nodes (PDR updates the target in small increments already)
  /// and at nodes (a BLE-confirmed fix can move the target further in one
  /// go, but the pin still glides there rather than teleporting).
  static const double _walkingSpeedMetersPerSecond = 1.3;

  static const Duration _followTickInterval = Duration(milliseconds: 80);

  final StoreMap storeMap;
  final BleScannerService bleScanner;
  final MotionService motionService;
  final ZoneSnapService _zoneSnap;
  final PathfindingService _pathfinder;
  StreamSubscription<Map<String, double>>? _rssiSub;
  StreamSubscription<double>? _stepSub;
  StreamSubscription<double>? _headingSub;
  Timer? _followTimer;
  DateTime? _lastFollowTick;

  String? _pendingBeaconId;
  int _pendingBeaconCount = 0;
  Edge? _lastSnappedEdge;

  Beacon? currentBeacon;
  Beacon? destinationBeacon;
  List<Beacon> currentPath = [];

  /// Total distance of [currentPath], in meters. Null when there's no route.
  double? currentDistanceMeters;

  /// Where PDR steps and confirmed BLE fixes say the user actually is
  /// (map units) — updated instantly, but not drawn directly; see
  /// [liveUserPosition].
  Offset? _targetPosition;

  /// The drawn/tracked live position (map units) — continuously eased
  /// toward [_targetPosition] at [_walkingSpeedMetersPerSecond] by
  /// [_advanceTowardTarget], so both PDR stepping *and* a beacon
  /// confirming you've reached the next node read as one continuous walk
  /// rather than a teleport at each node. Null until the first fix or step.
  Offset? liveUserPosition;

  /// Live compass heading (degrees, 0 = North), for arrow rotation.
  double? headingDegrees;

  void start() {
    bleScanner.startScan();
    motionService.start();
    _followTimer ??= Timer.periodic(_followTickInterval, (_) => _advanceTowardTarget());
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

    // Move the *target* to the confirmed beacon's node — liveUserPosition
    // still glides there via _advanceTowardTarget rather than teleporting,
    // so a node confirmation reads as arriving, not jumping.
    _targetPosition = nearest.position;
    _lastSnappedEdge = null; // Fresh anchor — let the next step pick a natural starting edge.

    notifyListeners();
  }

  void _onStepDistance(double distanceMeters) {
    final base = _targetPosition ?? currentBeacon?.position;
    if (base == null) return; // No fix yet to walk from.

    final distanceUnits = distanceMeters / storeMap.metersPerUnit;
    final delta = _stepDirection(base, distanceUnits);
    if (delta == null) return; // No route, and no heading yet either — nothing to go on.

    // Clamp onto the corridor graph — even path-aimed movement can cut a
    // straight-line corner through a room interior, which has no edges.
    final snapped = storeMap.snapToGraph(base + delta, preferredEdge: _lastSnappedEdge);
    _targetPosition = snapped.point;
    _lastSnappedEdge = snapped.edge;
    // liveUserPosition itself is advanced by _advanceTowardTarget on its
    // own ticker, not here — that's what keeps it moving continuously
    // between step events instead of jumping once per detected step.
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

  /// Eases [liveUserPosition] toward [_targetPosition] at a capped walking
  /// pace, ticked every [_followTickInterval] — the single mechanism that
  /// turns every discrete position update (a PDR step, or a beacon
  /// confirming a new node) into continuous, live motion on screen.
  void _advanceTowardTarget() {
    final target = _targetPosition;
    if (target == null) return;

    final current = liveUserPosition;
    if (current == null) {
      // Nothing to glide from yet — the very first fix appears immediately.
      liveUserPosition = target;
      _lastFollowTick = DateTime.now();
      notifyListeners();
      return;
    }

    final now = DateTime.now();
    final last = _lastFollowTick;
    _lastFollowTick = now;
    final dtSeconds =
        last == null ? _followTickInterval.inMilliseconds / 1000 : now.difference(last).inMicroseconds / 1e6;

    final toTarget = target - current;
    final remaining = toTarget.distance;
    if (remaining < 0.001) return; // Already there — nothing to animate.

    final maxMoveUnits = (_walkingSpeedMetersPerSecond / storeMap.metersPerUnit) * dtSeconds;
    final moveBy = math.min(maxMoveUnits, remaining);
    final next = current + toTarget / remaining * moveBy;

    final snapped = storeMap.snapToGraph(next, preferredEdge: _lastSnappedEdge);
    liveUserPosition = snapped.point;
    _lastSnappedEdge = snapped.edge;
    notifyListeners();
  }

  void _onHeading(double heading) {
    headingDegrees = heading;
    notifyListeners();
  }

  /// Recomputes [currentPath]/[currentDistanceMeters] for the current
  /// [currentBeacon] → [destinationBeacon] pair. Deliberately leaves the
  /// existing route on screen untouched if there's no beacon fix yet or no
  /// path could be found — the route should only ever go away because the
  /// user cleared it ([clearDestination]) or picked a different
  /// destination ([setDestination]), never because of a transient
  /// recompute glitch mid-walk.
  void _recomputePath() {
    final start = currentBeacon;
    final end = destinationBeacon;
    if (end == null) return; // clearDestination() already blanked currentPath itself.
    if (start == null) return; // No beacon fix yet — keep whatever was last shown.

    final result = _pathfinder.findPath(storeMap, start.id, end.id);
    if (result.path.isEmpty) return; // No route found — keep the last known-good one rather than hiding it.

    currentPath = result.path;
    currentDistanceMeters = result.distanceUnits * storeMap.metersPerUnit;
  }

  @override
  void dispose() {
    _rssiSub?.cancel();
    _stepSub?.cancel();
    _headingSub?.cancel();
    _followTimer?.cancel();
    bleScanner.dispose();
    motionService.dispose();
    super.dispose();
  }
}

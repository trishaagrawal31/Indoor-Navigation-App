import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/beacon.dart';
import '../models/store_map.dart';

/// Turns a set of averaged RSSI readings into a location. RSSI is in dBm
/// (negative; closer to 0 = stronger signal = nearer).
///
/// Rather than snapping to whichever single beacon reads strongest — noisy
/// indoors, since a farther beacon can transiently out-read a closer one
/// through multipath/interference — [estimatePosition] blends *all*
/// currently-visible beacons into one weighted position, the same approach
/// mall/venue nav apps use. That both gives a continuous position (it
/// shifts smoothly as relative signal strengths change, instead of
/// jumping beacon-to-beacon) and makes misreads less likely (one noisy
/// strong reading is outvoted by the other beacons still in range).
class ZoneSnapService {
  /// Beacons weaker than this are excluded entirely — too far/unreliable
  /// to trust even as a minor contributor to the estimate.
  static const double _minRssiFloor = -85.0;

  /// RSSI-weighted centroid of every visible beacon's position, or null if
  /// none are above [_minRssiFloor].
  Offset? estimatePosition(Map<String, double> rssiByBleId, StoreMap storeMap) {
    var weightSum = 0.0;
    var x = 0.0;
    var y = 0.0;

    for (final entry in rssiByBleId.entries) {
      if (entry.value < _minRssiFloor) continue;
      final beacon = storeMap.beaconByBleId(entry.key);
      if (beacon == null) continue;

      final weight = _weightFor(entry.value);
      weightSum += weight;
      x += beacon.position.dx * weight;
      y += beacon.position.dy * weight;
    }

    if (weightSum == 0) return null;
    return Offset(x / weightSum, y / weightSum);
  }

  /// Converts dBm to a linear weight so stronger (closer) beacons dominate
  /// the centroid while weaker ones still nudge it — RSSI is logarithmic,
  /// so averaging the dBm values directly wouldn't track physical distance
  /// the way linear signal power does.
  double _weightFor(double rssi) => math.pow(10, rssi / 10).toDouble();

  /// The known beacon nearest [estimatePosition]'s result — used for the
  /// "You are near" label and as the pathfinding start node, both of which
  /// need a discrete beacon rather than a continuous point.
  Beacon? nearestBeacon(Map<String, double> rssiByBleId, StoreMap storeMap) {
    final estimate = estimatePosition(rssiByBleId, storeMap);
    if (estimate == null) return null;

    Beacon? nearest;
    var bestDistanceSquared = double.infinity;
    for (final beacon in storeMap.beacons) {
      final d = (beacon.position - estimate).distanceSquared;
      if (d < bestDistanceSquared) {
        bestDistanceSquared = d;
        nearest = beacon;
      }
    }
    return nearest;
  }
}

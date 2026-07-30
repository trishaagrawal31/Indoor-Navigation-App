import '../models/beacon.dart';
import '../models/store_map.dart';

/// Snaps a set of averaged RSSI readings to the nearest known beacon.
/// RSSI is in dBm (negative; closer to 0 = stronger signal = nearer).
class ZoneSnapService {
  Beacon? nearestBeacon(Map<String, double> rssiByBleId, StoreMap storeMap) {
    String? strongestBleId;
    double? strongestRssi;

    for (final entry in rssiByBleId.entries) {
      if (strongestRssi == null || entry.value > strongestRssi) {
        strongestRssi = entry.value;
        strongestBleId = entry.key;
      }
    }

    if (strongestBleId == null) return null;
    return storeMap.beaconByBleId(strongestBleId);
  }
}

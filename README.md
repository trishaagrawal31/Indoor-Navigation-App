# Indoor Navigation — MVP Skeleton

BLE beacon → RSSI scan → zone snap → Dijkstra pathfinding → SVG map render → UI.

## Architecture

```
lib/
  models/
    beacon.dart            Beacon (id, bleId, name, position)
    store_map.dart          StoreMap + Edge, loaded from store_data.json
  services/
    store_data_repository.dart   Loads assets/store_data.json
    ble_scanner_service.dart     flutter_reactive_ble scan, 3s rolling RSSI avg
    zone_snap_service.dart       Strongest RSSI -> nearest beacon
    pathfinding_service.dart     Dijkstra over the beacon graph
    navigation_controller.dart   Wires the above into app state (ChangeNotifier)
  ui/
    screens/map_screen.dart      SVG map + destination picker + directions
    widgets/map_painter.dart     CustomPainter: user pin + route overlay
  app.dart / main.dart
assets/
  store_data.json           Beacon coords + aisle graph (edit this per store)
  map.svg                   Placeholder floor plan (replace with the real one)
```

## Setup

This directory currently has only the Dart source, not a full Flutter
project scaffold (no `android/`/`ios/` folders). Generate those with:

```
flutter create .
flutter pub get
```

BLE requires platform permissions that `flutter create` won't add for you:

- **Android** (`android/app/src/main/AndroidManifest.xml`): add
  `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and (for scan results on most
  devices) `ACCESS_FINE_LOCATION`.
- **iOS** (`ios/Runner/Info.plist`): add `NSBluetoothAlwaysUsageDescription`.

See the [flutter_reactive_ble](https://pub.dev/packages/flutter_reactive_ble)
docs for exact manifest/plist snippets.

## Wiring real beacons

Edit `assets/store_data.json`:
- `beacons[].bleId` must match the BLE device id/MAC each physical beacon
  advertises.
- `beacons[].x/y` and `mapWidth`/`mapHeight` are in the same coordinate
  space as `assets/map.svg`.
- `edges` describe walkable aisle connections and their distance/weight;
  the pathfinder treats them as undirected.

## Notes / MVP shortcuts

- Zone snap picks the single strongest beacon rather than trilaterating —
  fine for aisle-level granularity, not sub-meter precision.
- Pathfinding is a plain O(V²) Dijkstra, which is fine for a graph sized to
  a store's aisle endpoints (tens of nodes).
- No state management library — `NavigationController` is a single
  `ChangeNotifier` consumed via `AnimatedBuilder`.

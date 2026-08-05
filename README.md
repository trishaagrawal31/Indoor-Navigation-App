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
  floorMap.svg               Real floor plan, 297x210 (landscape) coordinate space
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
- `beacons[].bleId` must be the beacon's **iBeacon proximity UUID** (the
  UUID configured on the physical beacon / in its vendor app), not a
  Bluetooth MAC address — `BleScannerService` parses this out of the
  advertisement's manufacturer data (`lib/services/ble_scanner_service.dart`,
  `parseIBeaconUuid`). Only `b1` currently has a real UUID (confirmed
  working); `b2`–`b4` still have obviously-fake placeholder UUIDs
  (`00000000-...-0000000000N`) — replace those once you deploy those
  beacons. If your beacons broadcast major/minor values instead of distinct
  UUIDs, you'll need to extend the parser to key on UUID+major+minor.
- `beacons[].x/y` and `mapWidth`/`mapHeight` are in the same coordinate
  space as `assets/floorMap.svg`'s `viewBox` (currently `0 0 297 210`).
- `beacons[].x/y` for `b1`–`b4` are **estimated** corridor positions,
  computed from the gaps between the room rectangles in `floorMap.svg`
  (beacons are mounted on the walkway between rooms, not inside them) —
  adjust to match actual mounting locations once surveyed.
- `edges` describe walkable aisle connections and their distance/weight;
  the pathfinder treats them as undirected.

If you later mount a beacon inside/near one of the 7 labeled rooms
(ChatGPT Meeting Room, Safari Room, Gemma Room, SOC Room, Seating Area 1,
Seating Area 2, Breakout Room) instead of the walkway, add a beacon entry
for it and wire it into `edges` the same way.

## Troubleshooting: map stuck on the loading spinner

`MapScreen` shows a `CircularProgressIndicator` (via `placeholderBuilder`)
until `floorMap.svg` resolves, and now shows a red error message (via
`errorBuilder`) if it fails to parse instead of spinning forever. If you
still see the spinner after editing `assets/floorMap.svg`:

1. **Full restart, not hot reload.** Flutter bundles `assets/` content at
   build/restart time — editing an asset file's bytes while the app is
   running usually isn't picked up by hot reload. Stop the app and
   `flutter run` again (or hot **restart**, not hot reload).
2. Run `flutter pub get` after any change to `pubspec.yaml`'s `assets:` list.
3. Check the debug console for a `flutter_svg` parse error — invalid SVG
   (e.g. an unclosed tag) will now surface via `errorBuilder` instead of
   hanging silently.

## Notes / MVP shortcuts

- Zone snap picks the single strongest beacon rather than trilaterating —
  fine for aisle-level granularity, not sub-meter precision.
- Pathfinding is a plain O(V²) Dijkstra, which is fine for a graph sized to
  a store's aisle endpoints (tens of nodes).
- No state management library — `NavigationController` is a single
  `ChangeNotifier` consumed via `AnimatedBuilder`.

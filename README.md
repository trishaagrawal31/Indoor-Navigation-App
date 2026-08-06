# Indoor Navigation — MVP Skeleton

BLE beacon → RSSI scan → zone snap → Dijkstra pathfinding → SVG map render → UI.

## Architecture

```
lib/
  models/
    beacon.dart            Beacon (id, bleId, name, position)
    item.dart               Item (name, beaconId) — a searchable thing and its nearest beacon
    store_map.dart          StoreMap + Edge, loaded from store_data.json
  services/
    store_data_repository.dart   Loads assets/store_data.json
    ble_scanner_service.dart     flutter_reactive_ble scan, 3s rolling RSSI avg
    zone_snap_service.dart       Strongest RSSI -> nearest beacon
    pathfinding_service.dart     Dijkstra over the beacon graph
    navigation_controller.dart   Wires the above into app state (ChangeNotifier)
  ui/
    screens/map_screen.dart      SVG map + destination picker + item search + directions
    widgets/map_painter.dart     CustomPainter: user pin + route overlay
    widgets/item_search_delegate.dart   Search-as-you-type over items -> sets destination
  app.dart / main.dart
assets/
  store_data.json           Beacons, aisle graph, and searchable items (edit this per store)
  floorMap.svg               Real floor plan, 297x210 (landscape) coordinate space
```

## Setup

```
flutter pub get
```

### BLE permissions

Declared already, but both layers matter — the manifest/plist entries alone
are not enough, the app must also request them at runtime:

- **Android** (`android/app/src/main/AndroidManifest.xml`): `BLUETOOTH_SCAN`,
  `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION` (plus legacy `BLUETOOTH` /
  `BLUETOOTH_ADMIN` for API < 31, which the `flutter_reactive_ble` plugin's
  own manifest already contributes).
- **iOS** (`ios/Runner/Info.plist`): `NSBluetoothAlwaysUsageDescription` /
  `NSBluetoothPeripheralUsageDescription`.
- **Runtime request**: `BleScannerService.startScan()`
  (`lib/services/ble_scanner_service.dart`) requests these via
  `permission_handler` before scanning, and emits a message on
  `BleScannerService.errors` if the user denies one — `MapScreen` shows
  it as a `SnackBar`. If you deny a permission once, most OSes won't
  prompt again automatically; grant it manually in system settings and
  restart the app.

## Wiring real beacons

Edit `assets/store_data.json`:
- `beacons[].bleId` is the beacon's iBeacon identity as
  `"uuid:major:minor"`, e.g. `"01020304-0506-0708-090a-0b0c0d0e0f10:256:1"`
  — matched by `parseIBeacon()` in `lib/services/ble_scanner_service.dart`,
  which decodes the UUID/major/minor straight out of the advertisement's
  manufacturer data. A beacon fleet commonly shares one UUID and is
  differentiated only by minor, so the UUID alone isn't a safe key — always
  set all three. Confirmed working for `b1` (verified against nRF Connect's
  raw advertisement view: Company `Apple, Inc. <0x004C>`, Type `Beacon
  <0x02>`, UUID `01020304-...`, Major `256`, Minor `1`); `b2`–`b4` currently
  guess the same UUID/major with minors `2`–`4` as placeholders — replace
  once you confirm each physical beacon's actual minor (e.g. via nRF
  Connect, or the `[BLE]` debug log below).
- `BleScannerService._onDeviceSeen` currently has a **temporary debug
  `debugPrint`** that dumps every advertisement seen (id, rssi, raw
  manufacturer data, service data/UUIDs, and the parsed iBeacon if any) —
  useful for finding a beacon's real major/minor or diagnosing why it isn't
  showing up. Remove it once detection is confirmed working end-to-end.
- **If a beacon still doesn't show up**, check `local_packages/reactive_ble_mobile/android/.../ble/ReactiveBleClient.kt`'s
  `scanForDevices` — it previously called `.setLegacy(false)` on
  `ScanSettings.Builder`, which tells Android to report only Bluetooth 5
  extended-advertising results and silently drop legacy-format ones. iBeacon
  is a legacy-only format, so that one line made every iBeacon invisible to
  this app while still letting BLE5 devices (most modern phones/wearables)
  through — which is exactly why a scan log could show 100+ nearby devices
  and still miss the one beacon that mattered. It's been removed; if it
  reappears (e.g. from re-vendoring the plugin), take it back out. This is
  **native Android code** — changes here need a full rebuild, not hot
  reload/restart.
- `BleScannerService.startScan()` also explicitly requests
  `ScanMode.lowLatency` rather than the library's `balanced` default, for a
  higher scan duty cycle — matters for beacons with a sparse advertising
  interval.
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

## Item search

Tap the search icon in the app bar to search-as-you-type over
`store_data.json`'s `items` array; picking a result calls
`NavigationController.setDestination` with that item's nearest beacon, same
as picking one from the destination-picker menu, and the route renders the
same way.

- Each item is `{ "name": "...", "beaconId": "b1" }` — `beaconId` must match
  an existing `beacons[].id`. There's no separate "room" concept: an item's
  location *is* whichever beacon is nearest to it, same as how the walkway
  beacons are already named after nearby rooms.
- Matching is a plain case-insensitive substring match on `name`
  (`StoreMap.searchItems` in `lib/models/store_map.dart`) — fine for a
  handful of items; if the catalog grows large, that's the place to swap in
  something smarter (fuzzy matching, indexing, etc.).
- The current 8 items are placeholders illustrating the shape — replace with
  the store's real inventory.

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

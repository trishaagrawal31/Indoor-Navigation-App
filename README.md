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
    motion_service.dart          pedometer + flutter_compass -> PDR position deltas
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

## Live position tracking (PDR)

The map arrow no longer only jumps between beacon fixes — between fixes it
moves continuously via **pedestrian dead reckoning (PDR)**: each detected
step (`pedometer`, native OS step counter) advances a position estimate by
one step-length in the current compass heading (`flutter_compass`), and
each new BLE zone-snap fix resets that estimate back to the beacon's known
position, correcting drift. See `MotionService`
(`lib/services/motion_service.dart`) and `NavigationController`'s
`_onStepDelta`/`_onRssiUpdate` (`lib/services/navigation_controller.dart`).

- `store_data.json`'s `metersPerUnit` converts step-length meters into map
  coordinate units; `mapNorthOffsetDegrees` is the compass bearing that
  corresponds to the map's "up" direction, used to rotate a heading into
  the map's coordinate frame.
- **Current calibration is approximate.** Measured `b1↔b4` = 65 map units
  for 6 m (0.0923 m/unit) and `b4↔b3` = 103 map units for 12 m (0.1165
  m/unit) — these two disagree by ~26%, meaning the floor plan isn't
  uniformly to scale (expected, given it was reconstructed from a rotated
  SVG rather than surveyed). `metersPerUnit: 0.104` is their average.
  Re-measure more beacon pairs and adjust this single number to improve
  accuracy. `mapNorthOffsetDegrees: 180` was corrected empirically (on-device
  testing showed the arrow off by 90°) — note this means the map's "up"
  direction now works out to compass **South**, not the East originally
  described; if direction ever looks wrong again after further changes,
  that mismatch is the first thing to check, not another blind 90° nudge.
- `stepLengthMeters` (`MotionService`, default `0.75`) is a generic average
  adult stride — personalize per-user if needed.
- **Heading smoothing**: raw compass readings are noisy indoors (structural
  metal, electronics interfere with the magnetometer), which was causing
  whole batches of steps to fire in a wildly wrong direction — the live
  arrow visibly "jumping" instead of moving smoothly. `MotionService`
  applies an exponential moving average (`_smoothHeading`, circular —
  handles the 0°/360° wraparound correctly) before using a heading for
  anything. Tune via the `alpha` default in `_smoothHeading` if turns feel
  too laggy (higher alpha) or still too jumpy (lower alpha).
- **Proximity-gated recalibration**: `NavigationController` only hard-resets
  `liveUserPosition` to a beacon's exact position when that beacon's RSSI
  clears `_recalibrationMinRssi` (default `-70` dBm) — recalibrating off a
  weak signal was the other source of visible jumping, since two
  similar-strength weak beacons can flip "nearest" back and forth. Weak
  fixes still update `currentBeacon` (for the "You are near" text and as
  the pathfinding start) — only the live-arrow teleport is gated.
- **Permissions**: step counting needs `ACTIVITY_RECOGNITION`
  (`AndroidManifest.xml`, API 29+) / `NSMotionUsageDescription`
  (`Info.plist`), requested at runtime by `MotionService.start()` the same
  way `BleScannerService` handles BLE permissions; denial surfaces via
  `MotionService.errors` as a `SnackBar`, same pattern. `flutter_compass`
  needs no extra runtime permission on either platform as far as tested —
  flagged here in case that turns out wrong on a given device, consistent
  with this project's history of permission surprises.
- New native permission → needs a full rebuild (`flutter pub get`, then
  `flutter run`), not hot reload/restart.
- **Confined to the corridor graph**: `NavigationController._onStepDelta`
  runs every dead-reckoned position through `StoreMap.snapToGraph`
  (`lib/models/store_map.dart`) before using it — a map-matching step that
  projects the raw point onto the nearest edge of `storeMap.edges`, clamped
  to that segment. This is what stops PDR from drifting into the black room
  rectangles: those have no edges, so the graph itself defines walkable
  space. Simplification worth knowing about: it always snaps to whichever
  edge is geometrically nearest, with no directionality/continuity
  awareness — fine for this graph's current size (4 edges), but if the
  corridor layout grows dense enough for edges to run close and parallel,
  nearest-segment snapping can occasionally jump to the wrong nearby
  corridor instead of staying on the one actually being walked.
- **Animated arrow movement**: `_MapFrame` (`lib/ui/screens/map_screen.dart`)
  is a `StatefulWidget` that tweens the *drawn* position from wherever it
  currently is to each new `liveUserPosition` over ~350ms
  (`Curves.easeOut`), redirecting smoothly mid-flight if another update
  arrives before the tween finishes, rather than snapping instantly on
  every `notifyListeners()`. This is what makes the arrow read as
  continuous walking motion instead of discrete jumps between sparse step
  events. Heading isn't separately animated — `MotionService`'s heading
  smoothing (above) already keeps it visually smooth at the source.
- **Destination pin**: `MapPainter._drawDestinationPin` renders a
  `location_on` Material icon glyph directly onto the canvas (drawing an
  `Icon`'s glyph via `TextPainter` inside a `CustomPainter`) at the last
  beacon in the route, instead of the plain dot every other waypoint gets —
  makes the endpoint visually distinct from the path it took to get there.

## Route distance

Once a destination is picked, the status card above the map shows total
route distance (e.g. "142 m"), computed from `PathfindingService.findPath`'s
`RouteResult.distanceUnits` (the sum of edge weights Dijkstra already
computes to find the shortest path — no separate calculation) multiplied by
`metersPerUnit`. Since that scale factor is only roughly calibrated (see
above), treat this distance as approximate too.

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

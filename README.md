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
    motion_service.dart          pedometer step distance + gyroscope/compass fused heading
    zone_snap_service.dart       RSSI -> distance -> trilaterated position + nearest beacon
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
  <0x02>`, UUID `01020304-...`, Major `256`, Minor `1`); `b2`–`b4` are now
  confirmed against their real physical positions too. If you re-wire
  beacons later and need to re-diagnose, `BleScannerService._onDeviceSeen`
  previously had a temporary `debugPrint` dumping every advertisement seen,
  and `MainActivity.kt` a raw `BluetoothLeScanner` diagnostic (tag
  `RAWBLE`) that bypassed the Flutter plugin entirely to check whether the
  OS saw a beacon at all — both were removed once detection was confirmed
  working end-to-end; re-add similar logging temporarily if needed rather
  than leaving it in permanently.
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
step (`pedometer`, backed by the OS's accelerometer-based step counter)
advances a position estimate by one step-length, and each confirmed BLE
zone-snap fix resets that estimate back to the beacon's known position,
correcting drift. See `MotionService` (`lib/services/motion_service.dart`)
and `NavigationController`'s `_onStepDistance`/`_onRssiUpdate`
(`lib/services/navigation_controller.dart`).

- **Direction = along the route, not raw heading.** `_stepDirection`
  (`NavigationController`) walks toward the next waypoint on `currentPath`
  whenever a route is active, using the compass/gyro heading only as a
  fallback when there's no destination set. Indoor compass headings are
  noisy enough (see below) that trusting the planned route's direction is
  more reliable than trusting the phone's heading — and it's what keeps the
  pin advancing along the path the user actually asked to follow rather
  than wherever the compass happens to point. `storeMap.snapToGraph` still
  clamps the result onto the corridor graph either way, since a
  straight-line aim at a waypoint can cut a corner through a room interior.

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
- **Heading = gyroscope + compass fusion**: raw compass readings are noisy
  indoors (structural metal, electronics interfere with the magnetometer)
  and comparatively slow to update. `MotionService` now integrates
  `sensors_plus`' `gyroscopeEventStream()` (rotation rate, typically
  50-200 Hz) into the heading continuously (`_onGyro`) for fast, low-noise
  turn response, and corrects the accumulating gyro drift on every compass
  sample with a small-weight circular blend (`_onCompass`, `_blendHeading`,
  weight `0.08`) rather than trusting either sensor alone. Tune that weight
  if turns feel laggy (raise it) or the heading drifts/jitters between
  compass fixes (lower it).
- **Trilateration, not winner-take-all or a bare signal-weighted average**:
  `ZoneSnapService` used to snap to whichever single beacon read
  strongest — noisy indoors, since a farther beacon can transiently
  out-read a closer one, which was exactly the "shows me at the wrong room"
  symptom even with all 4 beacons correctly labeled. A signal-weighted
  centroid was tried after that (RSSI → linear power via `10^(rssi/10)`,
  averaged); it fixed *which node* got picked but, fed continuously into
  the live position, could overshoot toward a beacon just because it was
  in range — a proximity-weighted average doesn't reason about *absolute*
  distance. `estimatePosition` now does real multilateration: each
  beacon's RSSI is converted to an estimated distance in meters (a
  log-distance path-loss model, `_txPowerAt1m`/`_pathLossExponent` — not
  per-beacon calibrated, so treat distances as approximate), then solves
  (weighted least squares, closed-form for 2 unknowns) for the point
  consistent with *all* those distances — with >=3 beacons in range.
  Falls back to a distance-weighted centroid with only 1-2 beacons, or
  when the visible beacons are too close to collinear to solve (common
  here, since they're mounted along corridors rather than spread in a
  grid) — the solver's determinant check and a map-bounds plausibility
  check both guard against a degenerate solve shooting off to a
  nonsensical point. `nearestBeacon` picks whichever known beacon is
  closest to that estimate, for `currentBeacon`/pathfinding.
- **Target vs. drawn position — a continuous "chase"**: `NavigationController`
  tracks two positions. `_targetPosition` is the *logical* best-known
  spot, updated continuously by *both* PDR steps (`_stepDirection`) *and*
  every BLE reading's trilaterated estimate (`_onRssiUpdate`) — not just
  once a node flip is confirmed, which is what lets the pin keep moving
  and stay roughly accurate *between* beacons rather than only updating at
  them. `liveUserPosition` — what's actually drawn — is never set
  directly; `_advanceTowardTarget` (ticked every 80ms) continuously eases
  it toward `_targetPosition` at a capped `_walkingSpeedMetersPerSecond`
  (1.3 m/s). That speed cap is deliberate: even if a given trilateration
  reading is briefly noisy, the drawn pin can only be pulled by that much
  before the next (hopefully better) reading corrects it, rather than
  visibly teleporting — the mechanism that made the earlier
  proximity-centroid approach's overshoot-toward-destination bug possible
  no longer exists structurally. Both the target's updates and the
  chase's ticks run through `storeMap.snapToGraph`, so the pin stays on
  the walkable corridor throughout, never free-drifting through a room
  interior.
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
- **"Arrived" no longer blanks the UI**: when `currentBeacon` equals
  `destinationBeacon`, `PathfindingService.findPath` correctly returns a
  1-beacon path (nothing to walk) — but `MapPainter` used to only draw
  *anything* `if (path.length > 1)`, so arriving made the route line, pin,
  distance, and directions all vanish together, indistinguishable from "no
  route selected." It now always draws the destination pin whenever `path`
  is non-empty, and `NavigationController` reports `0 m` instead of `null`
  distance for a 1-beacon path.
- **Beacon-flip debounce**: `NavigationController._onRssiUpdate` now
  requires a candidate "nearest beacon" to win `_requiredConsecutiveReadings`
  (2) updates in a row before committing it to `currentBeacon` — a single
  noisy RSSI reading was previously enough to flip zones outright, which is
  a likely cause of the app reporting a beacon that didn't match physical
  reality. **This can only filter noise, not fix a wrong `bleId`-to-position
  mapping** — if `store_data.json`'s `beacons[].bleId` values don't
  correspond to where those physical beacons are actually mounted, no
  amount of software debouncing will report the correct zone. Worth
  re-verifying against nRF Connect (as done for the original `b1`) if
  misidentification continues after this.
- **Edge-stickiness**: `StoreMap.snapToGraph` now takes an optional
  `preferredEdge` and discounts its distance before comparing, so a noisy
  step doesn't flip the live position to a different, similarly-close
  corridor edge on every update — `NavigationController` tracks
  `_lastSnappedEdge` and passes it back in each call. This graph is small
  enough (4 short edges) that PDR error from a single step can be a
  significant fraction of an entire edge's length, so some jumpiness here
  is a real precision limit of step-based positioning at this map's scale,
  not purely a smoothing bug — expect it to improve as `metersPerUnit` gets
  more accurately calibrated (see above), not fully disappear.

## Route distance

Once a destination is picked, the status card above the map shows total
route distance (e.g. "142 m"), computed from `PathfindingService.findPath`'s
`RouteResult.distanceUnits` (the sum of edge weights Dijkstra already
computes to find the shortest path — no separate calculation) multiplied by
`metersPerUnit`. Since that scale factor is only roughly calibrated (see
above), treat this distance as approximate too.

- **If the distance looks way off** (e.g. reported ~44 m for a route
  expected to be ~24 m): check which beacon is actually set as
  `destinationBeacon` first, before suspecting `metersPerUnit`. With the
  current graph (`b2↔b3` 132 units, `b3↔b4` 103, `b4↔b1` 188), `b2→b4` is
  235 units × `0.104` ≈ **24 m** — already correct — while `b2→b1` (the
  graph's two *opposite ends*, via `b3` and `b4`) is 423 units × `0.104` ≈
  **44 m**. That exact match is what a wrong-destination selection looks
  like; it isn't reproducible from a `metersPerUnit`/edge-weight bug given
  the numbers above.
- **The route no longer disappears on its own.** `_recomputePath`
  (`NavigationController`) used to blank `currentPath`/`currentDistanceMeters`
  whenever `currentBeacon` was momentarily null or `PathfindingService`
  came back empty — which could happen transiently mid-walk, hiding the
  route line, destination pin, and directions chips for no reason visible
  to the user. It now leaves the existing route on screen untouched in
  both cases and only ever replaces or clears it for one of two
  intentional reasons: `setDestination` (a genuinely new destination) or
  `clearDestination` (the map card's refresh button).

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

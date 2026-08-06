import 'dart:ui' show Offset;

import 'beacon.dart';
import 'item.dart';

/// A weighted, undirected edge between two beacons in the aisle graph.
class Edge {
  final String from;
  final String to;
  final double weight;

  const Edge({required this.from, required this.to, required this.weight});

  factory Edge.fromJson(Map<String, dynamic> json) {
    return Edge(
      from: json['from'] as String,
      to: json['to'] as String,
      weight: (json['weight'] as num).toDouble(),
    );
  }
}

/// The full store layout: beacon positions, the aisle graph, and the map asset to render.
class StoreMap {
  final String mapAsset;
  final double mapWidth;
  final double mapHeight;

  /// Real-world meters per one map/SVG coordinate unit. Used to convert
  /// step-length-based movement (meters) into map-space offsets. Calibrated
  /// from measured real-world distances between beacons — see README.
  final double metersPerUnit;

  /// Compass bearing (degrees, 0 = North) that corresponds to the map's
  /// "up" (-y) direction, e.g. 90 if the top of the floor plan faces East.
  /// Used to rotate compass headings into the map's coordinate frame.
  final double mapNorthOffsetDegrees;

  final List<Beacon> beacons;
  final List<Edge> edges;
  final List<Item> items;

  const StoreMap({
    required this.mapAsset,
    required this.mapWidth,
    required this.mapHeight,
    required this.metersPerUnit,
    required this.mapNorthOffsetDegrees,
    required this.beacons,
    required this.edges,
    required this.items,
  });

  factory StoreMap.fromJson(Map<String, dynamic> json) {
    return StoreMap(
      mapAsset: json['mapAsset'] as String,
      mapWidth: (json['mapWidth'] as num).toDouble(),
      mapHeight: (json['mapHeight'] as num).toDouble(),
      metersPerUnit: (json['metersPerUnit'] as num? ?? 1.0).toDouble(),
      mapNorthOffsetDegrees: (json['mapNorthOffsetDegrees'] as num? ?? 0.0).toDouble(),
      beacons: (json['beacons'] as List)
          .map((b) => Beacon.fromJson(b as Map<String, dynamic>))
          .toList(),
      edges: (json['edges'] as List)
          .map((e) => Edge.fromJson(e as Map<String, dynamic>))
          .toList(),
      items: (json['items'] as List? ?? [])
          .map((i) => Item.fromJson(i as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Case-insensitive substring search over item names.
  List<Item> searchItems(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return items.where((i) => i.name.toLowerCase().contains(q)).toList();
  }

  Beacon? beaconById(String id) {
    for (final b in beacons) {
      if (b.id == id) return b;
    }
    return null;
  }

  Beacon? beaconByBleId(String bleId) {
    final normalized = bleId.toLowerCase();
    for (final b in beacons) {
      if (b.bleId.toLowerCase() == normalized) return b;
    }
    return null;
  }

  /// Adjacency list built from [edges], treated as undirected.
  Map<String, List<Edge>> get adjacency {
    final map = <String, List<Edge>>{};
    for (final e in edges) {
      map.putIfAbsent(e.from, () => []).add(e);
      map.putIfAbsent(e.to, () => []).add(Edge(from: e.to, to: e.from, weight: e.weight));
    }
    return map;
  }

  /// The closest point to [point] lying on any edge of the corridor graph
  /// — i.e. map-matching: projects [point] onto the nearest edge segment,
  /// clamped to that segment's endpoints. Used to keep PDR-tracked movement
  /// confined to walkable corridors instead of drifting into room
  /// interiors, which have no edges of their own.
  Offset snapToGraph(Offset point) {
    Offset? closest;
    var bestDistanceSquared = double.infinity;
    for (final edge in edges) {
      final a = beaconById(edge.from)?.position;
      final b = beaconById(edge.to)?.position;
      if (a == null || b == null) continue;
      final projected = _projectOntoSegment(point, a, b);
      final d = (projected - point).distanceSquared;
      if (d < bestDistanceSquared) {
        bestDistanceSquared = d;
        closest = projected;
      }
    }
    return closest ?? point;
  }

  Offset _projectOntoSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final abLengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (abLengthSquared == 0) return a;
    final t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / abLengthSquared;
    final tClamped = t.clamp(0.0, 1.0);
    return Offset(a.dx + ab.dx * tClamped, a.dy + ab.dy * tClamped);
  }
}

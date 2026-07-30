import 'beacon.dart';

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
  final List<Beacon> beacons;
  final List<Edge> edges;

  const StoreMap({
    required this.mapAsset,
    required this.mapWidth,
    required this.mapHeight,
    required this.beacons,
    required this.edges,
  });

  factory StoreMap.fromJson(Map<String, dynamic> json) {
    return StoreMap(
      mapAsset: json['mapAsset'] as String,
      mapWidth: (json['mapWidth'] as num).toDouble(),
      mapHeight: (json['mapHeight'] as num).toDouble(),
      beacons: (json['beacons'] as List)
          .map((b) => Beacon.fromJson(b as Map<String, dynamic>))
          .toList(),
      edges: (json['edges'] as List)
          .map((e) => Edge.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Beacon? beaconById(String id) {
    for (final b in beacons) {
      if (b.id == id) return b;
    }
    return null;
  }

  Beacon? beaconByBleId(String bleId) {
    for (final b in beacons) {
      if (b.bleId == bleId) return b;
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
}

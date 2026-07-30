import '../models/beacon.dart';
import '../models/store_map.dart';

/// Shortest path between two beacons over the aisle graph, via Dijkstra.
/// The store's beacon graph is small (tens of nodes), so a plain O(V^2)
/// implementation is simpler and fast enough for this MVP.
class PathfindingService {
  List<Beacon> findPath(StoreMap storeMap, String startId, String endId) {
    if (startId == endId) {
      final only = storeMap.beaconById(startId);
      return only == null ? [] : [only];
    }

    final adjacency = storeMap.adjacency;
    final distances = <String, double>{for (final b in storeMap.beacons) b.id: double.infinity};
    final previous = <String, String?>{};
    final visited = <String>{};

    distances[startId] = 0;

    while (visited.length < storeMap.beacons.length) {
      final currentId = _closestUnvisited(distances, visited);
      if (currentId == null) break;
      if (currentId == endId) break;
      visited.add(currentId);

      for (final edge in adjacency[currentId] ?? const []) {
        if (visited.contains(edge.to)) continue;
        final candidate = distances[currentId]! + edge.weight;
        if (candidate < (distances[edge.to] ?? double.infinity)) {
          distances[edge.to] = candidate;
          previous[edge.to] = currentId;
        }
      }
    }

    if (!previous.containsKey(endId) && startId != endId) return [];
    return _reconstructPath(storeMap, previous, startId, endId);
  }

  String? _closestUnvisited(Map<String, double> distances, Set<String> visited) {
    String? closest;
    var closestDistance = double.infinity;
    for (final entry in distances.entries) {
      if (visited.contains(entry.key)) continue;
      if (entry.value < closestDistance) {
        closestDistance = entry.value;
        closest = entry.key;
      }
    }
    return closest;
  }

  List<Beacon> _reconstructPath(
    StoreMap storeMap,
    Map<String, String?> previous,
    String startId,
    String endId,
  ) {
    final pathIds = <String>[endId];
    var currentId = endId;
    while (currentId != startId) {
      final prev = previous[currentId];
      if (prev == null) return [];
      pathIds.add(prev);
      currentId = prev;
    }
    return pathIds.reversed.map((id) => storeMap.beaconById(id)!).toList();
  }
}

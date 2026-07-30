import 'package:flutter/material.dart';

import '../../models/beacon.dart';

/// Draws the live user pin and the turn-by-turn route line on top of the
/// store's SVG floor plan. Coordinates are in the map's native SVG space;
/// the painter scales them to the widget's actual render size.
class MapPainter extends CustomPainter {
  MapPainter({
    required this.mapSize,
    required this.path,
    this.userLocation,
  });

  final Size mapSize;
  final List<Beacon> path;
  final Beacon? userLocation;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / mapSize.width;
    final scaleY = size.height / mapSize.height;
    Offset scale(Offset p) => Offset(p.dx * scaleX, p.dy * scaleY);

    if (path.length > 1) {
      final routePaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final routePath = Path()..moveTo(scale(path.first.position).dx, scale(path.first.position).dy);
      for (final beacon in path.skip(1)) {
        final p = scale(beacon.position);
        routePath.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(routePath, routePaint);
    }

    final user = userLocation;
    if (user != null) {
      final p = scale(user.position);
      canvas.drawCircle(p, 9, Paint()..color = Colors.white);
      canvas.drawCircle(p, 7, Paint()..color = Colors.redAccent);
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.path != path ||
        oldDelegate.userLocation?.id != userLocation?.id ||
        oldDelegate.mapSize != mapSize;
  }
}

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
        ..color = const Color(0xFF1E88E5)
        ..strokeWidth = 7
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final shadowPaint = Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..strokeWidth = 11
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final routePath = Path()
        ..moveTo(scale(path.first.position).dx, scale(path.first.position).dy);
      for (final beacon in path.skip(1)) {
        final p = scale(beacon.position);
        routePath.lineTo(p.dx, p.dy);
      }

      canvas.drawPath(routePath, shadowPaint);
      canvas.drawPath(routePath, routePaint);

      for (final beacon in path) {
        final p = scale(beacon.position);
        canvas.drawCircle(p, 6.5, Paint()..color = Colors.white);
        canvas.drawCircle(p, 4.5, Paint()..color = const Color(0xFF0D47A1));
      }
    }

    final user = userLocation;
    if (user != null) {
      final p = scale(user.position);
      canvas.drawCircle(p, 10, Paint()..color = Colors.white);
      canvas.drawCircle(p, 7.5, Paint()..color = Colors.redAccent);
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.path != path ||
        oldDelegate.userLocation?.id != userLocation?.id ||
        oldDelegate.mapSize != mapSize;
  }
}

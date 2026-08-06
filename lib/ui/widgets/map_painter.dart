import 'dart:math' as math;

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
    this.livePosition,
    this.headingDegrees,
    this.mapNorthOffsetDegrees = 0,
  });

  final Size mapSize;
  final List<Beacon> path;
  final Beacon? userLocation;

  /// PDR-tracked live position (map units) — takes priority over
  /// [userLocation]'s fixed beacon position for where the pin/arrow is
  /// drawn, when available.
  final Offset? livePosition;

  /// Live compass heading (degrees, 0 = North) — takes priority over the
  /// next-waypoint direction for which way the arrow points, when available.
  final double? headingDegrees;

  /// Compass bearing that corresponds to the map's "up" (-y) direction,
  /// used to convert [headingDegrees] into the map's coordinate frame.
  final double mapNorthOffsetDegrees;

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
        ..color = Colors.black.withValues(alpha: 0.18)
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
    final rawPosition = livePosition ?? user?.position;
    if (rawPosition != null) {
      final p = scale(rawPosition);
      canvas.drawCircle(p, 11, Paint()..color = Colors.white);

      final heading = headingDegrees;
      if (heading != null) {
        final angle = (heading - mapNorthOffsetDegrees) * math.pi / 180;
        _drawDirectionArrow(canvas, from: p, angle: angle);
      } else {
        final next = user == null ? null : _nextWaypoint(user);
        if (next != null) {
          final target = scale(next.position);
          _drawDirectionArrow(canvas, from: p, angle: math.atan2(target.dy - p.dy, target.dx - p.dx));
        } else {
          canvas.drawCircle(p, 7.5, Paint()..color = Colors.redAccent);
        }
      }
    }
  }

  /// The beacon immediately after [user] on the current route, or null if
  /// [user] isn't on the route (or has already reached its end) — i.e.
  /// there's no "forward" direction left to point an arrow toward.
  Beacon? _nextWaypoint(Beacon user) {
    final index = path.indexWhere((b) => b.id == user.id);
    if (index == -1 || index >= path.length - 1) return null;
    return path[index + 1];
  }

  /// Draws a chevron centered at [from], rotated to [angle] radians
  /// (0 = pointing along +x, increasing clockwise in screen space).
  void _drawDirectionArrow(Canvas canvas, {required Offset from, required double angle}) {
    canvas.save();
    canvas.translate(from.dx, from.dy);
    canvas.rotate(angle);
    final arrow = Path()
      ..moveTo(9, 0)
      ..lineTo(-5, 6)
      ..lineTo(-1.5, 0)
      ..lineTo(-5, -6)
      ..close();
    canvas.drawPath(arrow, Paint()..color = Colors.redAccent);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.path != path ||
        oldDelegate.userLocation?.id != userLocation?.id ||
        oldDelegate.livePosition != livePosition ||
        oldDelegate.headingDegrees != headingDegrees ||
        oldDelegate.mapNorthOffsetDegrees != mapNorthOffsetDegrees ||
        oldDelegate.mapSize != mapSize;
  }
}

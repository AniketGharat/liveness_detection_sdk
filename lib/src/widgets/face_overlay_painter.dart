import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../liveness_sdk.dart';

class FaceOverlayPainter extends CustomPainter {
  final double progress;
  final Animation<double> animation;
  final double circleSize;
  final LivenessState state;

  FaceOverlayPainter({
    required this.progress,
    required this.animation,
    required this.circleSize,
    required this.state,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * (circleSize / 2);

    // Draw circle
    final circlePaint = Paint()
      ..color = Colors.white.withOpacity(animation.value)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, circlePaint);

    // Draw progress
    if (progress > 0) {
      final progressPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -pi / 2,
        2 * pi * progress,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      animation != oldDelegate.animation ||
      circleSize != oldDelegate.circleSize ||
      state != oldDelegate.state;
}

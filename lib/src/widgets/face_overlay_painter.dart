import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

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

    // Draw base white circle
    final circlePaint = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, circlePaint);

    // Draw progress in quarters
    if (progress > 0) {
      final progressPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      // Calculate which quarter we're in
      final quarterProgress = (progress * 4).floor();
      final currentQuarterProgress = (progress * 4) % 1;

      // Draw completed quarters
      for (var i = 0; i < quarterProgress; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          -pi / 2 + (i * pi / 2),
          pi / 2,
          false,
          progressPaint,
        );
      }

      // Draw current quarter progress
      if (quarterProgress < 4) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          -pi / 2 + (quarterProgress * pi / 2),
          pi / 2 * currentQuarterProgress,
          false,
          progressPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      animation != oldDelegate.animation ||
      circleSize != oldDelegate.circleSize ||
      state != oldDelegate.state;
}

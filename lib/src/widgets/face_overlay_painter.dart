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

    // Draw base circle
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

      // Calculate number of complete quarters (0.25 each)
      final completeQuarters = (progress / 0.25).floor();
      final remainingProgress = progress % 0.25;
      final remainingAngle = (remainingProgress / 0.25) * (pi / 2);

      // Draw completed quarters
      for (var i = 0; i < completeQuarters; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          -pi / 2 + (i * pi / 2),
          pi / 2,
          false,
          progressPaint,
        );
      }

      // Draw partial progress in current quarter
      if (completeQuarters < 4) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          -pi / 2 + (completeQuarters * pi / 2),
          remainingAngle,
          false,
          progressPaint,
        );
      }
    }

    // Add error indication for multiple faces
    if (state == LivenessState.multipleFaces) {
      final errorPaint = Paint()
        ..color = Colors.red.withOpacity(0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      canvas.drawCircle(center, radius, errorPaint);
    }
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      animation != oldDelegate.animation ||
      circleSize != oldDelegate.circleSize ||
      state != oldDelegate.state;
}

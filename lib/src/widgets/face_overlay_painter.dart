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
    final radius = circleSize / 2;

    // Draw outer reference circle
    final outerCirclePaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius + 10, outerCirclePaint);

    // Draw base circle
    final circlePaint = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, circlePaint);

    // Calculate the angle based on progress
    final totalProgressAngle =
        progress * 2 * pi; // 0.25 for 1/4, 0.5 for 1/2, etc.

    // Paint progress
    final progressPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2, // Start from the top of the circle
      totalProgressAngle,
      false,
      progressPaint,
    );

    // Draw guidelines (cross lines)
    final guidelinePaint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Vertical guideline
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 20),
      Offset(center.dx, center.dy + radius + 20),
      guidelinePaint,
    );

    // Horizontal guideline
    canvas.drawLine(
      Offset(center.dx - radius - 20, center.dy),
      Offset(center.dx + radius + 20, center.dy),
      guidelinePaint,
    );

    // Add error indication for multiple faces
    if (state == LivenessState.multipleFaces) {
      final errorPaint = Paint()
        ..color = Colors.red.withOpacity(0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;

      canvas.drawCircle(center, radius, errorPaint);
    }

    // Draw animation effect
    final animationProgress = animation.value;
    final animationPaint = Paint()
      ..color = Colors.white.withOpacity(0.2 * (1 - animationProgress))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(
      center,
      radius + (20 * animationProgress),
      animationPaint,
    );
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      animation != oldDelegate.animation ||
      circleSize != oldDelegate.circleSize ||
      state != oldDelegate.state;
}

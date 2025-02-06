import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import '../../liveness_sdk.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(LivenessResult) onResult;
  final LivenessConfig config;

  const LivenessCameraView({
    Key? key,
    required this.onResult,
    this.config = const LivenessConfig(),
  }) : super(key: key);

  @override
  State<LivenessCameraView> createState() => _LivenessCameraViewState();
}

class _LivenessCameraViewState extends State<LivenessCameraView> {
  CameraController? _controller;
  late final LivenessDetector _livenessDetector;
  String _instruction = "Position your face in the circle";
  Color _circleColor = Colors.white;
  double _progress = 0.0;
  bool _isFaceDetected = false;
  bool _isCompleted = false;

  @override
  void initState() {
    super.initState();
    _livenessDetector = LivenessDetector(
      config: widget.config,
      onStateChanged: _handleStateChanged,
    );
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      _handleError("Camera permission required");
      return;
    }

    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        setState(() {});
        await _controller!.startImageStream(_livenessDetector.processImage);
      }
    } catch (e) {
      _handleError("Failed to initialize camera: $e");
    }
  }

  void _handleStateChanged(LivenessState state, double progress) {
    setState(() {
      _progress = progress;

      switch (state) {
        case LivenessState.initial:
          _instruction = "Position your face in the circle";
          _circleColor = Colors.white;
          break;
        case LivenessState.lookingStraight:
          _instruction = "Perfect! Now slowly turn your head left";
          _circleColor = Colors.green;
          _vibrateFeedback();
          break;
        case LivenessState.lookingLeft:
          _instruction = "Perfect! Now slowly turn your head right";
          _circleColor = Colors.green;
          _vibrateFeedback();
          break;
        case LivenessState.lookingRight:
          _instruction = "Great! Now center your face";
          _circleColor = Colors.green;
          _vibrateFeedback();
          break;
        case LivenessState.complete:
          _instruction = "Perfect! Processing...";
          _circleColor = Colors.green;
          _isCompleted = true;
          _vibrateFeedback();
          _capturePhoto();
          break;
      }
    });
  }

  void _vibrateFeedback() async {
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator != null && hasVibrator) {
      Vibration.vibrate(duration: 250);
    }
  }

  Future<void> _capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      await _controller!.stopImageStream();
      final XFile photo = await _controller!.takePicture();
      final File capturedFile = File(photo.path);
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String imagePath = '${appDir.path}/liveness_capture.jpg';

      await capturedFile.copy(imagePath);

      widget.onResult(LivenessResult(isSuccess: true, imagePath: imagePath));
      Navigator.pop(context);
    } catch (e) {
      _handleError("Failed to capture photo");
    }
  }

  void _handleError(String message) {
    widget.onResult(LivenessResult(
      isSuccess: false,
      errorMessage: message,
    ));
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _controller?.dispose();
    _livenessDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          CustomPaint(
            painter: FaceDetectionPainter(
              progress: _progress,
              circleColor: _circleColor,
              circleSize: widget.config.circleSize,
            ),
          ),
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _instruction,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FaceDetectionPainter extends CustomPainter {
  final double progress;
  final Color circleColor;
  final double circleSize;

  FaceDetectionPainter({
    required this.progress,
    required this.circleColor,
    required this.circleSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * (circleSize / 2);

    // Draw the main circle
    final circlePaint = Paint()
      ..color = circleColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(center, radius, circlePaint);

    // Draw progress arcs
    final rect = Rect.fromCircle(center: center, radius: radius);
    const double startAngle = -pi / 2; // Start from top

    // Background arcs (unfilled progress)
    final backgroundPaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawArc(rect, startAngle, 2 * pi, false, backgroundPaint);

    // Progress arc
    if (progress > 0) {
      final progressPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      canvas.drawArc(
        rect,
        startAngle,
        2 * pi * progress,
        false,
        progressPaint,
      );
    }

    // Draw guide text if no progress
    if (progress == 0) {
      const textStyle = TextStyle(
        color: Colors.white,
        fontSize: 14,
      );
      final textSpan = TextSpan(
        text: 'Position face here',
        style: textStyle,
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          center.dx - textPainter.width / 2,
          center.dy - radius - textPainter.height - 10,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(FaceDetectionPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      circleColor != oldDelegate.circleColor ||
      circleSize != oldDelegate.circleSize;
}

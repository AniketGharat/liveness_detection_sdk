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

  // Updated callback to match LivenessDetector's signature
  void _handleStateChanged(
      LivenessState state, double progress, String message) {
    setState(() {
      _progress = progress;
      _instruction = message;

      switch (state) {
        case LivenessState.initial:
          _circleColor = Colors.white;
          break;
        case LivenessState.lookingStraight:
          _circleColor = Colors.green;
          _vibrateFeedback();
          break;
        case LivenessState.lookingLeft:
          _circleColor = Colors.green;
          _vibrateFeedback();
          break;
        case LivenessState.lookingRight:
          _circleColor = Colors.green;
          _vibrateFeedback();
          break;
        case LivenessState.complete:
          _circleColor = Colors.green;
          _isCompleted = true;
          _vibrateFeedback();
          _capturePhoto();
          break;
      }
    });
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

    final circlePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(center, radius, circlePaint);

    if (progress > 0) {
      final rect = Rect.fromCircle(center: center, radius: radius);
      const double startAngle = -pi / 2;
      final segmentAngle = pi / 2;

      final completedSegments = (progress * 4).floor();

      final progressPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      for (var i = 0; i < completedSegments; i++) {
        canvas.drawArc(
          rect,
          startAngle + (i * segmentAngle),
          segmentAngle,
          false,
          progressPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectionPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      circleColor != oldDelegate.circleColor ||
      circleSize != oldDelegate.circleSize;
}

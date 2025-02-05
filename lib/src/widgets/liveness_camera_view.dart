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

class _LivenessCameraViewState extends State<LivenessCameraView>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  late final LivenessDetector _livenessDetector;
  late final AnimationController _progressController;
  List<CameraDescription> cameras = [];
  int _selectedCameraIndex = 0; // Will be set in initializeCamera

  String _instruction = "Position your face in the circle";
  Color _circleColor = Colors.white;
  double _progress = 0.0;
  bool _isCompleted = false;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: widget.config.phaseDuration,
    );

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

    cameras = await availableCameras();

    // Find the front camera index
    _selectedCameraIndex = cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front);
    if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;

    await _setupCamera();
  }

  Future<void> _setupCamera() async {
    if (cameras.isEmpty) return;

    if (_controller != null) {
      await _controller!.dispose();
    }

    _controller = CameraController(
      cameras[_selectedCameraIndex],
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

  Future<void> _switchCamera() async {
    if (_controller != null) {
      await _controller!.stopImageStream();
    }

    setState(() {
      _selectedCameraIndex = (_selectedCameraIndex + 1) % cameras.length;
    });

    await _setupCamera();
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
          _instruction = "Good! Now turn your head right slowly";
          _circleColor = Colors.green;
          Vibration.vibrate(duration: 100);
          break;
        case LivenessState.lookingRight:
          _instruction = "Perfect! Now turn your head left slowly";
          _circleColor = Colors.green;
          Vibration.vibrate(duration: 100);
          break;
        case LivenessState.lookingLeft:
          _instruction = "Great! Now center your face";
          _circleColor = Colors.green;
          Vibration.vibrate(duration: 100);
          break;
        case LivenessState.complete:
          _instruction = "Perfect! Hold still for photo";
          _circleColor = Colors.green;
          _isCompleted = true;
          Vibration.vibrate(duration: 100);
          _capturePhoto();
          break;
      }
    });
  }

  Future<void> _capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      await _controller!.stopImageStream();
      final XFile photo = await _controller!.takePicture();

      final Directory appDir = await getApplicationDocumentsDirectory();
      final String imagePath = '${appDir.path}/liveness_capture.jpg';
      await photo.saveTo(imagePath);

      widget.onResult(LivenessResult(
        isSuccess: true,
        imagePath: imagePath,
      ));

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
    _progressController.dispose();
    _controller?.dispose();
    _livenessDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
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
          // Camera switch button
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.switch_camera,
                  color: Colors.white, size: 30),
              onPressed: _switchCamera,
            ),
          ),
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _instruction,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
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

    // Guide circle
    final circlePaint = Paint()
      ..color = circleColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(center, radius, circlePaint);

    // Progress arc - Draw quarter circles based on progress
    if (progress > 0) {
      final progressPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      // Draw completed quarter circles
      final completedQuarters = (progress * 4).floor();
      for (var i = 0; i < completedQuarters; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          -pi / 2 + (i * pi / 2),
          pi / 2,
          false,
          progressPaint,
        );
      }

      // Draw current quarter progress
      final remainingProgress = progress * 4 - completedQuarters;
      if (remainingProgress > 0) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          -pi / 2 + (completedQuarters * pi / 2),
          (remainingProgress * pi / 2),
          false,
          progressPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectionPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      circleColor != oldDelegate.circleColor;
}

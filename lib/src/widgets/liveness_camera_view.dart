import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:image/image.dart' as img;

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

  String _instruction = "Position your face in the circle";
  Color _circleColor = Colors.white;
  double _progress = 0.0;
  bool _isCompleted = false;
  bool _isFaceDetected = true;

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

    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888,
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

      if (state == LivenessState.initial && _isFaceDetected) {
        _instruction = "Face not detected";
        _circleColor = Colors.red;
        _isFaceDetected = false;
        return;
      }

      _isFaceDetected = true;
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

      final File originalFile = File(photo.path);
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String imagePath = '${appDir.path}/liveness_capture.jpg';

      // Read and process the image
      final bytes = await originalFile.readAsBytes();
      var image = img.decodeImage(bytes);

      if (image != null) {
        // Only rotate the image, don't flip it to maintain mirror effect
        image = img.copyRotate(image, angle: 90);

        // Save the processed image
        final processedBytes = img.encodeJpg(image);
        await File(imagePath).writeAsBytes(processedBytes);

        widget.onResult(LivenessResult(
          isSuccess: true,
          imagePath: imagePath,
        ));
      } else {
        throw Exception('Failed to process image');
      }

      Navigator.pop(context);
    } catch (e) {
      print('Error capturing photo: $e');
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
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(
            color: Colors.white,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview with transform for mirroring
          Transform.scale(
            scale: 1.0,
            child: Center(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..scale(-1.0, 1.0, 1.0), // Mirror horizontally
                child: CameraPreview(_controller!),
              ),
            ),
          ),
          // Overlay for face detection
          CustomPaint(
            painter: FaceDetectionPainter(
              progress: _progress,
              circleColor: _circleColor,
              circleSize: widget.config.circleSize,
            ),
          ),
          // Instructions overlay
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

    // Draw guide circle
    final circlePaint = Paint()
      ..color = circleColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(center, radius, circlePaint);

    // Draw progress arc in quarters
    if (progress > 0) {
      final progressPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      final quarterTurns = (progress / 0.25).floor();
      final startAngle = -pi / 2;

      // Draw completed quarters
      for (var i = 0; i < quarterTurns; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          startAngle + (i * pi / 2),
          pi / 2,
          false,
          progressPaint,
        );
      }

      // Draw current quarter progress if not at a quarter boundary
      if (progress % 0.25 > 0) {
        final currentQuarterProgress = (progress % 0.25) * 4;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          startAngle + (quarterTurns * pi / 2),
          currentQuarterProgress * pi / 2,
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

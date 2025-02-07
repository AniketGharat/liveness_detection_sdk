// liveness_camera_view.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:lottie/lottie.dart';
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
    with TickerProviderStateMixin {
  CameraController? _controller;
  String _instruction = "Position your face in the circle";
  LivenessState _currentState = LivenessState.initial;
  double _progress = 0.0;
  bool _isFaceDetected = false;
  bool _hasMultipleFaces = false;
  late AnimationController _faceAnimationController;
  late AnimationController _overlayAnimationController;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _initializeCamera();
  }

  void _initializeAnimations() {
    _faceAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _overlayAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  Future<void> _initializeCamera() async {
    final status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      _handleError("Camera permission required");
      return;
    }

    try {
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

      await _controller!.initialize();

      if (!mounted) return;

      setState(() {});
      await _controller!.startImageStream(_processImage);
    } catch (e) {
      _handleError("Failed to initialize camera: $e");
    }
  }

  void _processImage(CameraImage image) async {
    try {
      // Add your face detection logic here
      // This is a placeholder for face detection processing
      bool faceDetected = true; // Replace with actual detection
      bool multipleFaces = false; // Replace with actual detection

      if (mounted) {
        setState(() {
          _isFaceDetected = faceDetected;
          _hasMultipleFaces = multipleFaces;
        });
      }
    } catch (e) {
      print('Error processing image: $e');
    }
  }

  Future<void> _capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      }

      final XFile photo = await _controller!.takePicture();
      final imagePath = await _processAndSaveImage(photo);

      widget.onResult(LivenessResult(
        isSuccess: true,
        imagePath: imagePath,
      ));

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      _handleError("Failed to capture photo: $e");
    }
  }

  Future<String> _processAndSaveImage(XFile photo) async {
    final File imageFile = File(photo.path);
    final Directory appDir = await getApplicationDocumentsDirectory();
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String newPath = '${appDir.path}/liveness_$timestamp.jpg';

    try {
      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) throw Exception("Failed to decode image");

      final flippedImage = img.flipHorizontal(image);
      final jpgBytes = img.encodeJpg(flippedImage);
      await File(newPath).writeAsBytes(jpgBytes);

      return newPath;
    } catch (e) {
      throw Exception("Failed to process image: $e");
    }
  }

  void _handleError(String message) {
    widget.onResult(LivenessResult(
      isSuccess: false,
      errorMessage: message,
    ));
    if (mounted) {
      Navigator.pop(context);
    }
  }

  void _handleStateChanged(LivenessState state, String message) async {
    if (!mounted) return;

    setState(() {
      _currentState = state;
      _instruction = message;

      _progress = switch (state) {
        LivenessState.initial => 0.0,
        LivenessState.lookingStraight => 0.25,
        LivenessState.lookingLeft => 0.5,
        LivenessState.lookingRight => 0.75,
        LivenessState.complete => 1.0,
      };
    });

    if (state != LivenessState.initial) {
      _overlayAnimationController.repeat(reverse: true);
      await _vibrateFeedback();
    } else {
      _overlayAnimationController.stop();
    }

    if (state == LivenessState.complete) {
      await _capturePhoto();
    }
  }

  Future<void> _vibrateFeedback() async {
    if (await Vibration.hasVibrator() ?? false) {
      await Vibration.vibrate(duration: 200);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller?.value.isInitialized != true) {
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
          // Camera Preview
          Transform.scale(
            scale: 1.0,
            child: Center(
              child: CameraPreview(_controller!),
            ),
          ),

          // Face Detection Overlay
          CustomPaint(
            painter: FaceOverlayPainter(
              progress: _progress,
              animation: _faceAnimationController,
              circleSize: widget.config.circleSize,
              state: _currentState,
            ),
          ),

          // Face Detection Animation
          if (!_isFaceDetected)
            Center(
              child: Lottie.asset(
                'assets/animations/face_scan.json',
                width: 200,
                height: 200,
              ),
            ),

          // Multiple Faces Warning
          if (_hasMultipleFaces)
            Center(
              child: Lottie.asset(
                'assets/animations/multiple_faces.json',
                width: 200,
                height: 200,
              ),
            ),

          // Instruction Message
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: _buildInstructionMessage(),
          ),

          // Close Button
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(
                Icons.close,
                color: Colors.white,
                size: 30,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _currentState == LivenessState.complete
              ? Colors.green.withOpacity(0.3)
              : Colors.white.withOpacity(0.3),
          width: 2,
        ),
      ),
      child: Text(
        _instruction,
        style: TextStyle(
          color: _currentState == LivenessState.complete
              ? Colors.green
              : Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  @override
  void dispose() {
    _faceAnimationController.dispose();
    _overlayAnimationController.dispose();
    _controller?.dispose();
    super.dispose();
  }
}

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

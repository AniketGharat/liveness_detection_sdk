import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
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
  Color _circleColor = Colors.transparent;
  double _progress = 0.0;
  bool _isCompleted = false;
  bool _isFaceDetected = false;
  bool _hasMultipleFaces = false;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: widget.config.phaseDuration,
    );

    // Create a new LivenessConfig with the callbacks
    final configWithCallbacks = LivenessConfig(
      requiredFrames: widget.config.requiredFrames,
      phaseDuration: widget.config.phaseDuration,
      straightThreshold: widget.config.straightThreshold,
      turnThreshold: widget.config.turnThreshold,
      errorTimeout: widget.config.errorTimeout,
      maxConsecutiveErrors: widget.config.maxConsecutiveErrors,
      circleSize: widget.config.circleSize,
      onFaceDetected: _handleFaceDetection,
      onMultipleFaces: _handleMultipleFaces,
    );

    _livenessDetector = LivenessDetector(
      config: configWithCallbacks,
      onStateChanged: _handleStateChanged,
    );

    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    // Request camera permission
    final status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      _handleError("Camera permission denied");
      return;
    }

    try {
      // Get available cameras
      final cameras = await availableCameras();

      // Find front camera
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      // Initialize the controller
      _controller = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      // Initialize the camera
      await _controller!.initialize();

      if (!mounted) return;

      // Start image stream
      await _controller!.startImageStream((image) {
        if (!_isCompleted) {
          _livenessDetector.processImage(image);
        }
      });

      // Set portrait orientation
      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      print('Error initializing camera: $e');
      _handleError("Failed to initialize camera");
    }
  }

  void _handleFaceDetection(bool detected) {
    if (mounted) {
      setState(() {
        _isFaceDetected = detected;
        _circleColor = detected ? Colors.green : Colors.transparent;
        if (!detected) {
          _instruction = "Position your face in the circle";
        }
      });
    }
  }

  void _handleMultipleFaces(bool hasMultiple) {
    if (mounted) {
      setState(() {
        _hasMultipleFaces = hasMultiple;
        if (hasMultiple) {
          _instruction = "Multiple faces detected";
          _circleColor = Colors.red;
        }
      });
    }
  }

  void _handleStateChanged(LivenessState state, double progress) {
    if (!mounted) return;

    setState(() {
      _progress = progress;

      if (_hasMultipleFaces) {
        _instruction = "Multiple faces detected";
        _circleColor = Colors.red;
        return;
      }

      if (!_isFaceDetected) {
        _instruction = "Position your face in the circle";
        _circleColor = Colors.transparent;
        return;
      }

      switch (state) {
        case LivenessState.initial:
          _instruction = "Position your face in the circle";
          _circleColor = Colors.green;
          break;
        case LivenessState.lookingStraight:
          _instruction = "Perfect! Now slowly turn your head left";
          _circleColor = Colors.green;
          Vibration.vibrate(duration: 100);
          break;
        case LivenessState.lookingLeft:
          _instruction = "Perfect! Now slowly turn your head right";
          _circleColor = Colors.green;
          Vibration.vibrate(duration: 100);
          break;
        case LivenessState.lookingRight:
          _instruction = "Great! Now center your face";
          _circleColor = Colors.green;
          Vibration.vibrate(duration: 100);
          break;
        case LivenessState.complete:
          _instruction = "Perfect! Processing...";
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
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String imagePath = '${appDir.path}/liveness_capture_$timestamp.jpg';

      // Read and process the image
      final bytes = await File(photo.path).readAsBytes();
      var image = img.decodeImage(bytes);

      if (image != null) {
        // Rotate and flip the image for correct orientation
        image = img.copyRotate(image, angle: 90);
        image =
            img.flipHorizontal(image); // Flip for front camera mirror effect

        // Save the processed image
        final processedBytes = img.encodeJpg(image);
        await File(imagePath).writeAsBytes(processedBytes);

        // Delete the old file if it exists
        final oldFile = File(photo.path);
        if (await oldFile.exists()) {
          await oldFile.delete();
        }

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
          Transform.scale(
            scale: 1.0,
            child: Center(
              child: CameraPreview(_controller!),
            ),
          ),
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

    if (circleColor != Colors.transparent) {
      // Draw guide frame
      final framePaint = Paint()
        ..color = circleColor.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      final frameRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center,
          width: size.width * 0.8,
          height: size.height * 0.8,
        ),
        const Radius.circular(12),
      );
      canvas.drawRRect(frameRect, framePaint);

      // Draw the circle
      final circlePaint = Paint()
        ..color = circleColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      canvas.drawCircle(center, radius, circlePaint);

      // Draw progress arcs only if there's progress
      if (progress > 0) {
        final progressPaint = Paint()
          ..color = Colors.green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0;

        // Calculate which quarter is active
        final activeQuarter = (progress * 4).floor();

        // Draw each quarter
        for (var i = 0; i < 4; i++) {
          final startAngle = -pi / 2 + (i * pi / 2);
          final paint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.0;

          if (i < activeQuarter) {
            // Completed quarters in green
            paint.color = Colors.green;
          } else if (i == activeQuarter) {
            // Current quarter in green with progress
            paint.color = Colors.green;
            final quarterProgress = (progress * 4) - activeQuarter;
            canvas.drawArc(
              Rect.fromCircle(center: center, radius: radius),
              startAngle,
              (pi / 2) * quarterProgress,
              false,
              paint,
            );
            continue;
          } else {
            // Future quarters in white with reduced opacity
            paint.color = Colors.white.withOpacity(0.3);
          }

          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            startAngle,
            pi / 2,
            false,
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectionPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      circleColor != oldDelegate.circleColor;
}

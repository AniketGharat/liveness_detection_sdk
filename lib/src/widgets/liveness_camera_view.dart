import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/liveness_config.dart';
import '../models/liveness_result.dart';
import '../models/liveness_state.dart';
import '../utils/liveness_detector.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(LivenessResult)? onResult;
  final LivenessConfig? config;

  const LivenessCameraView({
    Key? key,
    this.onResult,
    this.config,
  }) : super(key: key);

  @override
  State<LivenessCameraView> createState() => _LivenessCameraViewState();
}

class _LivenessCameraViewState extends State<LivenessCameraView> {
  late CameraController _cameraController;
  late LivenessDetector _livenessDetector;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _cameraController.initialize();
    if (!mounted) return;

    setState(() {
      _isInitialized = true;
    });

    _startLivenessDetection();
  }

  void _startLivenessDetection() {
    _livenessDetector = LivenessDetector(
      config: widget.config ?? const LivenessConfig(),
    );

    // Start processing frames
    _cameraController.startImageStream((image) {
      // Process each frame
      _livenessDetector.processImage(
        image,
        InputImageRotation.rotation0deg,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        CameraPreview(_cameraController),
        CustomPaint(
          painter: FaceOverlayPainter(),
          child: Container(),
        ),
        StreamBuilder<LivenessState>(
          stream: _livenessDetector.livenessState,
          builder: (context, snapshot) {
            return Positioned(
              bottom: 32,
              left: 16,
              right: 16,
              child: Text(
                _getInstructionText(snapshot.data ?? LivenessState.initial),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                ),
                textAlign: TextAlign.center,
              ),
            );
          },
        ),
      ],
    );
  }

  String _getInstructionText(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 'Position your face within the oval';
      case LivenessState.lookingStraight:
        return 'Perfect! Now slowly turn your head left';
      // Add other state messages...
      default:
        return '';
    }
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _livenessDetector.dispose();
    super.dispose();
  }
}

class FaceOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCenter(
      center: center,
      width: size.width * 0.7,
      height: size.height * 0.5,
    );

    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

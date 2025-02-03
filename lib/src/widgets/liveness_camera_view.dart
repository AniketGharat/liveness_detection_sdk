import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../models/liveness_state.dart';
import '../utils/liveness_detection_sdk.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(String)? onImageCaptured;
  final Function()? onComplete;

  const LivenessCameraView({
    Key? key,
    this.onImageCaptured,
    this.onComplete,
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
    _livenessDetector = LivenessDetector();
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

    _cameraController.startImageStream((image) {
      _livenessDetector.processImage(
        image,
        InputImageRotation.rotation0deg, // Adjust based on device orientation
      );
    });

    setState(() {
      _isInitialized = true;
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
        _buildOverlay(),
        _buildInstructions(),
      ],
    );
  }

  Widget _buildOverlay() {
    return CustomPaint(
      painter: FaceOverlayPainter(),
      child: Container(),
    );
  }

  Widget _buildInstructions() {
    return StreamBuilder<LivenessState>(
      stream: _livenessDetector.livenessState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? LivenessState.initial;
        return Positioned(
          bottom: 32,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _getInstructionText(state),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }

  String _getInstructionText(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 'Position your face in the frame';
      case LivenessState.lookingStraight:
        return 'Perfect! Now slowly turn your head left';
      case LivenessState.lookingLeft:
        return 'Good! Now slowly turn your head right';
      case LivenessState.lookingRight:
        return 'Great! Now look straight ahead again';
      case LivenessState.lookingStraightAgain:
        return 'Almost done! Keep looking straight';
      case LivenessState.complete:
        return 'Perfect! Taking photo...';
      case LivenessState.error:
        return 'Error occurred';
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
      ..strokeWidth = 2.0;

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final ovalSize = size.width * 0.7;

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: ovalSize,
        height: ovalSize,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
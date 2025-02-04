import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../../liveness_sdk.dart';
import '../models/liveness_result.dart';
import '../utils/liveness_detector.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(LivenessResult result) onResult;

  const LivenessCameraView({required this.onResult, Key? key})
      : super(key: key);

  @override
  _LivenessCameraViewState createState() => _LivenessCameraViewState();
}

class _LivenessCameraViewState extends State<LivenessCameraView> {
  late LivenessDetector _livenessDetector;
  CameraController? _cameraController;
  bool _isCameraReady = false;
  String _detectionMessage = "";
  List<Face> _faces = [];
  int _currentCameraIndex = 0;
  List<CameraDescription> _cameras = [];

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _livenessDetector = LivenessDetector(
      onFaceDetected: _handleFaceDetectionResult,
    );
  }

  Future<void> _initializeCamera() async {
    _cameras = await availableCameras();

    // Explicitly selecting the front camera
    CameraDescription frontCamera = _cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras.first, // Fallback if no front camera found
    );

    // Initialize the camera controller with front camera
    _initializeCameraController(frontCamera);
  }

  Future<void> _initializeCameraController(CameraDescription camera) async {
    _cameraController = CameraController(camera, ResolutionPreset.high);
    await _cameraController?.initialize();
    if (!mounted) return;
    setState(() {
      _isCameraReady = true;
    });

    // Start streaming images from the camera
    _cameraController?.startImageStream((CameraImage image) {
      _livenessDetector.processImage(image, InputImageRotation.rotation0deg);
    });
  }

  void _handleFaceDetectionResult(List<Face> faces) {
    setState(() {
      _faces = faces;
      if (faces.isEmpty) {
        _detectionMessage = "No face detected";
      } else if (faces.length > 1) {
        _detectionMessage = "Multiple faces detected";
      } else {
        _detectionMessage = "Face detected!";
      }
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _livenessDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Liveness Detection'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isCameraReady)
              Stack(
                children: [
                  CameraPreview(_cameraController!),
                  CustomPaint(
                    painter:
                        FacePainter(_faces, _livenessDetector.currentState),
                    child: Container(),
                  ),
                ],
              ),
            Text(
              _detectionMessage,
              style: TextStyle(fontSize: 20, color: Colors.red),
            ),
          ],
        ),
      ),
    );
  }
}

class FacePainter extends CustomPainter {
  final List<Face> faces;
  final LivenessState currentState;

  FacePainter(this.faces, this.currentState);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    // Mapping the LivenessState to the circle progress (1/4th per step)
    double progress = 0.0;
    switch (currentState) {
      case LivenessState.initial:
        progress = 0.0;
        break;
      case LivenessState.lookingStraight:
        progress = 0.25;
        break;
      case LivenessState.lookingLeft:
        progress = 0.5;
        break;
      case LivenessState.lookingRight:
        progress = 0.75;
        break;
      case LivenessState.complete:
        progress = 1.0;
        break;
      default:
        break;
    }

    // Draw the face circle with the current progress
    for (Face face in faces) {
      final rect = face.boundingBox;
      double radius = rect.width / 2;
      final startAngle = -90.0; // Start from top
      final sweepAngle = 360 * progress;

      paint.color = Colors.green.withOpacity(0.8); // Green color for the circle

      // Draw a partial circle to indicate progress
      canvas.drawArc(
        Rect.fromCircle(center: rect.center, radius: radius),
        startAngle * 3.14159 / 180, // Convert to radians
        sweepAngle * 3.14159 / 180, // Convert to radians
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

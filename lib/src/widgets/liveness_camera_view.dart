import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:vibration/vibration.dart';
import 'package:permission_handler/permission_handler.dart';

class LivenessCameraScreen extends StatefulWidget {
  @override
  _LivenessCameraScreenState createState() => _LivenessCameraScreenState();
}

class _LivenessCameraScreenState extends State<LivenessCameraScreen> {
  CameraController? _controller;
  bool _isDetecting = false;
  late FaceDetector _faceDetector;
  String _instruction = "Position your face in the frame";
  late List<CameraDescription> _cameras;
  late CameraDescription _camera;
  List<Face> _faces = [];

  @override
  void initState() {
    super.initState();
    _initCamera();
    _faceDetector = GoogleMlKit.vision.faceDetector(
      FaceDetectorOptions(
        enableLandmarks: true,
        enableContours: true,
        enableClassification: true,
        minFaceSize: 0.25,
      ),
    );
  }

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    _camera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front);

    await _checkPermissions();

    _controller = CameraController(_camera, ResolutionPreset.high);
    await _controller?.initialize();

    // Start image stream after initialization
    await _controller?.startImageStream((image) => _onImageAvailable(image));

    if (mounted) setState(() {});
  }

  Future<void> _checkPermissions() async {
    var status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Camera permission is required")));
      return;
    }
  }

  Future<void> _onImageAvailable(CameraImage image) async {
    if (_isDetecting) return;
    _isDetecting = true;

    try {
      // Convert CameraImage to InputImage
      final WriteBuffer allBytes = WriteBuffer();
      for (Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final imageRotation = InputImageRotation.rotation0deg;
      final inputImageFormat = InputImageFormat.bgra8888;

      final inputImageData = InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      );

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: inputImageData,
      );

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty && mounted) {
        setState(() {
          _faces = faces;
          _updateFaceTracking(faces.first);
        });
      }
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      _isDetecting = false;
    }
  }

  void _updateFaceTracking(Face face) {
    final eulerY = face.headEulerAngleY;

    if (eulerY != null && eulerY > 20) {
      _instruction = "Looking Left! Slowly move to the right";
      _vibrate();
    } else if (eulerY != null && eulerY < -20) {
      _instruction = "Looking Right! Slowly move to the left";
      _vibrate();
    } else {
      _instruction = "Looking straight. Keep it up!";
    }
  }

  void _vibrate() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 100);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text("Liveness Check")),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          CustomPaint(
            painter: FaceTrackerPainter(_faces),
          ),
          Positioned(
            bottom: 50,
            left: 50,
            right: 50,
            child: Text(
              _instruction,
              style: TextStyle(
                fontSize: 18,
                color: Colors.white,
                backgroundColor: Colors.black.withOpacity(0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class FaceTrackerPainter extends CustomPainter {
  final List<Face> faces;

  FaceTrackerPainter(this.faces);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    for (Face face in faces) {
      canvas.drawRect(face.boundingBox, paint);

      // Draw landmarks if available
      face.landmarks.forEach((type, landmark) {
        if (landmark != null && landmark.position != null) {
          canvas.drawCircle(
            Offset(landmark.position!.x.toDouble(),
                landmark.position!.y.toDouble()),
            5.0,
            paint,
          );
        }
      });

      // Draw contours if available
      face.contours.forEach((contourType, contour) {
        if (contour != null) {
          final points = contour.points;
          for (int i = 0; i < points.length - 1; i++) {
            canvas.drawLine(
              Offset(points[i].x.toDouble(), points[i].y.toDouble()),
              Offset(points[i + 1].x.toDouble(), points[i + 1].y.toDouble()),
              paint,
            );
          }
        }
      });
    }
  }

  @override
  bool shouldRepaint(FaceTrackerPainter oldDelegate) => true;
}

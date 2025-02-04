import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/liveness_result.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(LivenessResult) onResult;

  const LivenessCameraView({Key? key, required this.onResult})
      : super(key: key);

  @override
  _LivenessCameraViewState createState() => _LivenessCameraViewState();
}

class _LivenessCameraViewState extends State<LivenessCameraView> {
  CameraController? _controller;
  bool _isDetecting = false;
  late FaceDetector _faceDetector;
  String _instruction = "Position your face in the frame";
  late List<CameraDescription> _cameras;
  late CameraDescription _camera;
  List<Face> _faces = [];
  bool _isFaceAligned = false;
  int _alignedFrameCount = 0;
  static const int _requiredAlignedFrames = 10;

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

    await _controller?.startImageStream((image) => _onImageAvailable(image));

    if (mounted) setState(() {});
  }

  Future<void> _checkPermissions() async {
    var status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      widget.onResult(LivenessResult(
        isSuccess: false,
        errorMessage: "Camera permission is required",
      ));
      Navigator.pop(context);
    }
  }

  Future<void> _onImageAvailable(CameraImage image) async {
    if (_isDetecting) return;
    _isDetecting = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final inputImageData = InputImageMetadata(
        size: imageSize,
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.bgra8888,
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
      } else {
        setState(() {
          _isFaceAligned = false;
          _alignedFrameCount = 0;
          _instruction = "Position your face in the frame";
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
    final eulerZ = face.headEulerAngleZ;

    bool isAligned = (eulerY != null && eulerY.abs() < 10) &&
        (eulerZ != null && eulerZ.abs() < 10);

    setState(() {
      _isFaceAligned = isAligned;

      if (isAligned) {
        _alignedFrameCount++;
        _instruction =
            "Hold still... ${((_requiredAlignedFrames - _alignedFrameCount) / 30 * 100).round()}%";

        if (_alignedFrameCount >= _requiredAlignedFrames) {
          _captureImage();
        }
      } else {
        _alignedFrameCount = 0;
        if (eulerY != null && eulerY > 10) {
          _instruction = "Turn your head left slightly";
        } else if (eulerY != null && eulerY < -10) {
          _instruction = "Turn your head right slightly";
        } else {
          _instruction = "Center your face";
        }
      }
    });
  }

  Future<void> _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      await _controller?.stopImageStream();
      final XFile image = await _controller!.takePicture();
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String imagePath = '${appDir.path}/liveness_capture.jpg';
      await image.saveTo(imagePath);

      widget.onResult(LivenessResult(
        isSuccess: true,
        imagePath: imagePath,
      ));

      Navigator.pop(context);
    } catch (e) {
      print('Error capturing image: $e');
      widget.onResult(LivenessResult(
        isSuccess: false,
        errorMessage: 'Failed to capture image',
      ));
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
            painter: FaceTrackerPainter(_faces, _isFaceAligned),
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
  final bool isAligned;

  FaceTrackerPainter(this.faces, this.isAligned);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = isAligned ? Colors.green : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    for (Face face in faces) {
      canvas.drawRect(face.boundingBox, paint);

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
    }
  }

  @override
  bool shouldRepaint(FaceTrackerPainter oldDelegate) =>
      faces != oldDelegate.faces || isAligned != oldDelegate.isAligned;
}

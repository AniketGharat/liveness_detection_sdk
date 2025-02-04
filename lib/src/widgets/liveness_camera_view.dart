import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import '../models/liveness_result.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(LivenessResult) onResult;
  final Duration timeoutDuration;
  final double faceAlignmentThreshold;

  const LivenessCameraView({
    Key? key,
    required this.onResult,
    this.timeoutDuration = const Duration(seconds: 30),
    this.faceAlignmentThreshold = 10.0,
  }) : super(key: key);

  @override
  _LivenessCameraViewState createState() => _LivenessCameraViewState();
}

class _LivenessCameraViewState extends State<LivenessCameraView>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isDetecting = false;
  late final FaceDetector _faceDetector;
  String _instruction = "Position your face in the frame";
  late List<CameraDescription> _cameras;
  late CameraDescription _camera;
  List<Face> _faces = [];
  bool _isFaceAligned = false;
  int _alignedFrameCount = 0;
  static const int _requiredAlignedFrames = 10;
  bool _isProcessing = false;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSystem();
    _startTimeoutTimer();
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(widget.timeoutDuration, () {
      _vibrate();
      widget.onResult(LivenessResult(
        isSuccess: false,
        errorMessage: "Verification timeout - please try again",
      ));
      Navigator.pop(context);
    });
  }

  Future<void> _vibrate() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 200);
    }
  }

  Future<void> _initializeSystem() async {
    try {
      await _initCamera();
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableLandmarks: true,
          enableContours: true,
          enableClassification: true,
          minFaceSize: 0.25,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );
    } catch (e) {
      _vibrate();
      widget.onResult(LivenessResult(
        isSuccess: false,
        errorMessage: "Failed to initialize camera: ${e.toString()}",
      ));
      Navigator.pop(context);
    }
  }

  Future<void> _initCamera() async {
    if (!mounted) return;

    final status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      throw Exception("Camera permission denied");
    }

    _cameras = await availableCameras();
    _camera = _cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => throw Exception("No front camera found"),
    );

    _controller = CameraController(
      _camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    await _controller?.initialize();
    if (!mounted) return;

    await _controller?.startImageStream(_onImageAvailable);
    setState(() {});
  }

  Future<void> _onImageAvailable(CameraImage image) async {
    if (_isDetecting || _isProcessing) return;
    _isDetecting = true;

    try {
      final inputImage = await _processImageFrame(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (!mounted) return;

      setState(() {
        _faces = faces;
        if (faces.isNotEmpty) {
          _updateFaceTracking(faces.first);
        } else {
          _resetTracking();
        }
      });
    } catch (e) {
      debugPrint('Error processing image: $e');
    } finally {
      _isDetecting = false;
    }
  }

  Future<InputImage> _processImageFrame(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: imageSize,
        rotation: Platform.isIOS
            ? InputImageRotation.rotation270deg
            : InputImageRotation.rotation0deg,
        format: Platform.isAndroid
            ? InputImageFormat.yuv420
            : InputImageFormat.bgra8888,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  void _updateFaceTracking(Face face) {
    final eulerY = face.headEulerAngleY ?? 0;
    final eulerZ = face.headEulerAngleZ ?? 0;

    bool isAligned = eulerY.abs() < widget.faceAlignmentThreshold &&
        eulerZ.abs() < widget.faceAlignmentThreshold;

    setState(() {
      _isFaceAligned = isAligned;

      if (isAligned) {
        _alignedFrameCount++;
        final progress =
            (_alignedFrameCount / _requiredAlignedFrames * 100).round();
        _instruction = "Hold still... $progress%";

        if (_alignedFrameCount >= _requiredAlignedFrames) {
          _captureImage();
        }
      } else {
        _alignedFrameCount = 0;
        _instruction = _getAlignmentInstruction(eulerY, eulerZ);
      }
    });
  }

  String _getAlignmentInstruction(double eulerY, double eulerZ) {
    if (eulerY.abs() > widget.faceAlignmentThreshold) {
      return eulerY > 0
          ? "Turn your head left slightly"
          : "Turn your head right slightly";
    } else if (eulerZ.abs() > widget.faceAlignmentThreshold) {
      return eulerZ > 0 ? "Tilt your head right" : "Tilt your head left";
    }
    return "Center your face";
  }

  void _resetTracking() {
    _isFaceAligned = false;
    _alignedFrameCount = 0;
    _instruction = "Position your face in the frame";
  }

  Future<void> _captureImage() async {
    if (_isProcessing ||
        _controller == null ||
        !_controller!.value.isInitialized) {
      return;
    }

    setState(() => _isProcessing = true);

    try {
      await _controller?.stopImageStream();
      final XFile image = await _controller!.takePicture();
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String imagePath =
          '${appDir.path}/liveness_capture_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await image.saveTo(imagePath);

      await _vibrate(); // Success vibration
      widget.onResult(LivenessResult(
        isSuccess: true,
        imagePath: imagePath,
      ));

      Navigator.pop(context);
    } catch (e) {
      debugPrint('Error capturing image: $e');
      await _vibrate(); // Error vibration
      widget.onResult(LivenessResult(
        isSuccess: false,
        errorMessage: 'Failed to capture image: ${e.toString()}',
      ));
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return WillPopScope(
      onWillPop: () async {
        await _vibrate();
        widget.onResult(LivenessResult(
          isSuccess: false,
          errorMessage: "Verification cancelled",
        ));
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Liveness Check"),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              await _vibrate();
              widget.onResult(LivenessResult(
                isSuccess: false,
                errorMessage: "Verification cancelled",
              ));
              Navigator.pop(context);
            },
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(_controller!),
            CustomPaint(
              painter: FaceTrackerPainter(
                faces: _faces,
                isAligned: _isFaceAligned,
                canvasSize: MediaQuery.of(context).size,
                previewSize: _controller!.value.previewSize!,
              ),
            ),
            Positioned(
              bottom: 50,
              left: 50,
              right: 50,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _instruction,
                  style: const TextStyle(
                    fontSize: 18,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            if (_isProcessing)
              Container(
                color: Colors.black54,
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class FaceTrackerPainter extends CustomPainter {
  final List<Face> faces;
  final bool isAligned;
  final Size canvasSize;
  final Size previewSize;

  FaceTrackerPainter({
    required this.faces,
    required this.isAligned,
    required this.canvasSize,
    required this.previewSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = isAligned ? Colors.green : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final double scaleX = canvasSize.width / previewSize.width;
    final double scaleY = canvasSize.height / previewSize.height;

    for (Face face in faces) {
      final scaledRect = Rect.fromLTRB(
        face.boundingBox.left * scaleX,
        face.boundingBox.top * scaleY,
        face.boundingBox.right * scaleX,
        face.boundingBox.bottom * scaleY,
      );

      canvas.drawRect(scaledRect, paint);

      // Draw landmarks
      face.landmarks.forEach((_, landmark) {
        if (landmark?.position != null) {
          canvas.drawCircle(
            Offset(
              landmark!.position!.x * scaleX,
              landmark.position!.y * scaleY,
            ),
            5.0,
            paint,
          );
        }
      });
    }
  }

  @override
  bool shouldRepaint(FaceTrackerPainter oldDelegate) =>
      faces != oldDelegate.faces ||
      isAligned != oldDelegate.isAligned ||
      canvasSize != oldDelegate.canvasSize ||
      previewSize != oldDelegate.previewSize;
}

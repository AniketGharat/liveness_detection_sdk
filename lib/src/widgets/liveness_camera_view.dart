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

class _LivenessCameraViewState extends State<LivenessCameraView>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  LivenessDetector? _livenessDetector;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _disposeResources();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (_cameraController != null) return;

    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );

      await _cameraController?.initialize();

      if (!mounted) return;

      setState(() {
        _isInitialized = true;
      });

      _startLivenessDetection();
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  void _startLivenessDetection() {
    _livenessDetector = LivenessDetector(
      config: widget.config ?? const LivenessConfig(),
    );

    _livenessDetector?.detectionResult.listen((result) {
      if (result.isSuccess || result.state == LivenessState.error) {
        widget.onResult?.call(result);
      }
    });

    _cameraController?.startImageStream((image) {
      _livenessDetector?.processImage(
        image,
        InputImageRotation.rotation0deg,
      );
    });
  }

  Future<void> _disposeResources() async {
    await _livenessDetector?.dispose();
    _livenessDetector = null;

    await _cameraController?.stopImageStream();
    await _cameraController?.dispose();
    _cameraController = null;

    if (mounted) {
      setState(() {
        _isInitialized = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _cameraController == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        CameraPreview(_cameraController!),
        CustomPaint(
          size: Size.infinite,
          painter: FaceOverlayPainter(),
        ),
        if (_livenessDetector != null)
          StreamBuilder<LivenessState>(
            stream: _livenessDetector!.livenessState,
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
      case LivenessState.lookingLeft:
        return 'Great! Now turn your head right';
      case LivenessState.lookingRight:
        return 'Almost done! Look straight ahead';
      case LivenessState.complete:
        return 'Verification complete!';
      case LivenessState.error:
        return 'Please try again';
      default:
        return '';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeResources();
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

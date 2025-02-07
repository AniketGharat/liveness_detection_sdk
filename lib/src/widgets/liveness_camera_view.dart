import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:liveness_detection_sdk/src/widgets/animated_message.dart';
import 'package:liveness_detection_sdk/src/widgets/face_overlay_painter.dart';
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
  LivenessDetector? _livenessDetector;
  String _instruction = "Position your face in the circle";
  LivenessState _currentState = LivenessState.initial;
  double _progress = 0.0;
  bool _isFaceDetected = false;
  bool _hasMultipleFaces = false;
  late AnimationController _faceAnimationController;
  late AnimationController _overlayAnimationController;

  // Animation controllers for each state
  late AnimationController _initialAnimationController;
  late AnimationController _lookLeftAnimationController;
  late AnimationController _lookRightAnimationController;
  late AnimationController _lookStraightAnimationController;
  late AnimationController _processingAnimationController;

  @override
  void initState() {
    super.initState();
    _initializeAnimationControllers();
    _initializeCamera();
  }

  void _initializeAnimationControllers() {
    _faceAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _overlayAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // Initialize state-specific animation controllers
    _initialAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _lookLeftAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _lookRightAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _lookStraightAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _processingAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
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
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();

      _livenessDetector = LivenessDetector(
        config: widget.config,
        onStateChanged: _handleStateChanged,
      );

      if (!mounted) return;

      setState(() {});
      await _controller!.startImageStream(_processImage);
    } catch (e) {
      _handleError("Failed to initialize camera: $e");
    }
  }

  void _processImage(CameraImage image) async {
    if (_livenessDetector == null) return;
    await _livenessDetector!.processImage(image);
  }

  void _handleStateChanged(
      LivenessState state, double progress, String message) async {
    if (!mounted) return;

    // Stop all animation controllers
    _stopAllAnimations();

    setState(() {
      _currentState = state;
      _instruction = message;
      _progress = progress;
      _isFaceDetected = state != LivenessState.initial;
      _hasMultipleFaces = state == LivenessState.multipleFaces;
    });

    // Start appropriate animation based on state
    _startStateAnimation(state);

    if (state != LivenessState.initial) {
      _overlayAnimationController.repeat(reverse: true);
      await _vibrateFeedback();
    }

    if (state == LivenessState.complete) {
      await _capturePhoto();
    }
  }

  void _stopAllAnimations() {
    _initialAnimationController.reset();
    _lookLeftAnimationController.reset();
    _lookRightAnimationController.reset();
    _lookStraightAnimationController.reset();
    _processingAnimationController.reset();
  }

  void _startStateAnimation(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        _initialAnimationController.repeat();
        break;
      case LivenessState.lookingLeft:
        _lookLeftAnimationController.repeat();
        break;
      case LivenessState.lookingRight:
        _lookRightAnimationController.repeat();
        break;
      case LivenessState.lookingStraight:
        _lookStraightAnimationController.repeat();
        break;
      case LivenessState.complete:
        _processingAnimationController.repeat();
        break;
      default:
        break;
    }
  }

  Widget _buildStateAnimation() {
    String animationAsset;
    AnimationController controller;

    switch (_currentState) {
      case LivenessState.initial:
        animationAsset = 'assets/animations/face_scan.json';
        controller = _initialAnimationController;
        break;
      case LivenessState.lookingLeft:
        animationAsset = 'assets/animations/look_left.json';
        controller = _lookLeftAnimationController;
        break;
      case LivenessState.lookingRight:
        animationAsset = 'assets/animations/look_right.json';
        controller = _lookRightAnimationController;
        break;
      case LivenessState.lookingStraight:
        animationAsset = 'assets/animations/look_straight.json';
        controller = _lookStraightAnimationController;
        break;
      case LivenessState.complete:
        animationAsset = 'assets/animations/processing.json';
        controller = _processingAnimationController;
        break;
      case LivenessState.multipleFaces:
        animationAsset = 'assets/animations/multiple_faces.json';
        controller = _initialAnimationController;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(top: 20),
      width: 40,
      height: 40,
      child: Lottie.asset(
        animationAsset,
        controller: controller,
        package: 'liveness_detection_sdk',
        fit: BoxFit.contain,
      ),
    );
  }

  Future<void> _vibrateFeedback() async {
    if (await Vibration.hasVibrator() ?? false) {
      await Vibration.vibrate(duration: 200);
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
          Transform.scale(
            scale: 1.0,
            child: Center(
              child: CameraPreview(_controller!),
            ),
          ),
          CustomPaint(
            painter: FaceOverlayPainter(
              progress: _progress,
              animation: _faceAnimationController,
              circleSize: widget.config.circleSize,
              state: _currentState,
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: _buildStateAnimation(),
          ),
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: AnimatedLivenessMessage(
              message: _instruction,
              state: _currentState,
            ),
          ),
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

  @override
  void dispose() {
    _faceAnimationController.dispose();
    _overlayAnimationController.dispose();
    _initialAnimationController.dispose();
    _lookLeftAnimationController.dispose();
    _lookRightAnimationController.dispose();
    _lookStraightAnimationController.dispose();
    _processingAnimationController.dispose();
    _livenessDetector?.dispose();
    _controller?.dispose();
    super.dispose();
  }
}

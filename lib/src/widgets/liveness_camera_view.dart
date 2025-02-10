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

  // Map to store state-specific animation controllers
  final Map<LivenessState, AnimationController> _stateAnimationControllers = {};

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

    // Initialize animation controllers for each state
    LivenessState.values.forEach((state) {
      _stateAnimationControllers[state] = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2000),
      );
    });
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

  String _getAnimationAsset(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 'assets/animations/face_scan.json';
      case LivenessState.lookingLeft:
        return 'assets/animations/look_left.json';
      case LivenessState.lookingRight:
        return 'assets/animations/look_right.json';
      case LivenessState.lookingStraight:
        return 'assets/animations/look_straight.json';
      case LivenessState.complete:
        return 'assets/animations/processing.json';
      case LivenessState.multipleFaces:
        return 'assets/animations/multiple_faces.json';
    }
  }

  void _handleStateChanged(
      LivenessState state, double progress, String message) async {
    if (!mounted) return;

    // Stop all animations
    _stateAnimationControllers.values
        .forEach((controller) => controller.reset());

    setState(() {
      _currentState = state;
      _instruction = message;
      _progress = progress;
      _isFaceDetected = state != LivenessState.initial;
      _hasMultipleFaces = state == LivenessState.multipleFaces;
    });

    // Start the animation for the current state
    _stateAnimationControllers[state]?.repeat();

    if (state != LivenessState.initial) {
      _overlayAnimationController.repeat(reverse: true);
      await _vibrateFeedback();
    }

    if (state == LivenessState.complete) {
      await _capturePhoto();
    }
  }

  // Added missing methods
  void _handleError(String message) {
    widget.onResult(LivenessResult(
      isSuccess: false,
      errorMessage: message,
    ));
    if (mounted) {
      Navigator.pop(context);
    }
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

  Widget _buildStateAnimation() {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.only(top: 60),
        width: 40,
        height: 40,
        child: Lottie.asset(
          _getAnimationAsset(_currentState),
          controller: _stateAnimationControllers[_currentState],
          package: 'liveness_detection_sdk',
          fit: BoxFit.contain,
        ),
      ),
    );
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
          _buildStateAnimation(),
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
    _stateAnimationControllers.values
        .forEach((controller) => controller.dispose());
    _livenessDetector?.dispose();
    _controller?.dispose();
    super.dispose();
  }
}

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';
import 'package:liveness_detection_sdk/src/widgets/animated_message.dart';
import 'package:liveness_detection_sdk/src/widgets/face_overlay_painter.dart';
import 'package:lottie/lottie.dart';
import 'package:permission_handler/permission_handler.dart';

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
  CameraController? _cameraController;
  late AnimationController _overlayAnimationController;
  final Map<LivenessState, AnimationController> _stateAnimationControllers = {};
  LivenessDetector? _livenessDetector;
  LivenessState _currentState = LivenessState.initial;
  String _currentAnimationPath = 'assets/animations/face_scan.json';
  String _instruction = "Position your face in the circle";
  double _progress = 0.0;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeAnimationControllers();
    _initializeCamera();
  }

  void _initializeAnimationControllers() {
    _overlayAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);

    for (var state in LivenessState.values) {
      _stateAnimationControllers[state] = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2000),
      );
    }
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

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();

      _livenessDetector = LivenessDetector(
        config: widget.config,
        onStateChanged: _handleStateChanged,
      );

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
        await _cameraController!.startImageStream(_processImage);
      }
    } catch (e) {
      _handleError("Failed to initialize camera: $e");
    }
  }

  Future<void> _handleStateChanged(
    LivenessState state,
    double progress,
    String message,
    String animationPath,
  ) async {
    if (!mounted) return;

    // Reset previous state animation
    _stateAnimationControllers[_currentState]?.reset();

    setState(() {
      _currentState = state;
      _progress = progress;
      _instruction = message;
      _currentAnimationPath = animationPath;
    });

    // Start new state animation
    _stateAnimationControllers[state]?.forward();

    if (state == LivenessState.complete) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      widget.onResult(LivenessResult(
          isSuccess: true)); // Replace 'null' with actual image data if needed
    }
  }

  void _processImage(CameraImage image) {
    _livenessDetector?.processImage(image);
  }

  void _handleError(String message) {
    print("Error: $message");
    // Implement error handling (e.g., show a snackbar)
  }

  @override
  void dispose() {
    _isInitialized = false;
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _livenessDetector?.dispose();
    _overlayAnimationController.dispose();
    for (var controller in _stateAnimationControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    double circleSize = size.width * 0.6;

    return Scaffold(
      body: _isInitialized
          ? Stack(
              children: [
                // Camera Preview
                SizedBox(
                  width: size.width,
                  height: size.height,
                  child: AspectRatio(
                    aspectRatio: _cameraController!.value.aspectRatio,
                    child: CameraPreview(_cameraController!),
                  ),
                ),

                // Face Overlay
                CustomPaint(
                  size: Size.infinite,
                  painter: FaceOverlayPainter(
                    progress: _progress,
                    animation: _overlayAnimationController,
                    circleSize: 0.6,
                    state: _currentState,
                  ),
                ),

                // Animation & Text
                Positioned(
                  left: 0,
                  right: 0,
                  top: size.height * 0.15, //Positioned on top of Circle
                  child: Column(
                    children: [
                      SizedBox(
                        height: 150,
                        width: 150,
                        child: Lottie.asset(
                          _currentAnimationPath,
                          controller: _stateAnimationControllers[_currentState],
                          onLoaded: (composition) {
                            _stateAnimationControllers[_currentState]
                                ?.duration = composition.duration;
                            _stateAnimationControllers[_currentState]?.reset();
                            _stateAnimationControllers[_currentState]
                                ?.forward(); // Start the animation
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: size.height * 0.25, //Positioned on bottom of Circle
                  child: AnimatedLivenessMessage(
                    message: _instruction,
                    state: _currentState,
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

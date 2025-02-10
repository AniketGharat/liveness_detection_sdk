import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';
import 'package:liveness_detection_sdk/src/widgets/animated_message.dart';
import 'package:liveness_detection_sdk/src/widgets/face_overlay_painter.dart';
import 'package:liveness_detection_sdk/src/widgets/state_animation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:image/image.dart' as img;

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
      duration: const Duration(milliseconds: 1500),
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
      _instruction = message;
      _progress = progress;
      _currentAnimationPath = animationPath;
    });

    // Start new state animation
    _stateAnimationControllers[state]?.repeat();

    if (state != LivenessState.initial) {
      await _vibrateFeedback();
    }

    if (state == LivenessState.complete) {
      await _capturePhoto();
    }
  }

  Future<void> _vibrateFeedback() async {
    if (await Vibration.hasVibrator() ?? false) {
      await Vibration.vibrate(duration: 200);
    }
  }

  void _processImage(CameraImage image) async {
    if (_livenessDetector == null) return;
    await _livenessDetector!.processImage(image);
  }

  Future<void> _capturePhoto() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }

      final XFile photo = await _cameraController!.takePicture();
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

  void _handleCancel() {
    widget.onResult(LivenessResult(
      isSuccess: false,
      errorMessage: "Cancelled by user",
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_isInitialized) ...[
            Transform.scale(
              scale: 1.0,
              child: Center(
                child: CameraPreview(_cameraController!),
              ),
            ),
            CustomPaint(
              painter: FaceOverlayPainter(
                progress: _progress,
                animation: _overlayAnimationController,
                circleSize: widget.config.circleSize,
                state: _currentState,
              ),
            ),
            StateAnimation(
              animationPath: _currentAnimationPath,
              controller: _stateAnimationControllers[_currentState]!,
              state: _currentState,
              progress: _progress,
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
            _buildProgressIndicator(),
            _buildCloseButton(),
            if (_currentState == LivenessState.initial)
              _buildInitialHelperText(),
          ] else ...[
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 20,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: LivenessState.values
            .where((state) => state != LivenessState.multipleFaces)
            .map((state) {
          final isCompleted = _getStateProgress(state) <= _progress;
          return Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: isCompleted ? Colors.green : Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCloseButton() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 20,
      right: 20,
      child: IconButton(
        icon: const Icon(
          Icons.close,
          color: Colors.white,
          size: 30,
        ),
        onPressed: _handleCancel,
      ),
    );
  }

  Widget _buildInitialHelperText() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 100,
      left: 20,
      right: 20,
      child: Text(
        "Make sure your face is well-lit and clearly visible",
        style: TextStyle(
          color: Colors.white.withOpacity(0.8),
          fontSize: 16,
          height: 1.5,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  double _getStateProgress(LivenessState state) {
    return switch (state) {
      LivenessState.initial => 0.0,
      LivenessState.lookingStraight => 0.25,
      LivenessState.lookingLeft => 0.5,
      LivenessState.lookingRight => 0.75,
      LivenessState.complete => 1.0,
      LivenessState.multipleFaces => 0.0,
    };
  }

  @override
  void dispose() {
    _overlayAnimationController.dispose();
    for (var controller in _stateAnimationControllers.values) {
      controller.dispose();
    }
    _livenessDetector?.dispose();
    _cameraController?.dispose();
    super.dispose();
  }
}

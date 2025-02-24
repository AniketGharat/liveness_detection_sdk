import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:image/image.dart' as img;
import 'package:liveness_detection_sdk/src/widgets/animated_message.dart';
import 'package:liveness_detection_sdk/src/widgets/state_animation.dart';
import 'package:liveness_detection_sdk/src/widgets/face_overlay_painter.dart';
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
  CameraController? _cameraController;
  late AnimationController _faceAnimationController;
  final Map<LivenessState, AnimationController> _stateAnimationControllers = {};
  LivenessDetector? _livenessDetector;
  LivenessState _currentState = LivenessState.initial;
  String _currentAnimationPath = 'assets/animations/face_scan_init.json';
  String _instruction = "Position your face in the circle and blink 3 times";
  double _progress = 0.0;
  bool _isInitialized = false;
  List<CameraDescription>? _cameras;
  bool _isFrontCamera = true;
  bool _isProcessing = false;
  bool _isSwitchingCamera = false;

  @override
  void initState() {
    super.initState();
    _initializeAnimationControllers();
    _initializeCamera();
  }

  void _initializeAnimationControllers() {
    // Main face overlay animation
    _faceAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    // Individual state animations
    for (var state in LivenessState.values) {
      _stateAnimationControllers[state] = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 3000),
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
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        _handleError("No cameras available");
        return;
      }

      await _setupCamera();
    } catch (e) {
      _handleError("Failed to initialize camera: $e");
    }
  }

  Future<void> _setupCamera() async {
    if (_cameras == null || _cameras!.isEmpty) return;

    setState(() {
      _isInitialized = false;
      _isSwitchingCamera = true;
    });

    // Stop current image stream if active
    if (_cameraController?.value.isStreamingImages ?? false) {
      await _cameraController?.stopImageStream();
    }

    // Dispose current resources
    await _cameraController?.dispose();
    _livenessDetector?.dispose();

    // Select appropriate camera
    final CameraDescription selectedCamera = _isFrontCamera
        ? _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front,
            orElse: () => _cameras!.first,
          )
        : _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
            orElse: () => _cameras!.first,
          );

    _cameraController = CameraController(
      selectedCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize();

      _livenessDetector = LivenessDetector(
        config: widget.config,
        onStateChanged: _handleStateChanged,
        isFrontCamera: _isFrontCamera,
      );

      if (!mounted) return;

      setState(() {
        _isInitialized = true;
        _isSwitchingCamera = false;
      });

      _resetState();

      // Add delay before starting image stream
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted && _cameraController != null) {
        await _cameraController!.startImageStream(_processImage);
      }
    } catch (e) {
      _handleError("Failed to initialize camera: $e");
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras == null ||
        _cameras!.length < 2 ||
        _isProcessing ||
        _isSwitchingCamera) {
      return;
    }

    setState(() {
      _isFrontCamera = !_isFrontCamera;
    });

    await _setupCamera();
  }

  void _resetState() {
    setState(() {
      _currentState = LivenessState.initial;
      _progress = 0.0;
      _instruction = "Position your face in the circle";
      _currentAnimationPath = 'assets/animations/face_scan_init.json';
      _isProcessing = false;
    });

    // Reset all animation controllers
    for (var controller in _stateAnimationControllers.values) {
      controller.reset();
    }

    // Restart the face animation controller
    _faceAnimationController.reset();
    _faceAnimationController.repeat(reverse: true);
  }

  void _processImage(CameraImage image) async {
    if (_livenessDetector == null ||
        _isProcessing ||
        _isSwitchingCamera ||
        !mounted) return;

    _isProcessing = true;
    try {
      await _livenessDetector!.processImage(image);
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _handleStateChanged(
    LivenessState state,
    double progress,
    String message,
    String animationPath,
  ) async {
    if (!mounted || _isSwitchingCamera) return;

    // Reset controllers only if state actually changed
    if (_currentState != state) {
      for (var controller in _stateAnimationControllers.values) {
        controller.reset();
      }
    }

    setState(() {
      _currentState = state;
      _instruction = message;
      _progress = progress;
      _currentAnimationPath = animationPath;
    });

    _stateAnimationControllers[state]?.repeat();

    if (state != LivenessState.initial &&
        state != LivenessState.multipleFaces) {
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

      // Only flip if using front camera
      final processedImage = _isFrontCamera ? img.flipHorizontal(image) : image;
      final jpgBytes = img.encodeJpg(processedImage);
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

  Widget _buildCameraPreview() {
    if (!_isInitialized || _isSwitchingCamera) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white,
        ),
      );
    }

    return Transform.scale(
      scale: 1.0,
      child: Center(
        child: CameraPreview(_cameraController!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),
          CustomPaint(
            painter: FaceOverlayPainter(
              progress: _progress,
              animation: _faceAnimationController,
              circleSize: widget.config.circleSize,
              state: _currentState,
            ),
          ),
          if (_isInitialized && !_isSwitchingCamera) ...[
            StateAnimation(
              animationPath: _currentAnimationPath,
              controller: _stateAnimationControllers[_currentState]!,
              state: _currentState,
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
              top: MediaQuery.of(context).padding.top + 20,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: _buildProgressIndicators(),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 20,
              left: 20,
              child: IconButton(
                icon: const Icon(
                  Icons.flip_camera_ios,
                  color: Colors.white,
                  size: 30,
                ),
                onPressed: _switchCamera,
              ),
            ),
            Positioned(
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
            ),
            if (_currentState == LivenessState.initial)
              Positioned(
                top: MediaQuery.of(context).padding.bottom + 170,
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
              ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildProgressIndicators() {
    final states = [
      LivenessState.initial,
      LivenessState.lookingLeft,
      LivenessState.lookingRight,
      LivenessState.lookingStraight,
    ];

    return states.map((state) {
      final stateProgress = _getStateProgress(state);
      final isCurrentState = _currentState == state;
      final isCompleted = stateProgress <= _progress;

      return Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: isCompleted
              ? Colors.green
              : isCurrentState
                  ? Colors.white
                  : Colors.white.withOpacity(0.3),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }).toList();
  }

  double _getStateProgress(LivenessState state) {
    return switch (state) {
      LivenessState.initial => 0.0,
      LivenessState.lookingLeft => 0.25,
      LivenessState.lookingRight => 0.50,
      LivenessState.lookingStraight => 0.75,
      LivenessState.complete => 1.0,
      LivenessState.multipleFaces => 0.0,
      LivenessState.failed => 0.0, // Added case for failed state
    };
  }

  @override
  void dispose() {
    _faceAnimationController.dispose();
    for (var controller in _stateAnimationControllers.values) {
      controller.dispose();
    }
    _livenessDetector?.dispose();
    _cameraController?.dispose();
    super.dispose();
  }
}

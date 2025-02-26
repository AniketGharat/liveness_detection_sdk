import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
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
  String _instruction = "Position your face in the circle";
  double _progress = 0.0;
  bool _isInitialized = false;
  List<CameraDescription>? _cameras;
  bool _isFrontCamera = true;
  bool _isProcessing = false;
  bool _isSwitchingCamera = false;
  ResolutionPreset _currentResolution = ResolutionPreset.high;

  @override
  void initState() {
    super.initState();
    _initializeAnimationControllers();
    _initializeCamera();
  }

  void _initializeAnimationControllers() {
    _faceAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    for (var state in LivenessState.values) {
      _stateAnimationControllers[state] = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 3000),
      );
    }
  }

  // In your initializeCamera method
  Future<void> _initializeCamera() async {
    try {
      print("Requesting camera permission...");
      final status = await Permission.camera.request();
      print("Camera permission status: $status");

      if (status != PermissionStatus.granted) {
        print("Camera permission not granted: $status");
        _handleError("Camera permission required");
        return;
      }

      print("Getting available cameras...");
      _cameras = await availableCameras();
      print("Available cameras: ${_cameras?.length}");

      if (_cameras == null || _cameras!.isEmpty) {
        print("No cameras available");
        _handleError("No cameras available");
        return;
      }

      await _setupCamera();
    } catch (e) {
      print("Camera initialization error: $e");
      _handleError("Failed to initialize camera: $e");
    }
  }

  Future<void> _setupCamera() async {
    if (_cameras == null || _cameras!.isEmpty) return;

    setState(() {
      _isInitialized = false;
      _isSwitchingCamera = true;
    });

    // Stop current camera if active
    await _stopCurrentCamera();

    try {
      // Select appropriate camera
      final CameraDescription selectedCamera = _getSelectedCamera();

      // Initialize new camera controller
      await _initializeCameraController(selectedCamera);

      if (!mounted) return;

      setState(() {
        _isInitialized = true;
        _isSwitchingCamera = false;
      });

      _resetState();

      // Add delay before starting image stream
      await Future.delayed(const Duration(milliseconds: 500));
      await _startCameraStream();
    } catch (e) {
      _handleError("Failed to setup camera: $e");
    }
  }

  Future<void> _stopCurrentCamera() async {
    if (_cameraController?.value.isStreamingImages ?? false) {
      await _cameraController?.stopImageStream();
    }
    await _cameraController?.dispose();
    _livenessDetector?.dispose();
  }

  CameraDescription _getSelectedCamera() {
    return _isFrontCamera
        ? _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front,
            orElse: () => _cameras!.first,
          )
        : _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
            orElse: () => _cameras!.first,
          );
  }

  Future<void> _initializeCameraController(CameraDescription camera) async {
    print(
        "Setting up camera controller for ${camera.lensDirection.toString()}");

    // Use lower resolution on iOS
    final resolution = Platform.isIOS
        ? ResolutionPreset.medium
        : (_currentResolution == ResolutionPreset.high
            ? ResolutionPreset.high
            : ResolutionPreset.medium);

    print("Using resolution: $resolution");

    try {
      _cameraController = CameraController(
        camera,
        resolution,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21 // Try changing from bgra8888 to nv21
            : ImageFormatGroup.yuv420,
      );

      print("Initializing camera controller...");
      await _cameraController!.initialize();
      print("Camera controller initialized");

      // Lock orientation on iOS
      if (Platform.isIOS) {
        print("Locking capture orientation on iOS");
        await _cameraController!
            .lockCaptureOrientation(DeviceOrientation.portraitUp);
      }

      _livenessDetector = LivenessDetector(
        config: widget.config,
        onStateChanged: _handleStateChanged,
        isFrontCamera: _isFrontCamera,
      );
      print("Liveness detector created");
    } catch (e) {
      print("Error during camera controller initialization: $e");
      _handleError("Camera initialization failed: $e");
    }
  }

  Future<void> _startCameraStream() async {
    if (mounted && _cameraController != null) {
      await _cameraController!.startImageStream(_processImage);
    }
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
    _faceAnimationController.reset();
    _faceAnimationController.repeat(reverse: true);
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
    String instructions,
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
      _currentAnimationPath = _getAnimationPathForState(state);
    });

    _stateAnimationControllers[state]?.repeat();

    // Provide haptic feedback for state changes
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
      // Stop image stream before capturing
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

      // Apply different transformations based on platform and camera
      final processedImage;
      if (Platform.isIOS) {
        if (_isFrontCamera) {
          // iOS front camera may need different transformations
          processedImage = img.flipHorizontal(image);
        } else {
          processedImage = image;
        }
      } else {
        // Android processing (as you had before)
        processedImage = _isFrontCamera ? img.flipHorizontal(image) : image;
      }

      final jpgBytes = img.encodeJpg(processedImage, quality: 90);
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

  String _getAnimationPathForState(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 'assets/animations/face_scan_init.json';
      case LivenessState.lookingLeft:
        return 'assets/animations/look_left.json';
      case LivenessState.lookingRight:
        return 'assets/animations/look_right.json';
      case LivenessState.lookingStraight:
        return 'assets/animations/look_straight.json';
      case LivenessState.complete:
        return 'assets/animations/face_success.json';
      default:
        return 'assets/animations/face_scan_init.json';
    }
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
            _buildStateAnimation(),
            _buildInstructionMessage(),
            _buildProgressIndicators(),
            _buildCameraControls(),
            if (_currentState == LivenessState.initial)
              _buildInitialStateGuide(),
          ],
        ],
      ),
    );
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

  Widget _buildStateAnimation() {
    return StateAnimation(
      animationPath: _currentAnimationPath,
      controller: _stateAnimationControllers[_currentState]!,
      state: _currentState,
    );
  }

  Widget _buildInstructionMessage() {
    return Positioned(
      bottom: 50,
      left: 20,
      right: 20,
      child: AnimatedLivenessMessage(
        message: _instruction,
        state: _currentState,
      ),
    );
  }

  Widget _buildProgressIndicators() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 20,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: _buildProgressSteps(),
      ),
    );
  }

  List<Widget> _buildProgressSteps() {
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

  Widget _buildCameraControls() {
    return Stack(
      children: [
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
      ],
    );
  }

  Widget _buildInitialStateGuide() {
    return Positioned(
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
    );
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

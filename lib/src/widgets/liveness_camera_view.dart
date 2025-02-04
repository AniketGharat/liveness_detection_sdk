import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../models/liveness_state.dart';
import '../models/liveness_result.dart';
import '../models/liveness_config.dart';
import '../theme/liveness_theme.dart';
import '../utils/liveness_detector.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(LivenessResult)? onResult;
  final LivenessConfig? config;
  final LivenessTheme? theme;
  final bool showDebugInfo;

  const LivenessCameraView({
    Key? key,
    this.onResult,
    this.config,
    this.theme,
    this.showDebugInfo = false,
  }) : super(key: key);

  @override
  State<LivenessCameraView> createState() => _LivenessCameraViewState();
}

class _LivenessCameraViewState extends State<LivenessCameraView>
    with WidgetsBindingObserver {
  late CameraController _cameraController;
  late LivenessDetector _livenessDetector;
  bool _isInitialized = false;
  bool _isCameraPermissionGranted = false;
  StreamSubscription? _resultSubscription;
  StreamSubscription? _stateSubscription;
  LivenessState _currentState = LivenessState.initial;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _livenessDetector = LivenessDetector(
      config: widget.config ?? const LivenessConfig(),
    );
    _setupSubscriptions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes
    if (state == AppLifecycleState.inactive) {
      _cameraController.stopImageStream();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _requestCameraPermission() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _errorMessage = 'No cameras available';
        });
        return;
      }
      setState(() {
        _isCameraPermissionGranted = true;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Camera permission denied';
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (!_isCameraPermissionGranted) {
      await _requestCameraPermission();
      if (!_isCameraPermissionGranted) return;
    }

    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        front,
        widget.config?.cameraResolution ?? ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController.initialize();
      if (!mounted) return;

      await _cameraController.lockCaptureOrientation(
        DeviceOrientation.portraitUp,
      );

      _cameraController.startImageStream((image) {
        final rotation = _getInputImageRotation(
          _cameraController.description.sensorOrientation,
        );

        _livenessDetector.processImage(image, rotation);
      });

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to initialize camera: $e';
      });
    }
  }

  InputImageRotation _getInputImageRotation(int sensorOrientation) {
    final rotationIntValue = Platform.isIOS ? 0 : sensorOrientation ~/ 90;
    return InputImageRotation.values[rotationIntValue];
  }

  void _setupSubscriptions() {
    _resultSubscription?.cancel();
    _resultSubscription = _livenessDetector.detectionResult.listen(
      (result) {
        widget.onResult?.call(result);
        if (result.state == LivenessState.complete) {
          _captureImage();
        }
      },
    );

    _stateSubscription?.cancel();
    _stateSubscription = _livenessDetector.livenessState.listen(
      (state) {
        setState(() {
          _currentState = state;
          if (state != LivenessState.error) {
            _errorMessage = null;
          }
        });
      },
    );
  }

  Future<void> _captureImage() async {
    try {
      final xFile = await _cameraController.takePicture();
      widget.onResult?.call(LivenessResult(
        isSuccess: true,
        imagePath: xFile.path,
        state: LivenessState.complete,
      ));
    } catch (e) {
      widget.onResult?.call(LivenessResult(
        isSuccess: false,
        errorMessage: 'Failed to capture image: $e',
        state: LivenessState.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return _buildErrorView();
    }

    if (!_isInitialized) {
      return _buildLoadingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildCameraPreview(),
        _buildOverlay(),
        _buildInstructions(),
        if (widget.showDebugInfo) _buildDebugInfo(),
      ],
    );
  }

  Widget _buildErrorView() {
    return Container(
      color: widget.theme?.backgroundColor ?? Colors.black,
      child: Center(
        child: Text(
          _errorMessage ?? 'Unknown error',
          style: widget.theme?.errorTextStyle ??
              const TextStyle(color: Colors.red, fontSize: 18),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Container(
      color: widget.theme?.backgroundColor ?? Colors.black,
      child: Center(
        child: CircularProgressIndicator(
          color: widget.theme?.progressIndicatorColor ?? Colors.blue,
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    return Transform.scale(
      scale: _cameraController.value.aspectRatio /
          MediaQuery.of(context).size.aspectRatio,
      child: Center(
        child: CameraPreview(_cameraController),
      ),
    );
  }

  Widget _buildOverlay() {
    return CustomPaint(
      painter: FaceOverlayPainter(
        ovalColor: widget.theme?.ovalColor ?? Colors.white,
        strokeWidth: widget.theme?.ovalStrokeWidth ?? 2.0,
      ),
      child: Container(),
    );
  }

  Widget _buildInstructions() {
    return Positioned(
      bottom: 32,
      left: 16,
      right: 16,
      child: Container(
        padding: widget.theme?.instructionPadding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: widget.theme?.overlayColor ?? Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _getInstructionText(),
              style: widget.theme?.instructionTextStyle ??
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                  ),
              textAlign: TextAlign.center,
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _errorMessage!,
                  style: widget.theme?.errorTextStyle ??
                      const TextStyle(
                        color: Colors.red,
                        fontSize: 16,
                      ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDebugInfo() {
    return Positioned(
      top: 32,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'State: $_currentState\n'
          'Camera Resolution: ${widget.config?.cameraResolution ?? ResolutionPreset.medium}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  String _getInstructionText() {
    switch (_currentState) {
      case LivenessState.initial:
        return 'Position your face within the oval';
      case LivenessState.lookingStraight:
        return 'Perfect! Now slowly turn your head to the left';
      case LivenessState.lookingLeft:
        return 'Good! Now slowly turn your head to the right';
      case LivenessState.lookingRight:
        return 'Great! Now look straight ahead again';
      case LivenessState.lookingStraightAgain:
        return 'Almost done! Keep looking straight';
      case LivenessState.blinkEyes:
        return 'Now blink both eyes';
      case LivenessState.complete:
        return 'Perfect! Processing...';
      case LivenessState.error:
        return 'Please try again';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resultSubscription?.cancel();
    _stateSubscription?.cancel();
    _cameraController.dispose();
    _livenessDetector.dispose();
    super.dispose();
  }
}

class FaceOverlayPainter extends CustomPainter {
  final Color ovalColor;
  final double strokeWidth;

  FaceOverlayPainter({
    required this.ovalColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ovalColor.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final ovalWidth = size.width * 0.7;
    final ovalHeight = size.height * 0.5;

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: ovalWidth,
        height: ovalHeight,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      ovalColor != oldDelegate.ovalColor ||
      strokeWidth != oldDelegate.strokeWidth;
}

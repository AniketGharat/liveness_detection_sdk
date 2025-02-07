import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double, String) onStateChanged;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;
  Timer? _faceDetectionTimer;
  int _requiredFramesCount = 0;

  LivenessDetector({
    required this.config,
    required this.onStateChanged,
  }) {
    _initializeFaceDetector();
  }

  void _initializeFaceDetector() {
    final options = FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.fast,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<void> processImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _updateState(LivenessState.initial, "Position your face in the circle");
        return;
      }

      if (faces.length > 1) {
        _updateState(LivenessState.initial, "Multiple faces detected");
        return;
      }

      final face = faces.first;
      await _processDetectedFace(face);
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<InputImage> _convertCameraImageToInputImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (var plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }

    final bytes = allBytes.done().buffer.asUint8List();
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation270deg,
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Future<void> _processDetectedFace(Face face) async {
    final headEulerY = face.headEulerAngleY ?? 0.0;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(
                LivenessState.lookingStraight, "Now turn your head left");
          }
        } else {
          _resetProgress();
        }
        break;

      // Continuing from the previous liveness_detector.dart

      case LivenessState.lookingStraight:
        if (headEulerY < -config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft, "Now turn your head right");
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingLeft:
        if (headEulerY > config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingRight, "Now center your face");
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingRight:
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.complete, "Perfect! Processing...");
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.complete:
        break;
    }
  }

  bool _isFaceCentered(Face face) {
    final eulerY = face.headEulerAngleY ?? 0.0;
    final eulerZ = face.headEulerAngleZ ?? 0.0;
    return eulerY.abs() < config.straightThreshold &&
        eulerZ.abs() < config.straightThreshold;
  }

  void _resetProgress() {
    _requiredFramesCount = 0;
  }

  void _updateState(LivenessState newState, String message) {
    _currentState = newState;
    final progress = switch (newState) {
      LivenessState.initial => 0.0,
      LivenessState.lookingStraight => 0.25,
      LivenessState.lookingLeft => 0.5,
      LivenessState.lookingRight => 0.75,
      LivenessState.complete => 1.0,
    };
    _requiredFramesCount = 0;
    onStateChanged(newState, progress, message);
  }

  Future<void> dispose() async {
    _faceDetectionTimer?.cancel();
    await _faceDetector.close();
  }
}

// Save this as animated_message.dart
class AnimatedLivenessMessage extends StatefulWidget {
  final String message;
  final LivenessState state;

  const AnimatedLivenessMessage({
    Key? key,
    required this.message,
    required this.state,
  }) : super(key: key);

  @override
  State<AnimatedLivenessMessage> createState() =>
      _AnimatedLivenessMessageState();
}

class _AnimatedLivenessMessageState extends State<AnimatedLivenessMessage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;
  String _displayedMessage = '';

  @override
  void initState() {
    super.initState();
    _displayedMessage = widget.message;
    _initializeAnimations();
  }

  void _initializeAnimations() {
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.2),
        weight: 40.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.2, end: 1.0),
        weight: 60.0,
      ),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _opacityAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        weight: 40.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.0),
        weight: 60.0,
      ),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _controller.forward();
  }

  @override
  void didUpdateWidget(AnimatedLivenessMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message != oldWidget.message) {
      setState(() {
        _displayedMessage = widget.message;
      });
      _controller.reset();
      _controller.forward();
    }
  }

  Color _getMessageColor() {
    return switch (widget.state) {
      LivenessState.complete => Colors.green,
      LivenessState.initial => Colors.white,
      _ => Colors.white,
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Opacity(
            opacity: _opacityAnimation.value,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _getMessageColor().withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: Text(
                _displayedMessage,
                style: TextStyle(
                  color: _getMessageColor(),
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

// Save this as main.dart or wherever you want to use the LivenessCameraView
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: LivenessCameraView(
          onResult: (result) {
            if (result.isSuccess) {
              print('Liveness check successful: ${result.imagePath}');
            } else {
              print('Liveness check failed: ${result.errorMessage}');
            }
          },
          config: const LivenessConfig(
            requiredFrames: 5,
            straightThreshold: 10.0,
            turnThreshold: 15.0,
            circleSize: 0.8,
          ),
        ),
      ),
    );
  }
}

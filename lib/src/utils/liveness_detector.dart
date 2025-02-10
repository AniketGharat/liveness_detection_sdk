import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:lottie/lottie.dart';
import '../../liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double, String, String) onStateChanged;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;
  int _requiredFramesCount = 0;
  int _stableFrameCount = 0;
  String _currentAnimation = 'assets/animations/face_scan.json';

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

  String _getAnimationForState(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 'assets/animations/face_scan.json';
      case LivenessState.lookingStraight:
        return 'assets/animations/look_straight.json';
      case LivenessState.lookingLeft:
        return 'assets/animations/look_left.json';
      case LivenessState.lookingRight:
        return 'assets/animations/look_right.json';
      case LivenessState.complete:
        return 'assets/animations/processing.json';
      case LivenessState.multipleFaces:
        return 'assets/animations/multiple_faces.json';
    }
  }

  void _updateState(LivenessState newState, String message) {
    _currentState = newState;
    final progress = switch (newState) {
      LivenessState.initial => 0.0,
      LivenessState.lookingStraight => 0.25,
      LivenessState.lookingLeft => 0.5,
      LivenessState.lookingRight => 0.75,
      LivenessState.complete => 1.0,
      LivenessState.multipleFaces => 0.0,
    };
    _currentAnimation = _getAnimationForState(newState);
    _requiredFramesCount = 0;
    _stableFrameCount = 0;
    onStateChanged(newState, progress, message, _currentAnimation);
  }

  Future<void> processImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _updateState(LivenessState.initial, "Position your face in the circle");
        _stableFrameCount = 0;
        return;
      }

      if (faces.length > 1) {
        _updateState(LivenessState.multipleFaces, "Multiple faces detected");
        _stableFrameCount = 0;
        return;
      }

      final face = faces.first;
      await _processDetectedFace(face);
    } catch (e) {
      debugPrint('Error processing image: $e');
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
          _stableFrameCount++;
          if (_stableFrameCount >= 10) {
            _requiredFramesCount++;
            if (_requiredFramesCount >= config.requiredFrames) {
              _updateState(LivenessState.lookingStraight,
                  "Great! Now turn your head left slowly");
            }
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingStraight:
        if (headEulerY < -config.turnThreshold) {
          _stableFrameCount++;
          if (_stableFrameCount >= 10) {
            _requiredFramesCount++;
            if (_requiredFramesCount >= config.requiredFrames) {
              _updateState(LivenessState.lookingLeft,
                  "Good! Now turn your head right slowly");
            }
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingLeft:
        if (headEulerY > config.turnThreshold) {
          _stableFrameCount++;
          if (_stableFrameCount >= 10) {
            _requiredFramesCount++;
            if (_requiredFramesCount >= config.requiredFrames) {
              _updateState(
                  LivenessState.lookingRight, "Great! Now center your face");
            }
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingRight:
        if (_isFaceCentered(face)) {
          _stableFrameCount++;
          if (_stableFrameCount >= 10) {
            _requiredFramesCount++;
            if (_requiredFramesCount >= config.requiredFrames) {
              _updateState(LivenessState.complete, "Perfect! Processing...");
            }
          }
        } else {
          _resetProgress();
        }
        break;

      default:
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
    _stableFrameCount = 0;
  }

  void dispose() {
    _faceDetector.close();
  }
}

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double, String, String) onStateChanged;
  final bool isFrontCamera;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  bool _isDisposed = false;

  LivenessState _currentState = LivenessState.initial;
  int _stableFrameCount = 0;
  bool _hasCompletedLeft = false;
  bool _hasCompletedRight = false;

  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;
  DateTime? _stateStartTime;
  DateTime? _lastStateChange;
  DateTime? _lastValidAngle;
  double _lastEulerY = 0.0;

  // Anti-spoofing properties
  final int _textureAnalysisFrames = 5;
  final double _minTextureVariance = 2.0;
  final double _maxTextureVariance = 50.0;
  final double _minLightVariance = 3.0;
  final int _textureGridSize = 20;
  final int _lightHistorySize = 10;

  List<double> _textureVarianceHistory = [];
  List<double> _lightLevelsHistory = [];
  bool _isRealFace = false;
  int _spoofCheckCounter = 0;
  final int _spoofCheckInterval = 5; // Check every 5 frames

  final Map<LivenessState, double> _stateProgress = {
    LivenessState.initial: 0.0,
    LivenessState.lookingLeft: 0.0,
    LivenessState.lookingRight: 0.0,
    LivenessState.lookingStraight: 0.0,
  };

  LivenessDetector({
    required this.config,
    required this.onStateChanged,
    required this.isFrontCamera,
  }) {
    _initializeFaceDetector();
    _updateState(LivenessState.initial);
  }

  void _initializeFaceDetector() {
    final options = FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.accurate,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<void> processImage(CameraImage image) async {
    if (_isProcessing ||
        _currentState == LivenessState.complete ||
        _isDisposed) {
      return;
    }
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _handleNoFace();
      } else if (faces.length > 1) {
        _handleMultipleFaces();
      } else {
        // Increment spoof check counter
        _spoofCheckCounter++;

        // Perform spoof detection periodically
        if (_spoofCheckCounter >= _spoofCheckInterval) {
          _spoofCheckCounter = 0;
          _isRealFace = await _performSpoofDetection(image, faces.first);

          if (!_isRealFace) {
            _handleSpoofDetected();
            return;
          }
        }

        await _processDetectedFace(faces.first);
      }
    } catch (e) {
      debugPrint('Error in processImage: $e');
      _handleError();
    } finally {
      _isProcessing = false;
    }
  }

  Future<InputImage> _convertCameraImageToInputImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final InputImageRotation rotation = isFrontCamera
        ? InputImageRotation.rotation270deg
        : InputImageRotation.rotation90deg;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: metadata,
    );
  }

  Future<bool> _performSpoofDetection(CameraImage image, Face face) async {
    try {
      final faceRect = face.boundingBox;

      // Extract face region pixels
      List<int> facePixels = await _extractFaceRegionPixels(image, faceRect);

      // Perform texture analysis
      double textureVariance = _analyzeTexture(facePixels);
      _updateTextureHistory(textureVariance);

      // Analyze light levels
      double avgLightLevel = _calculateAverageLightLevel(facePixels);
      _updateLightHistory(avgLightLevel);

      // Check for spoof indicators
      bool passesTextureCheck = _checkTextureVariance();
      bool passesLightCheck = _checkLightVariance();
      bool passesMoireCheck = !_detectMoirePattern(facePixels);

      return passesTextureCheck && passesLightCheck && passesMoireCheck;
    } catch (e) {
      debugPrint('Spoof detection error: $e');
      return false;
    }
  }

  Future<List<int>> _extractFaceRegionPixels(
      CameraImage image, Rect faceRect) async {
    List<int> pixels = [];

    int startX = faceRect.left.toInt().clamp(0, image.width - 1);
    int startY = faceRect.top.toInt().clamp(0, image.height - 1);
    int endX = faceRect.right.toInt().clamp(0, image.width - 1);
    int endY = faceRect.bottom.toInt().clamp(0, image.height - 1);

    // Sample pixels in a grid pattern
    for (int y = startY; y < endY; y += _textureGridSize) {
      for (int x = startX; x < endX; x += _textureGridSize) {
        int pixelValue = _getPixelValue(image, x, y);
        pixels.add(pixelValue);
      }
    }

    return pixels;
  }

  int _getPixelValue(CameraImage image, int x, int y) {
    final int pixelIndex = y * image.planes[0].bytesPerRow + x;
    return image.planes[0].bytes[pixelIndex];
  }

  double _analyzeTexture(List<int> pixels) {
    if (pixels.isEmpty) return 0.0;

    double mean = pixels.reduce((a, b) => a + b) / pixels.length;
    double sumSquaredDiff =
        pixels.fold(0.0, (sum, value) => sum + (value - mean) * (value - mean));

    return sumSquaredDiff / pixels.length;
  }

  void _updateTextureHistory(double variance) {
    _textureVarianceHistory.add(variance);
    if (_textureVarianceHistory.length > _textureAnalysisFrames) {
      _textureVarianceHistory.removeAt(0);
    }
  }

  void _updateLightHistory(double lightLevel) {
    _lightLevelsHistory.add(lightLevel);
    if (_lightLevelsHistory.length > _lightHistorySize) {
      _lightLevelsHistory.removeAt(0);
    }
  }

  double _calculateAverageLightLevel(List<int> pixels) {
    if (pixels.isEmpty) return 0.0;
    return pixels.reduce((a, b) => a + b) / pixels.length;
  }

  bool _checkTextureVariance() {
    if (_textureVarianceHistory.length < _textureAnalysisFrames) return true;

    double avgVariance = _textureVarianceHistory.reduce((a, b) => a + b) /
        _textureVarianceHistory.length;

    return avgVariance > _minTextureVariance &&
        avgVariance < _maxTextureVariance;
  }

  bool _checkLightVariance() {
    if (_lightLevelsHistory.length < _lightHistorySize) return true;

    double variance = _calculateVariance(_lightLevelsHistory);
    return variance > _minLightVariance;
  }

  bool _detectMoirePattern(List<int> pixels) {
    if (pixels.length < 4) return false;

    int patternCount = 0;
    for (int i = 0; i < pixels.length - 3; i++) {
      List<int> window = pixels.sublist(i, i + 4);
      if (_isRegularPattern(window)) {
        patternCount++;
      }
    }

    return (patternCount / (pixels.length - 3)) > 0.3;
  }

  bool _isRegularPattern(List<int> values) {
    int diff1 = (values[1] - values[0]).abs();
    int diff2 = (values[2] - values[1]).abs();
    int diff3 = (values[3] - values[2]).abs();

    const tolerance = 5;
    return (diff1 - diff2).abs() <= tolerance &&
        (diff2 - diff3).abs() <= tolerance;
  }

  double _calculateVariance(List<double> values) {
    if (values.isEmpty) return 0.0;

    double mean = values.reduce((a, b) => a + b) / values.length;
    double sumSquaredDiff =
        values.fold(0.0, (sum, value) => sum + (value - mean) * (value - mean));

    return sumSquaredDiff / values.length;
  }

  // Original face processing logic
  Future<void> _processDetectedFace(Face face) async {
    double rawEulerY = face.headEulerAngleY ?? 0.0;
    double headEulerY = isFrontCamera ? rawEulerY : -rawEulerY;

    final now = DateTime.now();
    _stateStartTime ??= now;

    if ((_lastEulerY - headEulerY).abs() > config.straightThreshold) {
      _lastValidAngle = now;
    }
    _lastEulerY = headEulerY;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceStraight(headEulerY)) {
          _updateStateProgress(LivenessState.initial);
        }
        break;
      case LivenessState.lookingLeft:
        if (_isValidLeftTurn(headEulerY)) {
          _updateStateProgress(LivenessState.lookingLeft);
        }
        break;
      case LivenessState.lookingRight:
        if (_isValidRightTurn(headEulerY)) {
          _updateStateProgress(LivenessState.lookingRight);
        }
        break;
      case LivenessState.lookingStraight:
        if (_isFaceStraight(headEulerY)) {
          _updateStateProgress(LivenessState.lookingStraight);
        }
        break;
      default:
        break;
    }

    await _processCurrentState(face, headEulerY);
  }

  // Keep all existing helper methods...
  bool _isValidLeftTurn(double headEulerY) {
    final threshold =
        isFrontCamera ? config.turnThreshold : -config.turnThreshold;
    return isFrontCamera ? headEulerY >= threshold : headEulerY >= threshold;
  }

  bool _isValidRightTurn(double headEulerY) {
    final threshold =
        isFrontCamera ? -config.turnThreshold : config.turnThreshold;
    return isFrontCamera ? headEulerY <= threshold : headEulerY <= threshold;
  }

  bool _isFaceStraight(double headEulerY) {
    return headEulerY.abs() < config.straightThreshold;
  }

  Future<void> _processCurrentState(Face face, double headEulerY) async {
    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceStraight(headEulerY)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft);
            _resetStateTracking();
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      case LivenessState.lookingLeft:
        if (_isValidLeftTurn(headEulerY)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _hasCompletedLeft = true;
            _updateState(LivenessState.lookingRight);
            _resetStateTracking();
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      case LivenessState.lookingRight:
        if (_isValidRightTurn(headEulerY)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _hasCompletedRight = true;
            _updateState(LivenessState.lookingStraight);
            _resetStateTracking();
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      case LivenessState.lookingStraight:
        if (_isFaceStraight(headEulerY)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _updateState(LivenessState.complete);
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      default:
        break;
    }
  }

  void _handleNoFace() {
    if (_currentState != LivenessState.initial) {
      _updateState(LivenessState.initial);
    }
    _incrementErrorCount();
  }

  void _handleMultipleFaces() {
    _resetProgress();
    _updateState(LivenessState.multipleFaces);
    _incrementErrorCount();
  }

  void _handleSpoofDetected() {
    _resetProgress();
    _updateState(LivenessState.failed);
    onStateChanged(
        LivenessState.failed,
        0.0,
        "Please use a real face, not an image or screen",
        "Spoof detected - please try again with a real face");
  }

  void _handleError() {
    _incrementErrorCount();
    if (_consecutiveErrors > config.maxConsecutiveErrors) {
      _resetProgress();
      _updateState(LivenessState.failed);
    }
  }

  void _incrementErrorCount() {
    final now = DateTime.now();
    if (_lastErrorTime != null &&
        now.difference(_lastErrorTime!) > config.errorResetDuration) {
      _consecutiveErrors = 0;
    }
    _consecutiveErrors++;
    _lastErrorTime = now;
  }

  void _updateStateProgress(LivenessState state) {
    _stateProgress[state] =
        (_stableFrameCount / config.requiredFrames).clamp(0.0, 1.0);
  }

  void _resetStateTracking() {
    _stableFrameCount = 0;
    _lastValidAngle = null;
  }

  void _updateState(LivenessState newState) {
    if (_currentState == newState) return;

    _currentState = newState;
    _lastStateChange = DateTime.now();
    _stableFrameCount = 0;

    switch (newState) {
      case LivenessState.initial:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 0.0;
        _stateProgress[LivenessState.lookingRight] = 0.0;
        _stateProgress[LivenessState.lookingStraight] = 0.0;
        break;

      case LivenessState.lookingLeft:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 0.0;
        _stateProgress[LivenessState.lookingRight] = 0.0;
        _stateProgress[LivenessState.lookingStraight] = 0.0;
        break;

      case LivenessState.lookingRight:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 1.0;
        _stateProgress[LivenessState.lookingRight] = 0.0;
        _stateProgress[LivenessState.lookingStraight] = 0.0;
        break;

      case LivenessState.lookingStraight:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 1.0;
        _stateProgress[LivenessState.lookingRight] = 1.0;
        _stateProgress[LivenessState.lookingStraight] = 0.0;
        break;

      case LivenessState.complete:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 1.0;
        _stateProgress[LivenessState.lookingRight] = 1.0;
        _stateProgress[LivenessState.lookingStraight] = 1.0;
        break;

      case LivenessState.failed:
      case LivenessState.multipleFaces:
        _stateProgress.forEach((state, _) {
          _stateProgress[state] = 0.0;
        });
        break;
    }

    onStateChanged(
      newState,
      calculateTotalProgress(),
      _getStateMessage(newState),
      _getCurrentStateInstructions(),
    );
  }

  double calculateTotalProgress() {
    if (_currentState == LivenessState.failed ||
        _currentState == LivenessState.multipleFaces) {
      return 0.0;
    }

    double total = 0.0;

    if (_stateProgress[LivenessState.initial]! >= 1.0) {
      total += 0.25;
    }

    if (_currentState != LivenessState.initial &&
        _stateProgress[LivenessState.lookingLeft]! >= 1.0) {
      total += 0.25;
    }

    if (_currentState != LivenessState.initial &&
        _currentState != LivenessState.lookingLeft &&
        _stateProgress[LivenessState.lookingRight]! >= 1.0) {
      total += 0.25;
    }

    if (_currentState == LivenessState.complete &&
        _stateProgress[LivenessState.lookingStraight]! >= 1.0) {
      total += 0.25;
    }

    return total;
  }

  void _resetProgress() {
    _stableFrameCount = 0;
    _hasCompletedLeft = false;
    _hasCompletedRight = false;
    _lastValidAngle = null;
    _stateStartTime = null;
    _lastStateChange = null;
    _textureVarianceHistory.clear();
    _lightLevelsHistory.clear();
    _isRealFace = false;
    _spoofCheckCounter = 0;

    for (var state in _stateProgress.keys) {
      _stateProgress[state] = 0.0;
    }
  }

  String _getStateMessage(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return "Position your face in the frame";
      case LivenessState.lookingLeft:
        return "Turn your head left";
      case LivenessState.lookingRight:
        return "Turn your head right";
      case LivenessState.lookingStraight:
        return "Look straight ahead";
      case LivenessState.complete:
        return "Verification complete";
      case LivenessState.multipleFaces:
        return "Multiple faces detected";
      case LivenessState.failed:
        return !_isRealFace
            ? "Please use a real face, not an image or screen"
            : "Verification failed";
      default:
        return "";
    }
  }

  String _getCurrentStateInstructions() {
    switch (_currentState) {
      case LivenessState.initial:
        return "Center your face in the frame and look straight ahead";
      case LivenessState.lookingLeft:
        return "Slowly turn your head to the left";
      case LivenessState.lookingRight:
        return "Slowly turn your head to the right";
      case LivenessState.lookingStraight:
        return "Return to looking straight ahead";
      case LivenessState.complete:
        return "Liveness verification completed successfully";
      case LivenessState.multipleFaces:
        return "Please ensure only one face is visible";
      case LivenessState.failed:
        return !_isRealFace
            ? "Please try again with a real face"
            : "Please try again";
      default:
        return "";
    }
  }

  void dispose() {
    _isDisposed = true;
    _faceDetector.close();
  }
}

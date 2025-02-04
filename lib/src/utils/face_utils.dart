import 'package:flutter/cupertino.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceUtils {
  static bool isFacePositionValid(Face face, Size imageSize) {
    final boundingBox = face.boundingBox;
    final centerX = boundingBox.center.dx;
    final centerY = boundingBox.center.dy;

    return centerX >= imageSize.width * 0.3 &&
        centerX <= imageSize.width * 0.7 &&
        centerY >= imageSize.height * 0.3 &&
        centerY <= imageSize.height * 0.7;
  }

  static bool isFaceQualityAcceptable(Face face) {
    if (face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null) {
      final leftEyeOpen = face.leftEyeOpenProbability! > 0.8;
      final rightEyeOpen = face.rightEyeOpenProbability! > 0.8;
      return leftEyeOpen && rightEyeOpen;
    }
    return true;
  }

  static bool isBlinking(Face face) {
    if (face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null) {
      return face.leftEyeOpenProbability! < 0.2 &&
          face.rightEyeOpenProbability! < 0.2;
    }
    return false;
  }
}

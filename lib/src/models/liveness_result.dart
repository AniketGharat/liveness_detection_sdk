import 'liveness_state.dart';

class LivenessResult {
  final bool isSuccess;
  final String? imagePath;
  final String? errorMessage;
  final LivenessState state;
  final Map<String, dynamic>? metadata;

  LivenessResult({
    required this.isSuccess,
    this.imagePath,
    this.errorMessage,
    required this.state,
    this.metadata,
  });
}

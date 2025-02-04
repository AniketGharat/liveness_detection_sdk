class LivenessResult {
  final bool isSuccess;
  final String? imagePath;
  final String? errorMessage;

  const LivenessResult({
    required this.isSuccess,
    this.imagePath,
    this.errorMessage,
  });
}

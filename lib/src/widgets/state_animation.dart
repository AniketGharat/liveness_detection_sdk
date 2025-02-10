import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../../liveness_sdk.dart';

class StateAnimation extends StatelessWidget {
  final String animationPath;
  final AnimationController controller;
  final LivenessState state;

  const StateAnimation({
    Key? key,
    required this.animationPath,
    required this.controller,
    required this.state,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.only(top: 60),
        width: 120, // Increased size for better visibility
        height: 120, // Increased size for better visibility
        child: Lottie.asset(
          animationPath,
          controller: controller,
          package: 'liveness_detection_sdk',
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';
import 'package:lottie/lottie.dart';

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
        width: 30,
        height: 30,
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

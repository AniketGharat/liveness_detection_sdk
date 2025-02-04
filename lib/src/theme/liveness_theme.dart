import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class LivenessTheme {
  final Color backgroundColor;
  final Color overlayColor;
  final Color ovalColor;
  final double ovalStrokeWidth;
  final TextStyle instructionTextStyle;
  final TextStyle errorTextStyle;
  final Color progressIndicatorColor;
  final EdgeInsets instructionPadding;

  const LivenessTheme({
    this.backgroundColor = Colors.black,
    this.overlayColor = Colors.black54,
    this.ovalColor = Colors.white,
    this.ovalStrokeWidth = 2.0,
    this.instructionTextStyle = const TextStyle(
      color: Colors.white,
      fontSize: 18,
      fontWeight: FontWeight.w500,
    ),
    this.errorTextStyle = const TextStyle(
      color: Colors.red,
      fontSize: 18,
      fontWeight: FontWeight.w500,
    ),
    this.progressIndicatorColor = Colors.blue,
    this.instructionPadding = const EdgeInsets.all(16),
  });
}

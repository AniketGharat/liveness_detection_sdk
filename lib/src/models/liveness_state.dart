enum LivenessState {
  initial,
  lookingLeft,
  lookingRight,
  lookingStraight,
  complete,
  multipleFaces,
  failed, // Changed from error to failed
}

# NOTE: the checked-in generated files (lib/pigeon.dart, Pigeon.kt, Pigeon.h/.m)
# were produced by pigeon v9.2.5 and have since been hand-edited
# (VideoOptions.segmentDurationMs, CupertinoVideoOptions.bitrate). Regenerating
# with pigeon >= 10 rewrites every file in a different style and requires
# updating CameraAwesomeX.kt / CamerawesomePlugin.m accordingly.
flutter pub run pigeon \
  --input pigeons/interface.dart \
  --dart_out lib/pigeon.dart \
  --experimental_kotlin_out ./android/src/main/kotlin/com/apparence/camerawesome/cameraX/Pigeon.kt \
  --experimental_kotlin_package "com.apparence.camerawesome.cameraX" \
  --objc_source_out ./ios/camerawesome/Sources/camerawesome/Pigeon/Pigeon.m \
  --objc_header_out ./ios/camerawesome/Sources/camerawesome/include/Pigeon.h

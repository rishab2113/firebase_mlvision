package io.flutter.plugins.firebasemlvision;

import com.google.firebase.ml.vision.common.FirebaseVisionImage;

import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import java.io.IOException;

interface Detector {
  void handleDetection(final FirebaseVisionImage image, final EventChannel.EventSink eventSink);

  void close() throws IOException;
}

interface Setup {
  void setup(String modelName, final MethodChannel.Result result);
}

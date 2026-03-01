import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'api_client.dart';

class MotionSignalSample {
  const MotionSignalSample({
    required this.peakMagnitude,
    required this.meanMagnitude,
    required this.stdDeviation,
    required this.distressScore,
    required this.probableFall,
    required this.collectedAt,
    required this.sampleCount,
  });

  final double peakMagnitude;
  final double meanMagnitude;
  final double stdDeviation;
  final double distressScore;
  final bool probableFall;
  final DateTime collectedAt;
  final int sampleCount;

  static MotionSignalSample empty() {
    return MotionSignalSample(
      peakMagnitude: 9.8,
      meanMagnitude: 9.8,
      stdDeviation: 0.0,
      distressScore: 0.0,
      probableFall: false,
      collectedAt: DateTime.now(),
      sampleCount: 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'peakMagnitude': peakMagnitude,
      'meanMagnitude': meanMagnitude,
      'stdDeviation': stdDeviation,
      'distressScore': distressScore,
      'probableFall': probableFall,
      'sampleCount': sampleCount,
      'collectedAt': collectedAt.toIso8601String(),
    };
  }
}

class VoiceSignalSample {
  const VoiceSignalSample({
    required this.keywordDetected,
    required this.screamScore,
    required this.distressScore,
    required this.detectedAt,
    this.keyword,
    this.source = 'unknown',
  });

  final bool keywordDetected;
  final double screamScore;
  final double distressScore;
  final DateTime detectedAt;
  final String? keyword;
  final String source;

  static VoiceSignalSample empty() {
    return VoiceSignalSample(
      keywordDetected: false,
      screamScore: 0,
      distressScore: 0,
      detectedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'keywordDetected': keywordDetected,
      'keyword': keyword,
      'screamScore': screamScore,
      'distressScore': distressScore,
      'source': source,
      'detectedAt': detectedAt.toIso8601String(),
    };
  }
}

class DistressValidationResult {
  const DistressValidationResult({
    required this.likelyHurtConfidence,
    required this.falseAlarmConfidence,
    required this.imageScore,
    required this.motionScore,
    required this.voiceScore,
    required this.threshold,
    required this.usedTflite,
    required this.modelVersion,
    required this.createdAt,
  });

  final double likelyHurtConfidence;
  final double falseAlarmConfidence;
  final double imageScore;
  final double motionScore;
  final double voiceScore;
  final double threshold;
  final bool usedTflite;
  final String modelVersion;
  final DateTime createdAt;

  bool get isLikelyHurt => likelyHurtConfidence >= threshold;

  Map<String, dynamic> toJson() {
    return {
      'likelyHurtConfidence': likelyHurtConfidence,
      'falseAlarmConfidence': falseAlarmConfidence,
      'imageScore': imageScore,
      'motionScore': motionScore,
      'voiceScore': voiceScore,
      'threshold': threshold,
      'usedTflite': usedTflite,
      'modelVersion': modelVersion,
      'isLikelyHurt': isLikelyHurt,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}

class SosEvidenceBundle {
  const SosEvidenceBundle({
    required this.frontPhotoPath,
    required this.backPhotoPath,
    required this.audioPath,
    required this.capturedAt,
  });

  final String? frontPhotoPath;
  final String? backPhotoPath;
  final String? audioPath;
  final DateTime capturedAt;

  Map<String, dynamic> toJson() {
    return {
      'frontPhotoPath': frontPhotoPath,
      'backPhotoPath': backPhotoPath,
      'audioPath': audioPath,
      'capturedAt': capturedAt.toIso8601String(),
    };
  }
}

class AiValidatorService {
  AiValidatorService._();
  static final AiValidatorService instance = AiValidatorService._();

  static const String _modelAssetPath =
      'lib/assets/models/distress_classifier.tflite';
  static const String modelVersion = 'distress-mobilenetv2-v1';
  static const double defaultThreshold = 0.70;

  Interpreter? _interpreter;
  bool _initialized = false;

  bool get isModelReady => _interpreter != null;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final modelData = await rootBundle.load(_modelAssetPath);
      final options = InterpreterOptions()..threads = 2;
      _interpreter = Interpreter.fromBuffer(
        modelData.buffer.asUint8List(),
        options: options,
      );
      debugPrint('[ai-validator] model loaded: $_modelAssetPath');
    } catch (e) {
      // Fallback to heuristic mode when model file is missing/invalid.
      _interpreter = null;
      debugPrint('[ai-validator] model unavailable, fallback mode: $e');
    }
  }

  Future<MotionSignalSample> collectMotionSample({
    Duration duration = const Duration(milliseconds: 1200),
  }) async {
    final values = <double>[];
    final completer = Completer<MotionSignalSample>();

    late final StreamSubscription<AccelerometerEvent> sub;
    sub = accelerometerEventStream().listen((event) {
      final magnitude = math.sqrt(
        (event.x * event.x) + (event.y * event.y) + (event.z * event.z),
      );
      values.add(magnitude);
    });

    Future<void>.delayed(duration).then((_) async {
      await sub.cancel();
      if (values.isEmpty) {
        completer.complete(MotionSignalSample.empty());
        return;
      }

      final sum = values.fold<double>(0, (acc, v) => acc + v);
      final mean = sum / values.length;
      final peak = values.reduce(math.max);
      final variance =
          values.fold<double>(0, (acc, v) => acc + math.pow(v - mean, 2)) /
          values.length;
      final stdDev = math.sqrt(variance);
      final probableFall = peak >= 22 || (mean <= 8.5 && peak >= 18);

      final peakNorm = ((peak - 10.0) / 15.0).clamp(0.0, 1.0);
      final jitterNorm = (stdDev / 7.0).clamp(0.0, 1.0);
      final score = (peakNorm * 0.68) + (jitterNorm * 0.32);
      final distressScore = (score + (probableFall ? 0.10 : 0)).clamp(0.0, 1.0);

      completer.complete(
        MotionSignalSample(
          peakMagnitude: peak,
          meanMagnitude: mean,
          stdDeviation: stdDev,
          distressScore: distressScore,
          probableFall: probableFall,
          collectedAt: DateTime.now(),
          sampleCount: values.length,
        ),
      );
    });

    return completer.future;
  }

  Future<String?> captureSnapshot({
    required CameraLensDirection lens,
    String prefix = 'sos',
  }) async {
    final camPermission = await Permission.camera.request();
    if (!camPermission.isGranted) return null;

    final cameras = await availableCameras();
    if (cameras.isEmpty) return null;

    final CameraDescription camera = cameras.firstWhere(
      (c) => c.lensDirection == lens,
      orElse: () => cameras.first,
    );

    CameraController? controller;
    try {
      controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      final xFile = await controller.takePicture();

      final outDir = await _ensureEvidenceDir();
      final lensName = lens == CameraLensDirection.front ? 'front' : 'back';
      final outPath = p.join(
        outDir.path,
        '${prefix}_${DateTime.now().millisecondsSinceEpoch}_$lensName.jpg',
      );

      return await File(xFile.path).copy(outPath).then((f) => f.path);
    } catch (e) {
      debugPrint('[ai-validator] captureSnapshot failed: $e');
      return null;
    } finally {
      await controller?.dispose();
    }
  }

  Future<String?> recordAudioClip({
    Duration duration = const Duration(seconds: 5),
  }) async {
    final micPermission = await Permission.microphone.request();
    if (!micPermission.isGranted) return null;

    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) return null;

      final outDir = await _ensureEvidenceDir();
      final outPath = p.join(
        outDir.path,
        'audio_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );

      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 16000,
        ),
        path: outPath,
      );

      await Future<void>.delayed(duration);
      final filePath = await recorder.stop();
      return filePath ?? outPath;
    } catch (e) {
      debugPrint('[ai-validator] recordAudioClip failed: $e');
      return null;
    } finally {
      await recorder.dispose();
    }
  }

  Future<SosEvidenceBundle> captureCountdownEvidence({
    Duration audioDuration = const Duration(seconds: 5),
  }) async {
    final audioFuture = recordAudioClip(duration: audioDuration);

    final front = await captureSnapshot(
      lens: CameraLensDirection.front,
      prefix: 'countdown',
    );
    final back = await captureSnapshot(
      lens: CameraLensDirection.back,
      prefix: 'countdown',
    );
    final audio = await audioFuture;

    return SosEvidenceBundle(
      frontPhotoPath: front,
      backPhotoPath: back,
      audioPath: audio,
      capturedAt: DateTime.now(),
    );
  }

  Future<DistressValidationResult> runQuickValidation({
    required String? frontPhotoPath,
    required MotionSignalSample motion,
    required VoiceSignalSample voice,
    double threshold = defaultThreshold,
  }) async {
    await initialize();

    final heuristicImageScore = frontPhotoPath == null ? 0.45 : 0.62;
    double imageScore = heuristicImageScore;
    bool usedTflite = false;

    if (frontPhotoPath != null && _interpreter != null) {
      final tfliteScore = await _inferImageDistress(frontPhotoPath);
      if (tfliteScore != null) {
        imageScore = tfliteScore;
        usedTflite = true;
      }
    }

    final motionScore = motion.distressScore;
    final voiceScore = voice.distressScore.clamp(0.0, 1.0);

    double combined =
        (imageScore * 0.62) + (motionScore * 0.24) + (voiceScore * 0.14);

    if (voice.keywordDetected) {
      combined = (combined + 0.07).clamp(0.0, 1.0);
    }

    if (motion.probableFall) {
      combined = (combined + 0.05).clamp(0.0, 1.0);
    }

    final likelyHurt = combined.clamp(0.0, 1.0);
    final falseAlarm = (1.0 - likelyHurt).clamp(0.0, 1.0);

    return DistressValidationResult(
      likelyHurtConfidence: likelyHurt,
      falseAlarmConfidence: falseAlarm,
      imageScore: imageScore,
      motionScore: motionScore,
      voiceScore: voiceScore,
      threshold: threshold,
      usedTflite: usedTflite,
      modelVersion: modelVersion,
      createdAt: DateTime.now(),
    );
  }

  Future<Map<String, dynamic>> sendValidationToOrchestrator({
    required ApiClient api,
    required DistressValidationResult result,
    required MotionSignalSample motion,
    required VoiceSignalSample voice,
    required SosEvidenceBundle evidence,
    required String reporterId,
    required String? familyContactsJson,
    String? localIncidentUuid,
  }) async {
    final uri = Uri.parse('${api.baseUrl}/orchestrator/validate');
    final request = http.MultipartRequest('POST', uri);

    final token = await api.tokenProvider();
    if (token == null || token.isEmpty) {
      throw ApiException(401, 'Missing auth token for orchestrator validation');
    }
    request.headers['Authorization'] = 'Bearer $token';

    request.fields['reporter_id'] = reporterId;
    request.fields['ai_validation'] = jsonEncode(result.toJson());
    request.fields['motion_signal'] = jsonEncode(motion.toJson());
    request.fields['voice_signal'] = jsonEncode(voice.toJson());
    request.fields['captured_at'] = evidence.capturedAt.toIso8601String();
    request.fields['family_contacts'] = familyContactsJson ?? '[]';

    if (localIncidentUuid != null && localIncidentUuid.isNotEmpty) {
      request.fields['local_incident_uuid'] = localIncidentUuid;
    }

    if (evidence.frontPhotoPath != null &&
        evidence.frontPhotoPath!.isNotEmpty) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'front_photo',
          evidence.frontPhotoPath!,
        ),
      );
    }

    if (evidence.backPhotoPath != null && evidence.backPhotoPath!.isNotEmpty) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'back_photo',
          evidence.backPhotoPath!,
        ),
      );
    }

    if (evidence.audioPath != null && evidence.audioPath!.isNotEmpty) {
      request.files.add(
        await http.MultipartFile.fromPath('audio_clip', evidence.audioPath!),
      );
    }

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        'Orchestrator validation failed',
        body: response.body,
      );
    }

    if (response.body.isEmpty) return <String, dynamic>{'ok': true};
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'ok': true, 'response': decoded};
  }

  Future<void> discardEvidence(SosEvidenceBundle bundle) async {
    final files = [
      bundle.frontPhotoPath,
      bundle.backPhotoPath,
      bundle.audioPath,
    ];
    for (final path in files) {
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  Future<double?> _inferImageDistress(String imagePath) async {
    final interpreter = _interpreter;
    if (interpreter == null) return null;

    try {
      final bytes = await File(imagePath).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return null;

      final inputTensor = interpreter.getInputTensor(0);
      final inputShape = inputTensor.shape;
      if (inputShape.length != 4 || inputShape[0] != 1 || inputShape[3] != 3) {
        return null;
      }

      final inputH = inputShape[1];
      final inputW = inputShape[2];
      final resized = img.copyResizeCropSquare(
        image,
        size: math.max(inputH, inputW),
      );
      final normalized = img.copyResize(resized, width: inputW, height: inputH);

      final input = [
        List.generate(inputH, (y) {
          return List.generate(inputW, (x) {
            final px = normalized.getPixel(x, y);
            return [
              (px.r / 255.0).toDouble(),
              (px.g / 255.0).toDouble(),
              (px.b / 255.0).toDouble(),
            ];
          });
        }),
      ];

      final outputTensor = interpreter.getOutputTensor(0);
      final outputShape = outputTensor.shape;

      dynamic output;
      if (outputShape.length == 2 &&
          outputShape[0] == 1 &&
          outputShape[1] == 2) {
        output = [
          [0.0, 0.0],
        ];
      } else {
        output = [
          [0.0],
        ];
      }

      interpreter.run(input, output);

      if (output is List && output.isNotEmpty && output.first is List) {
        final first = output.first as List;
        if (first.length >= 2) {
          final logits = first.map((e) => (e as num).toDouble()).toList();
          return _softmax(logits).last.clamp(0.0, 1.0);
        }
        if (first.isNotEmpty) {
          final raw = (first.first as num).toDouble();
          return _sigmoid(raw).clamp(0.0, 1.0);
        }
      }
      return null;
    } catch (e) {
      debugPrint('[ai-validator] TFLite inference failed: $e');
      return null;
    }
  }

  List<double> _softmax(List<double> values) {
    if (values.isEmpty) return const [];
    final maxVal = values.reduce(math.max);
    final exps = values.map((v) => math.exp(v - maxVal)).toList();
    final sum = exps.fold<double>(0, (acc, v) => acc + v);
    return exps.map((v) => v / sum).toList();
  }

  double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

  Future<Directory> _ensureEvidenceDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'sos_validation'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}

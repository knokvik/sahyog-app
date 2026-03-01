# TFLite Distress Model Training Tips (Low False Alarm Target)

## Objective
Binary classifier for:
- `Real Distress / Likely Hurt`
- `False Alarm`

Target:
- false alarm rate < 3%
- mobile model size < 12 MB

## Recommended Backbone
- MobileNetV2 (alpha 1.0) or EfficientNet-Lite0
- Input size: `224x224`
- Quantization: post-training int8 or float16

## Data Strategy
- Keep a strict split by person/session/device to avoid leakage.
- Include hard negatives:
  - selfies in normal posture
  - walking/running/sports
  - phone drops with no injury
  - crowd noise/shouting not distress
- Include realistic distress positives:
  - lying/fall postures
  - low light indoor/outdoor
  - partial face/blur/motion blur

## Multi-Modal Labeling
For each training sample, store:
- image label (`distress` / `false_alarm`)
- accelerometer-derived fall score
- voice cue label (`help`, scream, pain words)

Use model + rules fusion:
- image model output as primary score
- calibrated motion/voice priors as secondary features
- final confidence calibration via temperature scaling

## False Alarm Reduction
- Optimize threshold on validation to cap false alarms before maximizing recall.
- Use focal loss or class-weighted BCE to penalize false positives.
- Build a hard-negative mining loop every sprint.
- Calibrate threshold per build and keep telemetry by app version.

## On-Device Validation
- Track confusion matrix separately for:
  - manual SOS taps
  - voice auto triggers
  - fall auto triggers
- Reject deployment if false alarm rate exceeds 3% in field-like test set.

## Export Checklist
- Convert to TFLite with representative dataset for quantization.
- Validate top-1 confidence parity between training and TFLite runtime.
- Keep model filename versioned, example:
  - `distress_mobilenetv2_v3_1.tflite`

// lib/dsp_profile.dart
import 'models.dart';

enum FeedbackSuppressorMode { off, passive, armed, hot }

class DspProfile {
  final int fftWindow;
  final int aecTaps;
  final double aecStepSize;
  final FeedbackSuppressorMode feedbackMode;
  final bool polyphonicPitch;
  final int chromaSmoothingFrames;
  final int voiceCeiling;
  final double reverbRoom;
  final double reverbWet;
  final double reverbDamping;
  final double subBassTrimDb;
  final double analysisConfidenceMultiplier;
  final bool hardLimiter;
  final int cajonAttackSofteningMs;

  const DspProfile({
    required this.fftWindow,
    required this.aecTaps,
    required this.aecStepSize,
    required this.feedbackMode,
    required this.polyphonicPitch,
    required this.chromaSmoothingFrames,
    required this.voiceCeiling,
    required this.reverbRoom,
    required this.reverbWet,
    required this.reverbDamping,
    required this.subBassTrimDb,
    required this.analysisConfidenceMultiplier,
    required this.hardLimiter,
    required this.cajonAttackSofteningMs,
  });

  static const whisper = DspProfile(
    fftWindow: 4096,
    aecTaps: 512,
    aecStepSize: 0.10,
    feedbackMode: FeedbackSuppressorMode.off,
    polyphonicPitch: true,
    chromaSmoothingFrames: 8,
    voiceCeiling: 24,
    reverbRoom: 0.98,
    reverbWet: 0.75,
    reverbDamping: 0.20,
    subBassTrimDb: 0.0,
    analysisConfidenceMultiplier: 1.0,
    hardLimiter: false,
    cajonAttackSofteningMs: 2,
  );

  static const chamber = DspProfile(
    fftWindow: 2048,
    aecTaps: 1024,
    aecStepSize: 0.15,
    feedbackMode: FeedbackSuppressorMode.passive,
    polyphonicPitch: false,
    chromaSmoothingFrames: 4,
    voiceCeiling: 16,
    reverbRoom: 0.85,
    reverbWet: 0.45,
    reverbDamping: 0.30,
    subBassTrimDb: 0.0,
    analysisConfidenceMultiplier: 1.0,
    hardLimiter: false,
    cajonAttackSofteningMs: 3,
  );

  static const hall = DspProfile(
    fftWindow: 2048,
    aecTaps: 2048,
    aecStepSize: 0.20,
    feedbackMode: FeedbackSuppressorMode.armed,
    polyphonicPitch: false,
    chromaSmoothingFrames: 4,
    voiceCeiling: 12,
    reverbRoom: 0.70,
    reverbWet: 0.30,
    reverbDamping: 0.50,
    subBassTrimDb: -3.0,
    analysisConfidenceMultiplier: 0.85,
    hardLimiter: false,
    cajonAttackSofteningMs: 5,
  );

  static const amplified = DspProfile(
    fftWindow: 2048,
    aecTaps: 4096,
    aecStepSize: 0.30,
    feedbackMode: FeedbackSuppressorMode.hot,
    polyphonicPitch: false,
    chromaSmoothingFrames: 2,
    voiceCeiling: 8,
    reverbRoom: 0.50,
    reverbWet: 0.18,
    reverbDamping: 0.70,
    subBassTrimDb: -9.0,
    analysisConfidenceMultiplier: 0.65,
    hardLimiter: true,
    cajonAttackSofteningMs: 6,
  );

  // Direct mode: always Whisper-quality regardless of master volume
  static const direct = DspProfile(
    fftWindow: 4096,
    aecTaps: 0,             // AEC disabled
    aecStepSize: 0.0,
    feedbackMode: FeedbackSuppressorMode.off,
    polyphonicPitch: true,
    chromaSmoothingFrames: 8,
    voiceCeiling: 24,
    reverbRoom: 0.85,       // user's reverb slider governs, not tier
    reverbWet: 0.45,
    reverbDamping: 0.30,
    subBassTrimDb: 0.0,
    analysisConfidenceMultiplier: 1.0,
    hardLimiter: false,
    cajonAttackSofteningMs: 2,
  );

  /// Select profile by coupling mode and smoothed master volume.
  /// Master is LINEAR (0..1), not dB.
  static DspProfile forMode(CouplingMode mode, double masterSmoothed) {
    if (mode == CouplingMode.direct) return direct;
    if (masterSmoothed <= 0.10) return whisper;
    if (masterSmoothed <= 0.30) return chamber;
    if (masterSmoothed <= 0.60) return hall;
    return amplified;
  }
}

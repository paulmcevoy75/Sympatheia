import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sympatheia/aec.dart';

void main() {
  // Reference: a chord-ish signal with noise so correlation has a peak.
  Float64List makeRef(int n) {
    final r = Random(1);
    final out = Float64List(n);
    for (int i = 0; i < n; i++) {
      out[i] = 0.2 * sin(2 * pi * 220 * i / 44100) +
          0.15 * sin(2 * pi * 330 * i / 44100) +
          0.1 * (r.nextDouble() * 2 - 1);
    }
    return out;
  }

  test('finds the echo delay and cancels most of the echo', () {
    const delay = 3000; // ~68 ms
    const n = 2048;
    const total = 44100 * 4;
    final ref = makeRef(total);
    // Echo = 0.5 * ref delayed + a weaker reflection 40 samples later.
    final mic = Float64List(total);
    for (int i = 0; i < total; i++) {
      final a = i - delay, b = i - delay - 40;
      mic[i] = (a >= 0 ? 0.5 * ref[a] : 0) + (b >= 0 ? 0.2 * ref[b] : 0);
    }

    final aec = EchoCanceller(taps: 256, stepSize: 0.3);
    const window = 32768, maxLag = 22050;
    final found = aec.estimateDelay(
      Float64List.sublistView(mic, total - window, total),
      Float64List.sublistView(ref, total - window - maxLag, total),
      maxLag,
    );
    expect(found, isTrue);
    expect((aec.delaySamples! - delay).abs(), lessThanOrEqualTo(16));

    // Run the canceller block by block.
    double inE = 0, outE = 0;
    for (int start = 44100; start + n <= total; start += n) {
      final from = start - aec.delaySamples! + aec.preTaps - (aec.taps - 1);
      final r = Float64List.sublistView(ref, from, from + n + aec.taps - 1);
      final m = Float64List.sublistView(mic, start, start + n);
      final out = aec.process(Float64List.fromList(m), Float64List.fromList(r));
      if (start > total - 44100) {
        for (int i = 0; i < n; i++) {
          inE += m[i] * m[i];
          outE += out[i] * out[i];
        }
      }
    }
    final erle = 10 * log(inE / outE) / ln10;
    // ignore: avoid_print
    print('AEC ERLE: ${erle.toStringAsFixed(1)} dB');
    expect(erle, greaterThan(15));
  });

  test('passes the player through when nothing is playing', () {
    final aec = EchoCanceller(taps: 128);
    final mic = Float64List.fromList(List.generate(512, (i) => sin(i * 0.1)));
    final out = aec.process(mic, Float64List(512 + 127));
    expect(out, mic);
  });
}

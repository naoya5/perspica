// The sound of the Perspica movie: music and effects, synthesized here.
//
// Nothing is sampled or downloaded. Every sound is built from sine waves and
// seeded noise, so the file is the same on every run and carries no one
// else's rights. The times come from `CUES` in movie.html: the picture and the
// sound read one timeline.
//
//   import { writeScore } from './score.mjs';
//   writeScore('score.wav', { cues, duration, beat });

import { writeFileSync } from 'node:fs';

const RATE = 48000;
const TAU = Math.PI * 2;

const hz = (midi) => 440 * 2 ** ((midi - 69) / 12);
const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));

/** A small seeded generator, so the noise is the same every time. */
const seeded = (seed) => () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};

export function renderScore({ cues, duration, beat }) {
  const length = Math.ceil(duration * RATE);
  const dry = [new Float32Array(length), new Float32Array(length)];
  const wet = [new Float32Array(length), new Float32Array(length)];
  const random = seeded(20261110);

  /**
   * Adds one voice. `sample(s, i)` gives the value `s` seconds after `at`;
   * `pan` is -1 (left) to 1 (right); `send` is how much goes to the reverb.
   */
  const voice = (at, seconds, gain, pan, send, sample) => {
    const from = Math.max(0, Math.round(at * RATE));
    const count = Math.min(length - from, Math.round(seconds * RATE));
    const left = Math.cos(((pan + 1) * Math.PI) / 4), right = Math.sin(((pan + 1) * Math.PI) / 4);
    for (let i = 0; i < count; i += 1) {
      const value = sample(i / RATE, i) * gain;
      dry[0][from + i] += value * left;
      dry[1][from + i] += value * right;
      wet[0][from + i] += value * left * send;
      wet[1][from + i] += value * right * send;
    }
  };

  /** Rises in `attack`, holds, falls in `release`. No voice starts or ends with a step. */
  const shape = (s, seconds, attack, release) => clamp(s / attack) * clamp((seconds - s) / release);
  const decay = (s, half) => 2 ** (-s / half);

  /** Noise through a band-pass filter whose centre moves: `centre(s)` in Hz. */
  const wind = (at, seconds, gain, pan, send, centre, envelope, q = 0.6) => {
    let low = 0, band = 0;
    voice(at, seconds, gain, typeof pan === 'function' ? 0 : pan, send, (s) => {
      const f = 2 * Math.sin((Math.PI * Math.min(centre(s), RATE / 6)) / RATE);
      low += f * band;
      const high = random() * 2 - 1 - low - q * band;
      band += f * high;
      return band * envelope(s);
    });
  };

  // ---------- instruments ----------

  const pad = (at, seconds, midi, gain) => {
    const f = hz(midi), drift = 0.3 + random() * 0.4, phase = random() * TAU;
    voice(at, seconds, gain, random() * 1.2 - 0.6, 0.5, (s) => {
      const breathe = 0.85 + 0.15 * Math.sin(TAU * drift * 0.2 * s + phase);
      return (Math.sin(TAU * f * s) + Math.sin(TAU * f * 1.004 * s + 1) + 0.18 * Math.sin(TAU * f * 2 * s))
        * shape(s, seconds, 1.4, 2.2) * breathe;
    });
  };

  const pluck = (at, midi, gain, pan) => {
    const f = hz(midi);
    voice(at, 1.1, gain, pan, 0.45, (s) =>
      (Math.sin(TAU * f * s) + 0.3 * Math.sin(TAU * 2 * f * s) * decay(s, 0.08) + 0.1 * Math.sin(TAU * 3 * f * s) * decay(s, 0.04))
      * clamp(s / 0.004) * decay(s, 0.16) * clamp((1.1 - s) / 0.1));
  };

  const bass = (at, midi, gain) => {
    const f = hz(midi);
    voice(at, 2.3, gain, 0, 0.1, (s) =>
      (Math.sin(TAU * f * s) + 0.45 * Math.sin(TAU * 2 * f * s)) * shape(s, 2.3, 0.03, 0.5) * decay(s, 0.9));
  };

  const chime = (at, midi, gain = 0.2) => {
    const f = hz(midi);
    const partials = [[1, 1, 0.9], [2.0, 0.5, 0.5], [3.01, 0.22, 0.3], [4.2, 0.12, 0.18]];
    voice(at, 3.2, gain, 0.15, 0.9, (s) => {
      let sum = 0;
      for (const [ratio, level, half] of partials) sum += level * Math.sin(TAU * f * ratio * s) * decay(s, half);
      return sum * clamp(s / 0.003) * clamp((3.2 - s) / 0.3);
    });
  };

  const tick = (at, gain = 0.1, pan = -0.3) => {
    voice(at, 0.05, gain, pan, 0.2, (s) =>
      (Math.sin(TAU * 2100 * s) * decay(s, 0.006) + (random() * 2 - 1) * decay(s, 0.002) * 0.6) * clamp(s / 0.0008) * clamp((0.05 - s) / 0.01));
  };

  // ---------- music ----------

  // Chords change with the scenes: D, B minor, G, A, and home to D for the end.
  const chords = [
    { from: 0, to: 16, tones: [50, 57, 62, 64, 66], root: 50 },
    { from: 16, to: 32, tones: [47, 54, 59, 62, 66], root: 47 },
    { from: 32, to: 48, tones: [55, 59, 62, 66, 69], root: 55 },
    { from: 48, to: 56, tones: [57, 61, 64, 69, 71], root: 57 },
    { from: 56, to: 64, tones: [50, 57, 62, 66, 69], root: 50 },
  ];
  const chordAt = (b) => chords.find((chord) => b >= chord.from && b < chord.to) || chords[chords.length - 1];

  for (const chord of chords) {
    for (const tone of chord.tones) pad(chord.from * beat - 0.6, (chord.to - chord.from) * beat + 1.8, tone, 0.028);
  }
  // The bass and the plucked line come in with the title and leave before the end card.
  for (let b = 10; b < 62; b += 4) bass(b * beat, chordAt(b).root + (chordAt(b).root < 50 ? 12 : 0), 0.11);
  const line = [0, 2, 4, 2, 1, 3, 4, 3];
  for (let step = 0; step < 128; step += 1) {
    const b = step / 2;
    if (b < 10 || b >= 58) continue;
    if (b < 16 && step % 4 !== 0) continue; // sparse under the title
    const tone = chordAt(b).tones[line[step % line.length]] + 24;
    pluck(b * beat, tone, step % 4 === 0 ? 0.075 : 0.05, step % 2 ? 0.4 : -0.4);
  }
  // A last, slow figure under the end card.
  [[58, 74], [59, 78], [60, 81], [61, 86]].forEach(([b, tone]) => pluck(b * beat, tone, 0.07, 0));

  // ---------- effects, one for each cue ----------

  for (const { time, kind, length: seconds = 1, note, index } of cues) {
    if (kind === 'land') {
      voice(time, 0.3, 0.3, 0, 0.3, (s) => Math.sin(TAU * (190 - 260 * s) * s) * clamp(s / 0.004) * decay(s, 0.06) * clamp((0.3 - s) / 0.05));
      wind(time - 0.25, 0.5, 0.25, 0, 0.5, (s) => 500 + 2600 * s, (s) => shape(s, 0.5, 0.22, 0.25));
    } else if (kind === 'sweep') {
      // The glasses crossing the page: air that moves from left to right.
      for (const side of [-1, 1]) {
        wind(time, seconds, 0.06, side, 0.5,
          (s) => 700 + 1900 * Math.sin((Math.PI * s) / seconds) + side * 120,
          (s) => shape(s, seconds, 0.9, 1.1) * (side < 0 ? 1 - s / seconds : s / seconds));
      }
    } else if (kind === 'chime') {
      chime(time, note);
      chime(time + 0.09, note + 7, 0.09);
    } else if (kind === 'tick') {
      tick(time);
    } else if (kind === 'press') {
      voice(time, 0.14, 0.34, -0.3, 0.25, (s) => Math.sin(TAU * (330 - 900 * s) * s) * clamp(s / 0.002) * decay(s, 0.03) * clamp((0.14 - s) / 0.03));
      tick(time, 0.16);
    } else if (kind === 'drag') {
      for (let i = 0; i < 9; i += 1) tick(time + (seconds * i) / 9, 0.035, 0.3);
    } else if (kind === 'pop') {
      voice(time, 0.4, 0.2, 0.3, 0.6, (s) => {
        const f = 420 + 460 * clamp(s / 0.09);
        return (Math.sin(TAU * f * s) + 0.3 * Math.sin(TAU * 2 * f * s)) * clamp(s / 0.004) * decay(s, 0.07) * clamp((0.4 - s) / 0.05);
      });
    } else if (kind === 'shimmer') {
      // The processing light: high, soft, slightly unsteady.
      [86, 90, 93, 98, 102].forEach((tone, i) => {
        const f = hz(tone), rate = 3 + random() * 4, phase = random() * TAU;
        voice(time, seconds, 0.011, (i - 2) * 0.35, 0.9, (s) =>
          Math.sin(TAU * f * s) * shape(s, seconds, 0.3, 0.5) * (0.6 + 0.4 * Math.sin(TAU * rate * s + phase)));
      });
    } else if (kind === 'block') {
      pluck(time, [74, 78, 81, 86][index % 4], 0.13, -0.5 + index * 0.33);
    } else if (kind === 'slide') {
      wind(time - 0.05, 0.4, 0.22, 0.2, 0.4, (s) => 1300 - 2200 * s, (s) => shape(s, 0.4, 0.08, 0.3));
    } else if (kind === 'hush') {
      wind(time - 0.7, 1.4, 0.13, 0, 0.7, (s) => 400 + 1500 * clamp(s / 0.7) - 900 * clamp((s - 0.7) / 0.7), (s) => shape(s, 1.4, 0.7, 0.7));
      voice(time, 0.5, 0.26, 0, 0.5, (s) => Math.sin(TAU * (170 - 110 * s) * s) * clamp(s / 0.005) * decay(s, 0.1) * clamp((0.5 - s) / 0.1));
    }
  }

  // ---------- the room ----------

  // A small reverb: four comb filters into two all-pass filters, on each side.
  const reverb = (input, offset) => {
    const out = new Float32Array(length);
    for (const [delay, feedback] of [[1687, 0.83], [1759, 0.82], [1621, 0.84], [1549, 0.81]]) {
      const line = new Float32Array(delay + offset);
      let at = 0, damp = 0;
      for (let i = 0; i < length; i += 1) {
        const echo = line[at];
        damp = echo * 0.7 + damp * 0.3;
        line[at] = input[i] + damp * feedback;
        at = (at + 1) % line.length;
        out[i] += echo * 0.25;
      }
    }
    for (const delay of [241, 601]) {
      const line = new Float32Array(delay + offset);
      let at = 0;
      for (let i = 0; i < length; i += 1) {
        const echo = line[at], value = out[i];
        line[at] = value + echo * 0.5;
        out[i] = echo - value * 0.5;
        at = (at + 1) % line.length;
      }
    }
    return out;
  };

  const mix = [0, 1].map((side) => {
    const room = reverb(wet[side], side * 23);
    const out = new Float32Array(length);
    // Take out what a laptop speaker cannot play, and fade the two ends.
    let previousIn = 0, previousOut = 0;
    const keep = 1 / (1 + (TAU * 95) / RATE);
    for (let i = 0; i < length; i += 1) {
      const value = dry[side][i] + room[i] * 0.3;
      previousOut = keep * (previousOut + value - previousIn);
      previousIn = value;
      const s = i / RATE;
      out[i] = previousOut * clamp(s / 0.05) * clamp((duration - s) / 1.1);
    }
    return out;
  });

  let peak = 0;
  for (const side of mix) for (const value of side) peak = Math.max(peak, Math.abs(value));
  const gain = peak > 0 ? 0.7 / peak : 1;
  for (const side of mix) for (let i = 0; i < length; i += 1) side[i] *= gain;
  return mix;
}

/** Writes the score as a 16-bit stereo WAV file. */
export function writeScore(path, timeline) {
  const [left, right] = renderScore(timeline);
  const bytes = Buffer.alloc(44 + left.length * 4);
  bytes.write('RIFF', 0);
  bytes.writeUInt32LE(36 + left.length * 4, 4);
  bytes.write('WAVEfmt ', 8);
  bytes.writeUInt32LE(16, 16);
  bytes.writeUInt16LE(1, 20);
  bytes.writeUInt16LE(2, 22);
  bytes.writeUInt32LE(RATE, 24);
  bytes.writeUInt32LE(RATE * 4, 28);
  bytes.writeUInt16LE(4, 32);
  bytes.writeUInt16LE(16, 34);
  bytes.write('data', 36);
  bytes.writeUInt32LE(left.length * 4, 40);
  for (let i = 0; i < left.length; i += 1) {
    bytes.writeInt16LE(Math.round(clamp(left[i], -1, 1) * 32767), 44 + i * 4);
    bytes.writeInt16LE(Math.round(clamp(right[i], -1, 1) * 32767), 46 + i * 4);
  }
  writeFileSync(path, bytes);
}

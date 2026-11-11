// Generates public/music.wav: an original, procedurally synthesised bed for the promo.
// Run: node make-music.mjs
import fs from 'node:fs';
const SR = 44100, DUR = 89.8, N = Math.floor(SR * DUR);
const L = new Float32Array(N), R = new Float32Array(N);
// Scene cuts. Every one is on the beat grid: 120 BPM, bars counted from the first cut.
const CUTS = [5, 13, 22, 35, 45, 59, 74, 83];
const BEAT = 0.5, BAR = BEAT * 4, ORIGIN = CUTS[0] % (BAR * 2);
for (const c of CUTS) if (Math.abs((c - ORIGIN) / BEAT - Math.round((c - ORIGIN) / BEAT)) > 1e-6) throw new Error(`cut ${c} is off the beat`);
const hz = (m) => 440 * 2 ** ((m - 69) / 12);
// A minor: Am9, Fmaj7, Cmaj7, G6 — one chord per two bars.
const CHORDS = [[45, 57, 60, 64, 71], [41, 57, 60, 64, 65], [48, 55, 59, 64, 67], [43, 55, 59, 62, 64]];
const chordAt = (t) => CHORDS[Math.floor((t - ORIGIN + BAR * 8 + 1e-6) / (BAR * 2)) % CHORDS.length];
let seed = 7; const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32) * 2 - 1;
const add = (i, l, r) => { if (i >= 0 && i < N) { L[i] += l; R[i] += r; } };
const env = (t, a, b, f) => Math.max(0, Math.min(1, t / a, (b - t) / f)); // fade in over a, out over f before b

// Pad: detuned saws through a slow one-pole low-pass that opens over the piece.
{
  let lpL = 0, lpR = 0;
  for (let i = 0; i < N; i++) {
    const t = i / SR, ch = chordAt(t), tc = (t - ORIGIN + BAR * 8) % (BAR * 2);
    const sw = Math.min(1, tc / 0.5) * Math.min(1, (BAR * 2 - tc) / 0.5);
    let l = 0, r = 0;
    for (let k = 1; k < ch.length; k++) {
      const f = hz(ch[k]);
      for (const [d, pan] of [[-0.004, -0.6], [0.004, 0.6], [0, 0]]) {
        const ph = (t * f * (1 + d)) % 1, s = (2 * ph - 1) * 0.5;
        l += s * (1 - pan) * 0.5; r += s * (1 + pan) * 0.5;
      }
    }
    const cutoff = 0.012 + 0.03 * Math.min(1, t / 40) + 0.008 * Math.sin(t * 0.4);
    lpL += cutoff * (l - lpL); lpR += cutoff * (r - lpR);
    const g = 0.16 * sw * env(t, 2.5, DUR, 4);
    L[i] += lpL * g; R[i] += lpR * g;
  }
}
// Rhythm section between the intro and the outro.
const RH0 = CUTS[0], RH1 = CUTS[CUTS.length - 1];
for (let b = 0; RH0 + b * BEAT < RH1; b++) {
  const t0 = RH0 + b * BEAT, i0 = Math.floor(t0 * SR);
  const quiet = t0 < CUTS[1] ? 0.75 : 1;
  // Kick
  for (let j = 0; j < SR * 0.32; j++) {
    const t = j / SR, f = 42 + 90 * Math.exp(-t * 28);
    const s = Math.sin(2 * Math.PI * (42 * t + (90 / 28) * (1 - Math.exp(-t * 28)))) * Math.exp(-t * 11) * 0.5 * quiet;
    add(i0 + j, s, s); void f;
  }
  // Off-beat hat
  let hp = 0, last = 0;
  for (let j = 0; j < SR * 0.05; j++) {
    const n = rnd(); hp = 0.85 * (hp + n - last); last = n;
    const s = hp * Math.exp(-j / (SR * 0.012)) * 0.05 * quiet;
    add(i0 + Math.floor(BEAT / 2 * SR) + j, s * 0.8, s * 1.1);
  }
  // Sub bass on the chord root, ducked by the kick
  const root = hz(chordAt(t0)[0]);
  for (let j = 0; j < SR * BEAT; j++) {
    const t = j / SR, duck = Math.min(1, t / 0.18);
    const s = Math.sin(2 * Math.PI * root * (t0 + t)) * 0.2 * duck * quiet * Math.min(1, (BEAT - t) / 0.03);
    add(i0 + j, s, s);
  }
}
// Plucked arpeggio in eighths from the agent scene, with a dotted-eighth echo.
{
  const P = new Float32Array(N);
  for (let e = 0; CUTS[1] + e * BEAT / 2 < CUTS[CUTS.length - 1]; e++) {
    const t0 = CUTS[1] + e * BEAT / 2, ch = chordAt(t0);
    const note = ch[1 + [0, 2, 3, 1, 2, 3, 0, 3][e % 8]] + 12;
    const f = hz(note), i0 = Math.floor(t0 * SR), amp = (e % 2 ? 0.05 : 0.075) * Math.min(1, (t0 - CUTS[1]) / 4 + 0.3);
    for (let j = 0; j < SR * 0.4; j++) {
      const t = j / SR, ph = (t * f) % 1;
      const tri = 4 * Math.abs(ph - 0.5) - 1;
      if (i0 + j < N) P[i0 + j] += (tri * 0.7 + Math.sin(2 * Math.PI * f * 2 * t) * 0.3) * Math.exp(-t * 9) * amp * Math.min(1, t / 0.004);
    }
  }
  const dl = Math.floor(BEAT * 0.75 * SR);
  for (let i = 0; i < N; i++) {
    const e1 = i >= dl ? P[i - dl] * 0.45 : 0, e2 = i >= 2 * dl ? P[i - 2 * dl] * 0.2 : 0;
    L[i] += P[i] * 0.9 + e1 * 0.3 + e2; R[i] += P[i] * 0.9 + e1 + e2 * 0.3;
  }
}
// Risers into each cut and a soft low impact on it.
for (const c of CUTS) {
  const len = 0.9; let lp = 0;
  for (let j = 0; j < SR * len; j++) {
    const p = j / (SR * len), n = rnd();
    lp += (0.02 + 0.35 * p * p) * (n - lp);
    const s = lp * p * p * 0.16;
    add(Math.floor((c - len) * SR) + j, s * (1 - p * 0.3), s * (0.7 + p * 0.3));
  }
  for (let j = 0; j < SR * 1.2; j++) {
    const t = j / SR;
    const s = Math.sin(2 * Math.PI * (38 * t + 3 * (1 - Math.exp(-t * 18)))) * Math.exp(-t * 4) * 0.34 + rnd() * Math.exp(-t * 40) * 0.05;
    add(Math.floor(c * SR) + j, s, s);
  }
}
// What's New: a bright hit as each of the four features lands (one every two beats), a bigger one for the grid.
for (let k = 0; k <= 4; k++) {
  const t0 = CUTS[0] + 1 + k, big = k === 4 ? 1.6 : 1;
  for (let j = 0; j < SR * 0.5; j++) {
    const t = j / SR;
    const s = (Math.sin(2 * Math.PI * hz(81 + (k % 2 ? 3 : 0)) * t) * 0.5 + Math.sin(2 * Math.PI * hz(69) * t) * 0.5) * Math.exp(-t * 10) * 0.11 * big + rnd() * Math.exp(-t * 60) * 0.06 * big;
    add(Math.floor(t0 * SR) + j, s, s);
  }
}
// The tick when the tap race starts (scene time 2.0 s).
for (let j = 0; j < SR * 0.06; j++) { const s = Math.sin(2 * Math.PI * 1800 * j / SR) * Math.exp(-j / (SR * 0.01)) * 0.12; add(Math.floor((CUTS[1] + 2.0) * SR) + j, s, s); }
// Master: fades, soft clip, normalise.
let peak = 0;
for (let i = 0; i < N; i++) {
  const t = i / SR, g = Math.min(1, t / 0.4) * Math.min(1, (DUR - t) / 2.5);
  L[i] = Math.tanh(L[i] * g * 1.5); R[i] = Math.tanh(R[i] * g * 1.5);
  peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
}
const k = 0.8 / peak, buf = Buffer.alloc(44 + N * 4);
buf.write('RIFF', 0); buf.writeUInt32LE(36 + N * 4, 4); buf.write('WAVEfmt ', 8); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22);
buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) { buf.writeInt16LE(Math.round(L[i] * k * 32767), 44 + i * 4); buf.writeInt16LE(Math.round(R[i] * k * 32767), 46 + i * 4); }
fs.writeFileSync('public/music.wav', buf);
console.log('wrote public/music.wav', (buf.length / 1e6).toFixed(1), 'MB, peak', peak.toFixed(2));

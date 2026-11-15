// Renders movie.html to an MP4 with sound, one frame at a time.
//
//   npm install
//   node render.mjs                 # ../../site/assets/perspica.mp4 and poster.jpg
//   node render.mjs --fps 12        # a quick draft
//   node render.mjs --frames 3,12.5 # only these moments, as PNGs in ./frames/
//   node render.mjs --score         # only the sound, as ./frames/score.wav
//
// The page exposes `seek(t)`, and every picture is a pure function of `t`, so
// the frames are identical on every run. The page also lists its sounds in
// `CUES`; score.mjs synthesizes them. Needs Google Chrome and ffmpeg.

import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright-core';
import { writeScore } from './score.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const assets = join(here, '..', '..', 'site', 'assets');
const POSTER_AT = 8.6;

const option = (name) => {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1] ?? '';
};
const fps = Number(option('--fps')) || 60;

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
await page.goto(`${pathToFileURL(join(here, 'movie.html'))}?render`);
await page.evaluate(async () => {
  await Promise.all([...document.images].map((image) => image.decode()));
  await document.fonts.ready;
});
const timeline = await page.evaluate(() => ({ cues: window.CUES, duration: window.DURATION, beat: window.BEAT }));

const frameAt = async (seconds, type = 'png') => {
  await page.evaluate((t) => window.seek(t), seconds);
  return page.screenshot(type === 'png' ? { type } : { type, quality: 92 });
};

const frames = join(here, 'frames');
if (option('--score') !== null) {
  mkdirSync(frames, { recursive: true });
  writeScore(join(frames, 'score.wav'), timeline);
  console.log(join(frames, 'score.wav'));
  console.log(JSON.stringify(timeline.cues.map((cue) => [Number(cue.time.toFixed(2)), cue.kind])));
  await browser.close();
  process.exit(0);
}

const stills = option('--frames');
if (stills) {
  mkdirSync(frames, { recursive: true });
  for (const seconds of stills.split(',').map(Number)) {
    const file = join(frames, `t${seconds.toFixed(2)}.png`);
    writeFileSync(file, await frameAt(seconds));
    console.log(file);
  }
  await browser.close();
  process.exit(0);
}

const work = mkdtempSync(join(tmpdir(), 'perspica-movie-'));
const score = join(work, 'score.wav');
writeScore(score, timeline);

mkdirSync(assets, { recursive: true });
const movie = join(assets, 'perspica.mp4');
// H.264 in yuv420p and AAC, with the index at the front, so Safari and
// QuickTime play it and a browser can start before the whole file has arrived.
// The sound is brought to -16 LUFS, the usual level for the web.
const ffmpeg = spawn('ffmpeg', [
  '-y', '-loglevel', 'error',
  '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
  '-i', score,
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p',
  '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000',
  '-t', String(timeline.duration), '-movflags', '+faststart', movie,
], { stdio: ['pipe', 'inherit', 'inherit'] });
const encoded = new Promise((resolve, reject) => {
  ffmpeg.on('error', reject);
  ffmpeg.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited with ${code}`))));
});

const total = Math.round(timeline.duration * fps);
for (let frame = 0; frame < total; frame += 1) {
  const png = await frameAt(frame / fps);
  if (!ffmpeg.stdin.write(png)) await new Promise((resolve) => ffmpeg.stdin.once('drain', resolve));
  if (frame % (fps * 2) === 0) process.stdout.write(`\r${Math.round((frame / total) * 100)}%`);
}
ffmpeg.stdin.end();
await encoded;
process.stdout.write('\r100%\n');

writeFileSync(join(assets, 'poster.jpg'), await frameAt(POSTER_AT, 'jpeg'));
await browser.close();
rmSync(work, { recursive: true, force: true });

const probe = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'stream=codec_name,duration', '-of', 'csv=p=0', movie], { encoding: 'utf8' });
console.log(movie);
console.log(probe.stdout.trim());

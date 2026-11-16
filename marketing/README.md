# Marketing

The landing page lives in `site/`. This folder holds the source of the movie the page embeds.

| Path | What |
|---|---|
| `site/index.html`, `style.css`, `site.js` | The landing page. Static files, system fonts, no requests to other sites. |
| `site/assets/shots/` | The footage both the page and the movie use (see below). |
| `site/assets/perspica.mp4`, `poster.jpg` | The rendered movie and its poster. Written by `render.mjs`. |
| `marketing/movie/movie.html` | The movie. Every frame is a pure function of `seek(t)`. |
| `marketing/movie/polly/` | Polly, the mascot, in the five poses the movie uses, cut to one shared square so a pose change does not move it. |
| `site/assets/polly/` | Polly on the page: the idle pose and its blink (one crop), and the wave. |
| `marketing/movie/render.mjs` | Steps through `movie.html` in headless Chrome and encodes the frames and the sound with ffmpeg. |
| `marketing/movie/score.mjs` | Synthesizes the music and the effects. |
| `marketing/sources/` | The pages the footage was made from. |
| `marketing/fonts/subset.sh` | Makes the heading fonts in `site/assets/fonts/`. |

## Preview the page

Open `site/index.html` in a browser. It needs no server and no build.

## Render the movie

Needs Node, Google Chrome and `ffmpeg`.

```sh
cd marketing/movie
npm install
node render.mjs                    # site/assets/perspica.mp4 (1920x1080, 60 fps, H.264 + AAC) and poster.jpg
node render.mjs --fps 12           # a quick draft
node render.mjs --frames 6.3,20.5  # only these moments, as PNGs in ./frames/
node render.mjs --score            # only the sound, as ./frames/score.wav
```

Open `movie.html` in a browser to preview the picture in real time. Space pauses, the arrow keys step.

### Sound

`score.mjs` synthesizes the music and every effect from sine waves and seeded noise. Nothing is
sampled or downloaded, so the sound is the same on every run and carries no one else's rights.

The picture and the sound read one timeline. In `movie.html`, each motion that should be heard calls
`cue(time, kind)` where its time is defined, and `render.mjs` hands that list to `score.mjs`. To move
a sound, move the motion. The film runs on a beat of 0.625 s, and scenes start on beats, so the
chords change with the scenes.

`render.mjs` brings the mix to -16 LUFS with a true peak under -1.5 dB. After a change to the score,
check it with `ffmpeg -i site/assets/perspica.mp4 -af ebur128=peak=true -f null -`, and listen to it.

## Fonts

Headings are set in Shippori Mincho (SIL Open Font License 1.1, `site/assets/fonts/OFL.txt`); the text
uses the system font. The font files are in the site, so the page still loads nothing from other
sites. Each file holds only the characters that the page and the movie use (about 80 KB instead of
8 MB). After you change their text, run `marketing/fonts/subset.sh` again, or new characters fall back
to the system Mincho.

## Footage

Everything shown was produced by the real app from text written for this purpose. No history, no real
documents and no third-party text appear in it. The captures were taken with the `verify-yaku` skill,
each in a fresh `--data-dir`, so the time the panel shows is a first translation (engine start
included), not a cache hit.

| File | How it was made |
|---|---|
| `page-en.png` | A page set in English, written and drawn for the demo: `marketing/sources/page.html`, rendered at 1.6 pixels per point. |
| `page-ja.png` | `--demo-image <that page> --demo-scale 1`, captured with `yaku-verify shot`: the app read the page and laid its translation over it. |
| `pdf-before.png`, `pdf-after.png` | Page 1 of a paper written for the demo (`marketing/sources/paper.html`, printed to PDF), and page 1 of the PDF the app wrote for it (`--demo-pdf`), both rendered with `pdftoppm -r 200`. |
| `panel-light.png`, `panel-dark.png` | `--demo-surface panel --demo-state done --demo-pin --demo-backdrop light|dark`, captured as a screen region so the backdrop is behind the glass. |
| `panel-glass.png`, `hud-glass.png` | The same kind of capture (`--demo-surface panel` / `hud`), cut at the edge of the glass. The page and the movie draw only the shadow under them. |

Both page pictures have their top row cut off. A small line of text was there on purpose: the overlay
draws a focus ring on its first block when it opens, and that row takes it.

The page was drawn at 1.6 pixels per point and passed with `--demo-scale 1`, because the demo window
opens on the main display, which was not the Retina one. Its headline is a bold sans: with a large
serif headline the tops of some letters stayed visible above the translation.

Polly (the mascot) is not footage. It was drawn for Perspica with the Mascot Designer skill, the same
pictures the app ships in `app/Resources/Polly.xcassets`. In the movie it waves in the title, and in
each feature scene it thinks while the light runs and then points at the result. On the page it is a
plain picture with CSS motion that stops under Reduce Motion.

The glasses in the hero and in the movie are drawn by the page: each lens is a round window onto
`page-ja.png`, enlarged 1.1 times in the middle and 1.3 times at the edge.

### Taking the captures again

The terminal needs Screen Recording permission. `yaku-verify shot` captures a window on its own, which
turns Liquid Glass into flat grey, so the panel and the HUD are captured as a region with
`capture_region` from `app/tools/capture-lib.sh` while a `yaku-verify run` holds the window open (see
`.agents/skills/verify-yaku/features/panel-hud.md`). On a Mac with two displays, give the HUD a
`--demo-anchor` on the Retina display, or the capture comes out at 1 pixel per point.

## Rules the page and the movie keep

- Every claim comes from `README.md`, `SPEC.md` or a measurement named next to it.
- The download is the latest dmg on GitHub Releases. The page says it is a personal preview, that
  llama.cpp comes from Homebrew, and that the first launch needs **Open Anyway** (it is not notarized).
- "Built with PLaMo" stays on the page and in the movie (PLaMo Community License, article 4).
- The page loads nothing from other sites: no web fonts, no analytics, no embeds.

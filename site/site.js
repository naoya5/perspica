// Perspica landing page, second version: the glasses in the hero, the cards
// that come alive when first seen, the before/after control, the questions
// that open and close, and the copy button.
// No network requests, no storage.

// --- Sections come in once, the first time they are reached. ---
// This runs first and on its own, so an error further down cannot leave the
// page hidden. The hidden state applies only after .reveal-ready is set here.
(() => {
  if (!('IntersectionObserver' in window)) return;
  const main = document.querySelector('main');
  if (!main) return;

  const items = new Map(); // element -> 'heading' | 'text'
  for (const section of main.querySelectorAll(':scope > section:not(.hero)')) {
    // A heading with line breaks enters line by line.
    for (const h2 of section.querySelectorAll('h2')) {
      const lines = h2.querySelectorAll('.line');
      for (const el of lines.length ? lines : [h2]) items.set(el, 'heading');
    }
    const rest = section.querySelectorAll([
      '.section-head .eyebrow', '.section-head > p', '.section-head > div > p:not(.eyebrow)', '.section-head > dl',
      '.grid > .card', '.also', 'video', '.table-wrap', '.note', '.promises > div',
      '.terminal', '.questions', '.actions', '.polly',
    ].join(','));
    for (const el of rest) if (!items.has(el)) items.set(el, 'text');
  }
  for (const [el, kind] of items) el.dataset.reveal = kind;

  // The items that come into view in one callback cascade in page order.
  // The cascade stops growing after 6, so a tall window never waits long.
  const byPage = (a, b) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
  const observer = new IntersectionObserver((entries) => {
    const shown = entries
      // Also items already above the window, after a jump to #faq or a restored scroll.
      .filter((entry) => entry.isIntersecting || entry.boundingClientRect.bottom <= 0)
      .map((entry) => entry.target)
      .sort(byPage);
    shown.forEach((el, i) => {
      el.style.setProperty('--i', Math.min(i, 6));
      el.classList.add('in');
      observer.unobserve(el);
    });
  }, { rootMargin: '0px 0px -48px 0px' });
  for (const el of items.keys()) observer.observe(el);
  document.documentElement.classList.add('reveal-ready');
})();

(() => {
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  // The same curve as --ease-out in the stylesheet.
  const EASE_OUT = 'cubic-bezier(0.23, 1, 0.32, 1)';

  // --- The glasses ---
  // Each lens is a round window onto the translated page. The window is drawn
  // 1.1 times larger in the middle and 1.3 times larger at the thick edge, so
  // it reads as glass. A spring pulls the glasses after the pointer.
  const stage = document.getElementById('stage');
  const glasses = document.getElementById('glasses');
  if (stage && glasses) {
    const parts = [...glasses.querySelectorAll('[data-part]')];
    const sheet = stage.querySelector('.page');
    const MAGNIFY = 1.1;
    const EDGE_MAGNIFY = 1.3;
    const SPREAD = 1.18; // lens centre, in radii from the bridge

    let W = 0, H = 0, r = 0;
    // The page picture inside the stage: on a phone it is wider than the stage.
    const page = { x: 0, y: 0, w: 0, h: 0 };
    const edge = { x: 0, y: 0 };
    const pos = { x: 0, y: 0, vx: 0, vy: 0, a: 0, lift: 1 };
    const goal = { x: 0, y: 0 };
    let held = false, visible = false, running = false, last = 0, started = 0;

    const measure = () => {
      const box = stage.getBoundingClientRect();
      W = box.width;
      H = box.height;
      const inner = sheet.getBoundingClientRect();
      // The glasses are placed from the inside of the stage's border, so the
      // page and the pointer are measured from there too. Otherwise the view
      // in a lens is off by the border width times the magnification.
      edge.x = stage.clientLeft;
      edge.y = stage.clientTop;
      Object.assign(page, { x: inner.left - box.left - edge.x, y: inner.top - box.top - edge.y, w: inner.width, h: inner.height });
      r = Math.max(40, Math.min(W * 0.105, H * 0.36));
      glasses.style.setProperty('--r', `${r}px`);
      size();
    };

    // Sizes and resting places change only with the stage, so they are set
    // here. `layout` then moves the parts with transforms alone, and a frame
    // costs no layout. Setting `cssText` clears the transform, so every caller
    // of `measure` draws with `layout` afterwards.
    const size = () => {
      for (const el of parts) {
        const side = Number(el.dataset.side || 0);
        const part = el.dataset.part;
        if (part === 'frame' || part === 'shadow') {
          const w = r * 5.24, h = r * 2.24;
          el.style.cssText = `left:${-w / 2}px;top:${-h / 2}px;width:${w}px;height:${h}px`;
        } else if (part === 'lens') {
          el.style.cssText = `left:${side * r * SPREAD - r}px;top:${-r}px;width:${r * 2}px;height:${r * 2}px`;
          for (const img of el.querySelectorAll('img.view')) {
            img.style.cssText = `left:0;top:0;width:${page.w}px;height:${page.h}px;transform-origin:0 0`;
          }
        }
      }
    };

    const layout = () => {
      const rad = (pos.a * Math.PI) / 180;
      const cos = Math.cos(rad), sin = Math.sin(rad);
      // `lift` is 1 while the glasses are still above the page, 0 once they rest on it.
      glasses.style.transform = `translate(${pos.x}px, ${pos.y - pos.lift * r * 0.5}px) rotate(${pos.a}deg) scale(${1 + pos.lift * 0.22})`;
      glasses.style.opacity = 1 - pos.lift;
      for (const el of parts) {
        const side = Number(el.dataset.side || 0);
        const part = el.dataset.part;
        if (part === 'shadow') {
          const drop = r * (0.2 + pos.lift * 0.5);
          el.style.transform = `translate(${drop * 0.4}px, ${drop}px)`;
        } else if (part === 'lens') {
          // Where this lens sits on the sheet, so the view inside it lines up.
          const cx = pos.x + cos * side * r * SPREAD;
          const cy = pos.y + sin * side * r * SPREAD;
          el.querySelector('.upright').style.transform = `rotate(${-pos.a}deg)`;
          // The point of the page under the lens centre, in the picture's own
          // coordinates. It stays at the lens centre at any magnification.
          const ox = cx - page.x, oy = cy - page.y;
          for (const img of el.querySelectorAll('img.view')) {
            const scale = img.classList.contains('edge') ? EDGE_MAGNIFY : MAGNIFY;
            img.style.transform = `translate(${r - ox * scale}px, ${r - oy * scale}px) scale(${scale})`;
          }
        }
      }
    };

    // The sheet rises in on load (style.css, .spectacles). The glasses wait
    // until it is about half way, so they land on it and not in the air.
    const rising = stage.closest('.spectacles')?.getAnimations?.() ?? [];
    let landed = false;
    const landing = () => landed || (landed = rising.every((a) => {
      const { delay, duration } = a.effect.getTiming();
      return a.playState !== 'running' || a.currentTime >= delay + duration * 0.45;
    }));

    const frame = (now) => {
      if (!visible) { running = false; return; }
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      if (!started) started = now;
      if (!held) {
        // Until someone takes them, the glasses read the page by themselves.
        const t = (now - started) / 1000;
        goal.x = W * (0.5 + 0.27 * Math.sin(t * 0.38 + 0.4));
        goal.y = H * (0.47 + 0.2 * Math.sin(t * 0.61 + 0.9));
        // Stay in the part of the sheet that is on the screen. The frames write
        // transforms only, so this read finds the layout clean.
        const shown = Math.min(H, innerHeight - stage.getBoundingClientRect().top);
        if (shown > r * 2.4) goal.y = Math.min(goal.y, shown - r * 1.15);
      }
      const k = held ? 170 : 26, c = held ? 24 : 9;
      pos.vx += ((goal.x - pos.x) * k - pos.vx * c) * dt;
      pos.vy += ((goal.y - pos.y) * k - pos.vy * c) * dt;
      pos.x += pos.vx * dt;
      pos.y += pos.vy * dt;
      const tilt = Math.max(-7, Math.min(7, pos.vx * 0.012));
      pos.a += (tilt - pos.a) * Math.min(1, dt * 8);
      if (landing()) pos.lift += (0 - pos.lift) * Math.min(1, dt * 5);
      if (pos.lift < 0.002) pos.lift = 0;
      layout();
      // Held and at rest: nothing moves until the pointer does, so stop drawing.
      const still = held && pos.lift === 0 && Math.abs(pos.vx) + Math.abs(pos.vy) < 0.5
        && Math.abs(goal.x - pos.x) + Math.abs(goal.y - pos.y) < 0.3 && Math.abs(pos.a) < 0.02;
      if (still) { running = false; return; }
      requestAnimationFrame(frame);
    };
    const run = () => {
      if (running || reduceMotion || !visible) return;
      running = true;
      last = performance.now();
      requestAnimationFrame(frame);
    };

    const follow = (event) => {
      const box = stage.getBoundingClientRect();
      held = true;
      goal.x = event.clientX - box.left - edge.x;
      goal.y = event.clientY - box.top - edge.y;
      if (reduceMotion) {
        pos.x = goal.x;
        pos.y = goal.y;
        layout();
      } else {
        run();
      }
    };
    stage.addEventListener('pointermove', follow);
    stage.addEventListener('pointerdown', follow);
    stage.addEventListener('pointerleave', (event) => {
      // A finger lifted leaves the glasses where they are; a mouse hands them back.
      if (event.pointerType === 'mouse') { held = false; run(); }
    });
    new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      run();
    }, { threshold: 0.05 }).observe(stage);
    const refit = () => {
      measure();
      // A held lens can otherwise retain desktop coordinates after a resize.
      pos.x = Math.max(0, Math.min(W, pos.x));
      pos.y = Math.max(0, Math.min(H, pos.y));
      goal.x = Math.max(0, Math.min(W, goal.x));
      goal.y = Math.max(0, Math.min(H, goal.y));
      layout();
    };
    addEventListener('resize', refit);
    sheet.addEventListener('load', refit);

    measure();
    pos.x = goal.x = W * 0.5;
    pos.y = goal.y = H * 0.42;
    if (reduceMotion) pos.lift = 0;
    // `?at=x,y` (fractions of the sheet) holds the glasses still, for screenshots.
    const at = new URLSearchParams(location.search).get('at');
    if (at) {
      const [fx, fy] = at.split(',').map(Number);
      pos.x = goal.x = W * fx;
      pos.y = goal.y = H * fy;
      pos.lift = 0;
      held = true;
    }
    layout();
  }

  // --- Cards play their small motion once, the first time they are seen. ---
  const cards = document.querySelectorAll('.grid .card');
  const seen = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('seen');
      seen.unobserve(entry.target);
    }
  }, { threshold: 0.35 });
  cards.forEach((card) => seen.observe(card));

  // --- Before / after: the range input moves the cut. ---
  const compare = document.querySelector('#compare');
  const range = document.querySelector('.compare-control input');
  if (compare && range) {
    const apply = () => compare.style.setProperty('--cut', `${range.value}%`);
    range.addEventListener('input', apply);
    apply();
  }

  // --- Questions open and close over 200 ms instead of jumping. ---
  // Without this script, and with reduced motion, <details> works as it is.
  if (!reduceMotion) {
    for (const details of document.querySelectorAll('.questions details')) {
      const summary = details.querySelector('summary');
      const answer = summary.nextElementSibling;
      let running = null;

      const run = (from, to, opening) => {
        details.classList.toggle('closing', !opening);
        details.style.overflow = 'hidden';
        const timing = { duration: 200, easing: EASE_OUT };
        const fade = answer.animate({ opacity: opening ? [0, 1] : [1, 0] }, timing);
        const height = details.animate({ height: [`${from}px`, `${to}px`] }, timing);
        running = { height, fade };
        height.onfinish = () => {
          if (!opening) details.open = false;
          details.classList.remove('closing');
          details.style.overflow = '';
          running = null;
        };
      };

      summary.addEventListener('click', (event) => {
        event.preventDefault();
        // A second click in the middle starts from the height on screen.
        const from = details.getBoundingClientRect().height;
        const opening = !details.open || details.classList.contains('closing');
        if (running) {
          running.height.onfinish = null;
          running.height.cancel();
          running.fade.cancel();
        }
        if (opening) {
          details.open = true;
          run(from, details.getBoundingClientRect().height, true);
        } else {
          const style = getComputedStyle(details);
          const edge = parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth);
          run(from, summary.getBoundingClientRect().height + edge, false);
        }
      });
    }
  }

  // --- Copy the install commands. ---
  // The result is said beside the button, so the button keeps its width.
  for (const button of document.querySelectorAll('[data-copy-target]')) {
    const status = button.parentElement.querySelector('.copy-status');
    let timer = 0;
    button.addEventListener('click', async () => {
      const text = document.getElementById(button.dataset.copyTarget).innerText;
      let copied = true;
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        copied = false;
      }
      clearTimeout(timer);
      status.textContent = copied ? 'コピーしました' : 'コピーできませんでした';
      status.classList.add('shown');
      button.classList.toggle('done', copied);
      timer = setTimeout(() => {
        status.classList.remove('shown');
        button.classList.remove('done');
        // Empty the line once it has faded, so it is not read again later.
        timer = setTimeout(() => { status.textContent = ''; }, 200);
      }, 1600);
    });
  }
})();

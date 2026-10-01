// SimpleBrowser inspector tools agent -- audits, accessibility, storage
// browsers, animations and page overlays.
//
// Runs in the isolated world, injected by DevToolsController the first time
// one of its commands is used rather than at document start, so pages pay
// nothing for it while DevTools is closed. It adds its commands to the DOM
// agent's dispatcher (`__sbAgent.extend`) and shares its node registry, so
// node ids here are the Elements tree's.
(function () {
  "use strict";
  const agent = window.__sbAgent;
  if (!agent || agent.has("Tools.loaded")) return;

  // ---- FPS meter ----------------------------------------------------------------------
  // A fixed overlay counting animation frames, like Chrome's Rendering → FPS
  // meter. Frames that took over 1.5× the median are counted as dropped.
  const fps = { el: null, raf: 0, frames: [], value: 0, dropped: 0, history: [] };

  function drawFPS() {
    const now = performance.now();
    fps.frames.push(now);
    while (fps.frames.length && now - fps.frames[0] > 1000) fps.frames.shift();
    const n = fps.frames.length;
    if (n > 1) {
      const deltas = [];
      for (let i = 1; i < n; i++) deltas.push(fps.frames[i] - fps.frames[i - 1]);
      const median = deltas.slice().sort((a, b) => a - b)[deltas.length >> 1];
      fps.value = Math.round(((n - 1) * 1000) / (fps.frames[n - 1] - fps.frames[0]));
      fps.dropped = deltas.filter((d) => d > median * 1.5).length;
    }
    if (!fps.history.length || now - fps.history[fps.history.length - 1].t > 250) {
      fps.history.push({ t: now, v: fps.value });
      if (fps.history.length > 40) fps.history.shift();
      const label = fps.el.firstChild, canvas = fps.el.lastChild, ctx = canvas.getContext("2d");
      label.textContent = fps.value + " fps" + (fps.dropped ? "  ·  " + fps.dropped + " dropped/s" : "");
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      fps.history.forEach((p, i) => {
        const h = Math.min(1, p.v / 60) * canvas.height;
        ctx.fillStyle = p.v >= 50 ? "#7ed36f" : p.v >= 30 ? "#f2c037" : "#f28b82";
        ctx.fillRect(i * 4, canvas.height - h, 3, h);
      });
    }
    fps.raf = requestAnimationFrame(drawFPS);
  }

  function setFPSMeter(on) {
    if (on && !fps.el) {
      const el = document.createElement("div");
      el.setAttribute("aria-hidden", "true");
      el.style.cssText = "position:fixed;top:8px;right:8px;z-index:2147483647;pointer-events:none;background:rgba(32,33,36,.88);" +
        "color:#e8eaed;font:11px/1.4 Menlo,monospace;padding:6px 8px;border-radius:4px;box-shadow:0 2px 8px rgba(0,0,0,.35);";
      const label = document.createElement("div");
      const canvas = document.createElement("canvas");
      canvas.width = 160; canvas.height = 32;
      canvas.style.cssText = "display:block;margin-top:4px;width:160px;height:32px;";
      el.append(label, canvas);
      (document.documentElement || document.body).appendChild(agent.own(el));
      fps.el = el; fps.frames = []; fps.history = [];
      fps.raf = requestAnimationFrame(drawFPS);
    } else if (!on && fps.el) {
      cancelAnimationFrame(fps.raf);
      agent.disown(fps.el);
      fps.el.remove();
      fps.el = null;
    }
    return !!fps.el;
  }

  const handlers = {
    "Tools.loaded": () => true,
    "Rendering.setFPSMeter": ({ enabled }) => setFPSMeter(!!enabled),
    "Rendering.getFPS": () => ({ shown: !!fps.el, fps: fps.value, dropped: fps.dropped }),
  };

  agent.extend(handlers);
})();

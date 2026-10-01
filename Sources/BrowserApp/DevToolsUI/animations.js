// SimpleBrowser DevTools — the Animations drawer: every running CSS
// animation, CSS transition and Web Animation on the page, with pause,
// replay, scrubbing and a global playback rate. WebKit's Animation domain
// only reports animations, so control goes through the Web Animations API in
// the isolated world (tools-agent.js), which drives the same animations.
"use strict";

(function () {
  const SBAnimations = window.SBAnimations = {
    list: [],
    rate: 1,
    timer: null,
    paused: false,

    async refresh() {
      try { this.list = await DevTools.rpc("Animations.list"); this.error = null; }
      catch (e) { this.list = []; this.error = e.message; }
      this.render();
      return this.list;
    },

    async command(method, params = {}) {
      try { await DevTools.rpc(method, params); } catch (e) { Toast.show(e.message); }
      return this.refresh();
    },
    pauseAll() { this.paused = true; return this.command("Animations.pause", {}); },
    resumeAll() { this.paused = false; return this.command("Animations.play", {}); },
    replayAll() { return this.command("Animations.replay", {}); },
    setRate(rate) { this.rate = rate; return this.command("Animations.setPlaybackRate", { rate }); },

    render() {
      const body = $("#animations-list");
      if (!body) return;
      for (const b of $$("#animations-rates button")) b.classList.toggle("active", +b.dataset.rate === this.rate);
      $("#animations-pause").textContent = this.paused ? "▶ Resume all" : "⏸ Pause all";
      body.textContent = "";
      if (this.error) { body.appendChild(h("div", { class: "detail-note v-error" }, this.error)); return; }
      if (!this.list.length) { body.appendChild(h("div", { class: "empty-state" }, "No animations are running. Start one on the page and it appears here.")); return; }
      for (const a of this.list) {
        const duration = a.duration || 0;
        const total = a.delay + duration * (typeof a.iterations === "number" ? a.iterations : 1) + a.endDelay;
        const progress = a.progress != null ? a.progress : 0;
        const bar = h("div", { class: "anim-track", title: "Click to scrub" },
          h("div", { class: "anim-delay", style: `width:${total ? (a.delay / total) * 100 : 0}%` }),
          h("div", { class: "anim-progress", style: `width:${Math.max(0, Math.min(1, progress)) * 100}%` }));
        bar.addEventListener("click", (e) => {
          const r = bar.getBoundingClientRect();
          this.command("Animations.seek", { ids: [a.id], time: ((e.clientX - r.left) / r.width) * (total || duration) });
        });
        const target = a.target ? h("span", { class: "link mono", title: "Reveal in Elements panel", onclick: () => { DevTools.showPanel("elements"); DevTools.panels.elements.revealNode(a.target.nodeId); } },
          a.target.label + (a.pseudo || "")) : h("span", { class: "muted" }, "(no target)");
        const toggle = h("button", { class: "icon-button small", title: a.playState === "paused" ? "Play" : "Pause" }, a.playState === "paused" ? "▶" : "⏸");
        toggle.addEventListener("click", () => this.command(a.playState === "paused" ? "Animations.play" : "Animations.pause", { ids: [a.id] }));
        const replay = h("button", { class: "icon-button small", title: "Replay" }, "↻");
        replay.addEventListener("click", () => this.command("Animations.replay", { ids: [a.id] }));
        const timing = [duration ? Math.round(duration) + " ms" : "", a.delay ? "delay " + Math.round(a.delay) + " ms" : "",
          a.iterations === "infinite" ? "∞" : a.iterations > 1 ? "×" + a.iterations : "", a.easing && a.easing !== "linear" ? a.easing : "", a.playbackRate !== 1 ? a.playbackRate + "×" : ""].filter(Boolean).join(" · ");
        body.appendChild(h("div", { class: "anim-row " + a.playState, "data-name": a.name },
          toggle, replay,
          h("div", { class: "anim-info" }, h("div", {}, h("span", { class: "anim-name" }, a.name), " ", h("span", { class: "muted" }, a.type), " ", target),
            h("div", { class: "muted anim-timing" }, `${a.playState} · ${timing}`)),
          bar));
      }
    },

    show() {
      this.refresh();
      clearInterval(this.timer);
      this.timer = setInterval(() => { if (Drawer.current === "animations" && DevTools.panels) this.refresh(); }, 500);
    },
    hide() { clearInterval(this.timer); this.timer = null; },

    init() {
      $("#animations-pause").addEventListener("click", () => this.paused ? this.resumeAll() : this.pauseAll());
      $("#animations-replay").addEventListener("click", () => this.replayAll());
      $("#animations-refresh").addEventListener("click", () => this.refresh());
      for (const b of $$("#animations-rates button")) b.addEventListener("click", () => this.setRate(+b.dataset.rate));
      DevTools.on("DOM.documentUpdated", () => { this.paused = false; this.rate = 1; if (Drawer.current === "animations") this.refresh(); });
    },
  };

  Drawer.register("animations", { title: "Animations", init: () => SBAnimations.init(), show: () => SBAnimations.show(), hide: () => SBAnimations.hide() });
})();

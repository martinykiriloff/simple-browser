// Keel DevTools — actor tags: who caused a console message or a request.
//
// "agent" when it happened while an AI agent's tool call was running in
// this tab (or just after it returned: the click's request starts as the
// call ends), "human" within a second of the person clicking, typing or
// scrolling in the page, else "page". Agent calls come from the Agent panel
// and the app; human input times from the page view, which counts only
// events the app dispatched (an agent's synthetic input is not among them).
"use strict";

(function () {
  const AGENT_GRACE = 400;     // ms after a call returns that still counts as the agent's
  const AGENT_LEAD = 30;       // ms before the recorded start (clock rounding)
  const HUMAN_WINDOW = 1000;   // ms after a human input

  const Actors = window.Actors = {
    human: [],
    agent: [],                 // [[start, end]], sorted by start
    listeners: [],
    pendingFrom: null,
    timer: null,

    LABELS: { agent: "agent", human: "you", page: "" },
    TITLES: { agent: "Happened while an AI agent's tool call ran in this tab", human: "Happened within a second of your click, key press or scroll in the page", page: "" },

    async start() {
      DevTools.on("Actors.humanInput", ({ time }) => { this.human.push(time); if (this.human.length > 500) this.human.shift(); this.changed(time); });
      try {
        const known = await DevTools.rpc("Actors.get");
        this.human = (known.human || []).concat(this.human).sort((a, b) => a - b);
        this.addWindows(known.agent || []);
      } catch (_) {}
      if (window.AgentPanel) this.addCalls(AgentPanel.calls);
    },

    /// Agent calls as the Agent panel has them ({ time, ms }).
    addCalls(calls) {
      this.addWindows((calls || []).filter((c) => typeof c.time === "number").map((c) => [c.time, c.time + (c.ms || 0)]));
    },

    addWindows(windows) {
      let from = null;
      for (const [start, end] of windows) {
        if (this.agent.some((w) => w[0] === start)) continue;
        this.agent.push([start, end]);
        from = from == null ? start : Math.min(from, start);
      }
      if (from == null) return;
      this.agent.sort((a, b) => a[0] - b[0]);
      if (this.agent.length > 2000) this.agent.splice(0, this.agent.length - 2000);
      this.changed(from);
    },

    /// "agent", "human" or "page" for a moment (ms since 1970).
    of(ms) {
      if (typeof ms !== "number" || !isFinite(ms)) return "page";
      for (let i = this.agent.length - 1; i >= 0; i--) {
        const [start, end] = this.agent[i];
        if (ms >= start - AGENT_LEAD && ms <= end + AGENT_GRACE) return "agent";
        if (end + AGENT_GRACE < ms - 600000) break;
      }
      for (let i = this.human.length - 1; i >= 0; i--) {
        const t = this.human[i];
        if (t > ms) continue;
        return ms - t <= HUMAN_WINDOW ? "human" : "page";
      }
      return "page";
    },

    /// A small badge for a row; empty for page.
    badge(actor) {
      return h("span", { class: "actor-tag actor-" + actor, title: this.TITLES[actor] || "" }, this.LABELS[actor] || "");
    },

    /// Called with the earliest time whose tag may have changed.
    onChange(fn) { this.listeners.push(fn); },

    changed(from) {
      this.pendingFrom = this.pendingFrom == null ? from : Math.min(this.pendingFrom, from);
      if (this.timer) return;
      this.timer = setTimeout(() => {
        const at = this.pendingFrom;
        this.timer = null;
        this.pendingFrom = null;
        for (const fn of this.listeners) { try { fn(at); } catch (e) { console.error(e); } }
      }, 60);
    },
  };
})();

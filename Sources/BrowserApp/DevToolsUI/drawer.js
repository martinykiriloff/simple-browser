// SimpleBrowser DevTools — the drawer: Chrome's bottom strip for tools that
// sit beside whichever panel is showing (request blocking, overrides,
// search, Rendering, Animations). Tools register a pane; the drawer owns
// the tabs, the height and which one is showing.
"use strict";

const Drawer = window.Drawer = {
  panes: new Map(),
  current: null,

  // `pane`: { title, init(), show(), hide() }; its markup is #drawer-<name>.
  register(name, pane) {
    this.panes.set(name, Object.assign({ initialized: false }, pane));
    const tab = h("button", { class: "subtab", "data-drawer": name }, pane.title);
    tab.addEventListener("click", () => this.show(name));
    $("#drawer-tabs").insertBefore(tab, $("#drawer-tabs-end"));
  },

  init() {
    $("#drawer-close").addEventListener("click", () => this.hide());
    for (const item of $$("#more-menu [data-drawer]")) {
      item.addEventListener("click", () => { Popup.hideAll(); this.show(item.dataset.drawer); });
    }
    try { const saved = +localStorage.getItem("devtools.drawer.height"); if (saved > 60) $("#drawer").style.height = saved + "px"; } catch (_) {}
    $("#drawer-resizer").addEventListener("mousedown", (e) => {
      e.preventDefault();
      const drawer = $("#drawer"), startY = e.clientY, startH = drawer.getBoundingClientRect().height;
      const move = (ev) => { drawer.style.height = Math.max(80, Math.min(innerHeight - 120, startH + startY - ev.clientY)) + "px"; };
      const up = () => {
        document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
        try { localStorage.setItem("devtools.drawer.height", String(parseInt(drawer.style.height, 10))); } catch (_) {}
      };
      document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
    });
  },

  show(name) {
    const pane = this.panes.get(name);
    if (!pane) return;
    $("#drawer").hidden = false;
    if (this.current && this.current !== name) this.panes.get(this.current).hide?.();
    this.current = name;
    for (const tab of $$("#drawer-tabs .subtab")) tab.classList.toggle("active", tab.dataset.drawer === name);
    for (const section of $$(".drawer-pane")) section.classList.toggle("active", section.id === "drawer-" + name);
    if (!pane.initialized) { pane.initialized = true; pane.init?.(); }
    pane.show?.();
  },

  hide() {
    if (this.current) this.panes.get(this.current).hide?.();
    this.current = null;
    $("#drawer").hidden = true;
  },

  toggle(name) {
    if (this.current === name && !$("#drawer").hidden) this.hide(); else this.show(name);
  },
};

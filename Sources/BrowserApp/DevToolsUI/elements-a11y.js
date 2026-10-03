// Keel DevTools — the Elements sidebar's Accessibility pane: the
// accessibility tree around the selected node, and its computed role, name,
// description and properties. WebKit's own accessibility object comes from
// the protocol (DOM.getAccessibilityPropertiesForNode); the name's source,
// the description and the tree are computed by the tools agent.
"use strict";

(function () {
  const panel = DevTools.panels.elements;

  Object.assign(panel, {
    a11yGeneration: 0,

    async loadAccessibility(id) {
      const view = $("#a11y-view");
      const generation = ++this.a11yGeneration;
      let computed, ancestors, tree, engine = null, engineError = null;
      try {
        [computed, ancestors, tree] = await Promise.all([
          DevTools.rpc("Accessibility.getNode", { nodeId: id }),
          DevTools.rpc("Accessibility.getAncestors", { nodeId: id }),
          DevTools.rpc("Accessibility.getTree", { nodeId: id }),
        ]);
      } catch (e) {
        if (generation !== this.a11yGeneration) return;
        view.textContent = "";
        view.appendChild(h("div", { class: "styles-note" }, e.message));
        return;
      }
      try { engine = await DevTools.rpc("Accessibility.getEngineProperties", { nodeId: id }); }
      catch (e) { engineError = e.message; }
      if (generation !== this.a11yGeneration) return;
      this.a11y = { computed, ancestors, tree, engine };

      view.textContent = "";
      // Tree: the ancestors down to this node, then its accessible children.
      const treeBox = h("div", { class: "a11y-tree" });
      const row = (node, depth, current) => {
        const el = h("div", { class: "a11y-node" + (current ? " current" : ""), style: `padding-left:${8 + depth * 12}px`, title: "Select in the Elements panel" },
          h("span", { class: "a11y-role" }, node.role), node.name ? h("span", { class: "a11y-name" }, " \"" + node.name + "\"") : null);
        el.addEventListener("click", () => this.revealNode(node.nodeId));
        el.addEventListener("mouseenter", () => DevTools.rpc("Overlay.highlightNode", { nodeId: node.nodeId }).catch(() => {}));
        el.addEventListener("mouseleave", () => DevTools.rpc("Overlay.hideHighlight").catch(() => {}));
        return el;
      };
      const shown = ancestors.filter((a, i) => i === ancestors.length - 1 || (a.role !== "generic" && a.role !== "presentation"));
      shown.forEach((a, i) => treeBox.appendChild(row(a, i, i === shown.length - 1)));
      const walk = (children, depth) => { for (const c of children) { treeBox.appendChild(row(c, depth, false)); walk(c.children || [], depth + 1); } };
      walk(tree.children, shown.length);
      view.appendChild(this.a11ySection("Accessibility Tree", treeBox));

      // Computed properties: WebKit's answer first where it has one.
      const props = h("div", { class: "a11y-props" });
      const prop = (name, value, note) => props.appendChild(h("div", { class: "a11y-prop" },
        h("span", { class: "a11y-prop-name" }, name), h("span", { class: "a11y-prop-value" + (value === "" ? " empty" : "") }, value === "" ? "\"\"" : String(value)),
        note ? h("span", { class: "a11y-prop-note" }, note) : null));
      const role = engine && engine.exists ? engine.role || computed.role : computed.role;
      const name = engine && engine.exists && engine.label != null && engine.label !== "" ? engine.label : computed.name;
      prop("Name", name, computed.nameSource ? "from " + computed.nameSource : "");
      prop("Role", role, engine && engine.exists && engine.role && engine.role !== computed.role ? "(DevTools computes " + computed.role + ")" : "");
      if (computed.description) prop("Description", computed.description);
      const ignored = engine ? !!(engine.ignored || engine.hidden || !engine.exists) : computed.ignored;
      prop("Ignored", ignored ? "true" : "false", engine && engine.ignoredByDefault ? "ignored by default" : "");
      const fromEngine = engine ? {
        checked: engine.checked, pressed: engine.pressed, expanded: engine.expanded, selected: engine.selected, disabled: engine.disabled,
        required: engine.required, readonly: engine.readonly, invalid: engine.invalid, busy: engine.busy, focused: engine.focused,
        level: engine.headingLevel || engine.hierarchyLevel, live: engine.liveRegionStatus, current: engine.current,
        haspopup: engine.isPopUpButton || undefined,
      } : {};
      const merged = Object.assign({}, computed.properties);
      for (const [k, v] of Object.entries(fromEngine)) if (v !== undefined && v !== null && v !== "" && !(v === false && merged[k] === undefined)) merged[k] = v;
      for (const [k, v] of Object.entries(merged)) prop(k, v);
      view.appendChild(this.a11ySection("Computed Properties", props));
      view.appendChild(h("div", { class: "styles-note" }, engine
        ? "Role, name and states come from WebKit's accessibility object for this node, what VoiceOver gets; the name's source, the description and the tree are computed by DevTools."
        : "Computed by DevTools from the DOM (HTML-AAM and accessible-name rules); WebKit's own accessibility object needs the inspector protocol" + (engineError ? ": " + engineError : ".")));
    },

    a11ySection(title, content) {
      const s = h("div", { class: "detail-section" });
      const head = h("div", { class: "detail-head" }, title);
      head.addEventListener("click", () => s.classList.toggle("collapsed"));
      s.append(head, h("div", { class: "a11y-body" }, content));
      return s;
    },
  });
})();

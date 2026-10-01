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

  const handlers = {
    "Tools.loaded": () => true,
  };

  agent.extend(handlers);
})();

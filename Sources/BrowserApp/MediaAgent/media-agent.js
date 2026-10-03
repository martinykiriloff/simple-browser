// Keel media agent: what a tab is playing, and play/pause/next
// from the toolbar, the media keys and Picture in Picture. Runs in its own
// content world; next and previous are the page's own media session
// actions, which a small hook in the page keeps for it.
(() => {
  "use strict";
  if (window.__simpleBrowserMedia) return;
  const post = (body) => { try { window.webkit.messageHandlers.simpleBrowserMedia.postMessage(body); } catch (e) {} };
  let last = null;       // the element that played most recently
  let reported = "";

  const media = () => Array.from(document.querySelectorAll("video, audio"));
  const audible = (m) => !m.paused && !m.muted && m.volume > 0 && !m.ended;
  const hasVideo = () => media().some((m) => m.tagName === "VIDEO" && m.readyState > 0 && m.videoWidth > 0);

  function report() {
    const playing = media().some((m) => !m.paused && !m.ended);
    const state = {
      kind: "state",
      playing,
      audible: media().some(audible),
      hasVideo: hasVideo(),
      pictureInPicture: media().some((m) => m.webkitPresentationMode === "picture-in-picture"),
      title: (navigator.mediaSession && navigator.mediaSession.metadata && navigator.mediaSession.metadata.title) || document.title,
      artist: (navigator.mediaSession && navigator.mediaSession.metadata && navigator.mediaSession.metadata.artist) || "",
      canSkip: document.documentElement.dataset.sbMediaActions ? document.documentElement.dataset.sbMediaActions.includes("nexttrack") : false,
    };
    const key = JSON.stringify(state);
    if (key !== reported) { reported = key; post(state); }
  }

  // Media events do not bubble, but they pass the document on the way down.
  for (const type of ["play", "playing", "pause", "ended", "volumechange", "loadedmetadata", "emptied", "enterpictureinpicture", "leavepictureinpicture"]) {
    document.addEventListener(type, (event) => {
      if (event.target instanceof HTMLMediaElement) {
        if (type === "play" || type === "playing") last = event.target;
        report();
      }
    }, true);
  }
  document.addEventListener("webkitpresentationmodechanged", report, true);

  function target() {
    if (last && last.isConnected) return last;
    return media().find((m) => !m.paused) || media()[0] || null;
  }

  function video() {
    const playing = media().filter((m) => m.tagName === "VIDEO" && m.videoWidth > 0);
    return playing.find((m) => !m.paused) || playing[0] || null;
  }

  window.__simpleBrowserMedia = {
    report,
    command(name) {
      const m = target();
      if (name === "pause") { media().forEach((x) => x.pause()); return true; }
      if (!m) return false;
      if (name === "play") { m.play(); return true; }
      if (name === "toggle") { if (media().some((x) => !x.paused)) media().forEach((x) => x.pause()); else m.play(); return true; }
      return false;
    },
    pictureInPicture(on) {
      const v = on ? video() : media().find((m) => m.webkitPresentationMode === "picture-in-picture");
      if (!v || !v.webkitSupportsPresentationMode || !v.webkitSupportsPresentationMode("picture-in-picture")) return false;
      v.webkitSetPresentationMode(on ? "picture-in-picture" : "inline");
      return true;
    },
    isPlayingVideo() { const v = video(); return !!(v && !v.paused); },
  };
  setInterval(report, 1500);   // titles and metadata change without events
})();

// Runs in Douyin's own page context (manifest: world MAIN). On the first video
// a page loads, Douyin's "f" (open the author's profile) also calls
// document.exitFullscreen(); on later videos the profile opens inside
// fullscreen. Ignore Douyin's exit calls for a moment after an "f" press.
// Esc and MediaCtrl's own exits don't go through this page's exitFullscreen.
(() => {
    const AFTER_KEY_MS = 1000;
    let fPressedAt = -Infinity;

    document.addEventListener("keydown", (e) => {
        if (e.isTrusted && (e.key === "f" || e.key === "F") && !e.ctrlKey && !e.altKey && !e.metaKey)
            fPressedAt = performance.now();
    }, true);

    const exit = Document.prototype.exitFullscreen;
    Document.prototype.exitFullscreen = function () {
        if (document.fullscreenElement && performance.now() - fPressedAt < AFTER_KEY_MS)
            return Promise.resolve();
        return exit.call(this);
    };
})();

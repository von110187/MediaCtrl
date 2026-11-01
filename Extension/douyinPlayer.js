// Runs in Douyin's own page context (manifest: world MAIN). Douyin's newer
// player decodes video in the page and feeds the <video> a live stream
// (srcObject), which ignores currentTime and playbackRate; its player object,
// kept on the .douyin-player element as _player.proxy, seeks and changes
// speed. content.js can't see that object from its isolated world, so it
// asks with a "mediactrl:control" event on the video (detail: JSON
// {to} / {by} seconds, {rate}, or {get: "rate"}, answered in the video's
// data-mediactrl-rate). The event is cancelled when the player did the job.
(() => {
    document.addEventListener("mediactrl:control", (e) => {
        const video = e.target;
        try {
            const player = video.closest(".douyin-player")?._player?.proxy;
            if (!player) return;
            const cmd = JSON.parse(e.detail);
            if (typeof cmd.to === "number") {
                player.currentTime = cmd.to;
            } else if (typeof cmd.by === "number") {
                const max = isFinite(player.duration) ? player.duration : Infinity;
                player.currentTime = Math.max(0, Math.min(player.currentTime + cmd.by, max));
            } else if (typeof cmd.rate === "number") {
                player.playbackRate = cmd.rate;
            } else if (cmd.get === "rate") {
                video.setAttribute("data-mediactrl-rate", String(player.playbackRate));
            } else {
                return;
            }
            e.preventDefault();
        } catch (err) {
            // player gone (revoked proxy) or a bad request: content.js falls back
        }
    }, true);
})();

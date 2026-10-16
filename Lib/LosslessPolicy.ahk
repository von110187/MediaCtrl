; ============ LOSSLESS SCALING POLICY ============
; Pure module: no Send/WinActive/COM calls. Decides when to press the
; Lossless Scaling hotkey (it toggles scaling for the foreground window):
;   - on when a video's fullscreen is confirmed, off when it ends;
;   - a manual press during a fullscreen video hands that page to the user —
;     no more automatic on/off for it, except "off" when it leaves fullscreen;
;   - outside fullscreen, manual presses (e.g. for a game) are left alone;
;   - a toggle wanted while Chrome isn't foreground waits until it is.
; See design.md "Lossless Scaling".

class LosslessPolicy {
    ; on: what we believe scaling is (tracked, or detected when available)
    ; manualPage: pageId the user took over with a manual press
    ; pending: "on" / "off" waiting for Chrome to come to the foreground
    ; detected: SetDetected() has been used, so `on` is observed, not assumed
    static New() {
        return {on: false, manualPage: "", pending: "", detected: false}
    }

    ; fsState: the FsMachine state just reached ("fullscreen" | "normal").
    ; adopted: the first report after an AHK reload said fullscreen — the
    ; previous instance turned scaling on, so assume it's on (unless detected).
    static OnFullscreenChange(ls, fsState, pageId, chromeForeground, adopted := false) {
        if fsState == "fullscreen" {
            if adopted && !ls.detected {
                ls.on := true
                ls.pending := ""
                return ""
            }
            wanted := ls.manualPage == pageId ? ls.on : true
        } else if fsState == "normal" {
            ; always off on leaving, even on a manual page
            wanted := false
            if ls.on
                ls.manualPage := ""
        } else {
            return ""
        }
        return LosslessPolicy._Want(ls, wanted, chromeForeground)
    }

    ; Chrome came to the foreground: apply a change held back while it wasn't.
    static OnChromeForeground(ls) {
        if ls.pending == ""
            return ""
        return LosslessPolicy._Want(ls, ls.pending == "on", true)
    }

    ; F1/F2/F3 pressed: the key always goes out, so scaling flips.
    static OnManualPress(ls, fsState, pageId) {
        ls.on := !ls.on
        ls.pending := ""
        if fsState == "fullscreen"
            ls.manualPage := pageId
    }

    ; Observed state from Lib/LosslessDetect.ahk, fed in before each change.
    static SetDetected(ls, isOn) {
        ls.detected := true
        ls.on := isOn ? true : false
    }

    static _Want(ls, wanted, chromeForeground) {
        if wanted == ls.on {
            ls.pending := ""
            return ""
        }
        if !chromeForeground {
            ls.pending := wanted ? "on" : "off"
            return ""
        }
        ls.on := wanted
        ls.pending := ""
        return "toggle"
    }
}

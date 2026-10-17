; ============ LOSSLESS SCALING POLICY ============
; Pure module: no Send/WinActive/COM calls. Decides when to press the
; Lossless Scaling hotkey (it toggles scaling for the foreground window):
;   - on when a video's fullscreen is confirmed, off when it ends — every
;     time, also when the same video re-enters fullscreen;
;   - a manual press (F1/F2/F3) only flips what we believe the state is, so
;     the next automatic change still goes the right way;
;   - a toggle wanted while Chrome isn't foreground waits until it is.

class LosslessPolicy {
    ; on: what we believe scaling is (tracked, or detected when available)
    ; pending: "on" / "off" waiting for Chrome to come to the foreground
    ; detected: SetDetected() has been used, so `on` is observed, not assumed
    static New() {
        return {on: false, pending: "", detected: false}
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
            wanted := true
        } else if fsState == "normal" {
            wanted := false
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
    static OnManualPress(ls) {
        ls.on := !ls.on
        ls.pending := ""
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

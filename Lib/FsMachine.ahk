; ============ FULLSCREEN STATE MACHINE ============
; Pure module: no Send/WinActive/COM calls, time is always passed in (ms).
; Never assumes a request worked — only the extension's fullscreen reports
; move the state to "fullscreen" / "normal". Each request gets one retry,
; then gives up and falls back to whatever the page last reported.
; Same machine as the Mac version of MediaCtrl, which this was ported from.

class FsMachine {
    static CONFIRM_MS := 1000

    ; lastReported: "" until the first report, then true/false
    ; pageId: the page the in-flight request is for
    static New() {
        return {state: "normal", lastReported: "", attempt: 0, deadline: "", pageId: ""}
    }

    static _StartAttempt(m, attempt, now) {
        m.attempt := attempt
        m.deadline := now + FsMachine.CONFIRM_MS
    }

    static _Settle(m, state) {
        m.state := state
        m.attempt := 0
        m.deadline := ""
    }

    ; kind: "enter" | "exit". Returns "nudge" | "exitCmd", or "" if not allowed
    ; (already in progress, or already in the requested state).
    ; pageId: the page this request is for (see Report()).
    static Request(m, kind, now, pageId := "") {
        if kind == "enter" && m.state == "normal" {
            m.state := "entering"
            m.pageId := pageId
            FsMachine._StartAttempt(m, 1, now)
            return "nudge"
        } else if kind == "exit" && m.state == "fullscreen" {
            m.state := "exiting"
            m.pageId := pageId
            FsMachine._StartAttempt(m, 1, now)
            return "exitCmd"
        }
        return ""
    }

    ; Called on every fullscreen report from the extension.
    ; Returns "confirmed" | "unrequestedExit" | "adopted" | "cancelled" | "".
    static Report(m, isFullscreen, pageChanged, now, pageId := "") {
        isFullscreen := isFullscreen ? true : false
        fresh := m.lastReported == ""
        m.lastReported := isFullscreen

        ; a report from a different page (tab/window switch) mid-request: that
        ; request is moot — never retry it into the other page
        inFlight := m.state == "entering" || m.state == "exiting"
        if inFlight && m.pageId != "" && pageId != "" && pageId != m.pageId {
            FsMachine._Settle(m, isFullscreen ? "fullscreen" : "normal")
            return "cancelled"
        }

        if m.state == "entering" {
            if isFullscreen {
                FsMachine._Settle(m, "fullscreen")
                return "confirmed"
            }
            return ""  ; still waiting; Timeout() handles retries
        } else if m.state == "exiting" {
            if !isFullscreen {
                FsMachine._Settle(m, "normal")
                return "confirmed"
            }
            return ""
        }

        ; first report after an AHK (re)load: take it as the truth,
        ; it is not something the user just did
        if fresh {
            FsMachine._Settle(m, isFullscreen ? "fullscreen" : "normal")
            return ""
        }

        if m.state == "normal" && isFullscreen {
            FsMachine._Settle(m, "fullscreen")
            return "adopted"  ; user used the site's own button, etc.
        } else if m.state == "fullscreen" && !isFullscreen {
            ; pageChanged is passed on by the caller to Decide.OnUnrequestedExit
            FsMachine._Settle(m, "normal")
            return "unrequestedExit"
        }
        return ""
    }

    ; The page couldn't enter fullscreen itself — go straight to the key fallback.
    static EnterFailed(m, now) {
        if m.state != "entering"
            return ""
        FsMachine._StartAttempt(m, 2, now)
        return "fsKey"
    }

    ; Called on a timer. Returns "fsKey" | "exitCmd" (retry), "gaveUp", or "".
    static Timeout(m, now) {
        if (m.state != "entering" && m.state != "exiting") || now <= m.deadline
            return ""
        if m.attempt == 1 {
            cmd := m.state == "entering" ? "fsKey" : "exitCmd"
            FsMachine._StartAttempt(m, 2, now)
            return cmd
        }
        FsMachine._Settle(m, m.lastReported == true ? "fullscreen" : "normal")
        return "gaveUp"
    }
}

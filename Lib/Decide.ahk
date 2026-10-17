; ============ VIDEO STATE RULES ============
; Pure module: no Send/WinActive/COM calls, so tests/RunTests.ahk can test it.
; Given a snapshot of inputs, decides whether to enter/exit fullscreen and
; whether the video-mode keys should be on. Same rules as the Mac version
; of MediaCtrl, which this was ported from.

class Decide {
    ; consecutive ticks a page must look "not playable" before we treat it as
    ; left — absorbs brief <video> swaps (Douyin feed) without a false exit
    static MISS_TICKS := 3

    ; manualExitPage: the pageId the manual exit belongs to — another video
    ; page isn't blocked by it, the same page still is after an app switch
    static New() {
        return {manualExit: false, manualExitPage: "", notPlayableTicks: 0, lastKeys: false}
    }

    static _Result(state, enter, exit, keys) {
        state.lastKeys := keys
        return {enter: enter, exit: exit, keys: keys}
    }

    ; inp: connected, monitorOn, chromeFocused, site ("" = none), playable,
    ;      playing, ready, editableFocused, pageId,
    ;      fs ("normal" | "entering" | "fullscreen" | "exiting")
    ; isTick: true only from the main timer, so the miss counter moves once per tick
    static Evaluate(state, inp, isTick) {
        ; extension gone: we know nothing new, so no enter/exit and no tick
        ; counting. Keys off — they can't reach the page, and Esc should go to
        ; Chrome itself (which exits fullscreen on its own).
        if !inp.connected
            return Decide._Result(state, false, false, false)

        if !inp.monitorOn
            return Decide._Result(state, false, false, false)

        ; Rule 1: not Chrome / not a matched site. Switching apps never exits
        ; fullscreen by itself, and doesn't forget a manual exit either — coming
        ; back to the same video keeps it out of fullscreen (Rule 4).
        if !inp.chromeFocused || !inp.site {
            if isTick
                state.notPlayableTicks := 0
            return Decide._Result(state, false, false, false)
        }

        ; Rule 7: leaving a playable page needs MISS_TICKS consecutive ticks
        if isTick
            state.notPlayableTicks := inp.playable ? 0 : state.notPlayableTicks + 1
        if !inp.playable {
            if state.notPlayableTicks < Decide.MISS_TICKS
                return Decide._Result(state, false, false, state.lastKeys)
            state.manualExit := false
            return Decide._Result(state, false, inp.fs == "fullscreen", false)
        }

        ; typing in a text field on the page: let the letters through, and
        ; don't yank the page into fullscreen mid-typing
        if inp.editableFocused
            return Decide._Result(state, false, false, false)

        if inp.playing {
            ; Rule 3: auto-enter; Rule 4: not after a manual exit
            blocked := state.manualExit && state.manualExitPage == inp.pageId
            enter := inp.fs == "normal" && inp.ready && !blocked
            return Decide._Result(state, enter, false, true)
        }

        ; Rule 5: paused in fullscreen keeps keys on
        if inp.fs == "fullscreen"
            return Decide._Result(state, false, false, true)

        ; Rule 6: stopped and not fullscreen — done
        if inp.fs == "normal"
            state.manualExit := false
        return Decide._Result(state, false, false, false)
    }

    ; Rule 8: a fullscreen exit the script didn't request counts as manual,
    ; except when the page itself was replaced (reload / navigation).
    ; pageId: the page the exit happened on.
    static OnUnrequestedExit(state, pageChanged, pageId := "") {
        if !pageChanged {
            state.manualExit := true
            state.manualExitPage := pageId
        }
    }
}

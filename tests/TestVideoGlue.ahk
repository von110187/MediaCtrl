; StateEngine.ahk + Video.ahk end to end, with a fake VideoEnv: page reports
; go in through OnBridgeMessage, and the keys / bridge messages that would
; have gone out are recorded. Mirrors the hands-on checks in
; docs/windows-checks.md.

; Not under test — real versions live in files the runner doesn't include.
BridgeClient_Send(msg) {
}
BridgeClient_Connected() => true
_LosslessActive(*) => false
UpdateClockVisibility() {
}
MonitorTick() {
}

class FakeEnv {
    __New() {
        this.t := 100000, this.fg := "chrome.exe", this.hwnd := 1
        this.keys := [], this.msgs := [], this.timers := Map()
        this.hotkeysOn := false, this.ls := false, this.isConnected := true
    }
    now() => this.t
    foreground() => this.hwnd
    processName() => this.fg
    send(keys) {
        this.keys.Push(keys)
        if keys == CONFIG.LOSSLESS_HOTKEY  ; Lossless Scaling reacts to its key
            this.ls := !this.ls
    }
    bridgeSend(msg) => this.msgs.Push(msg)
    connected() => this.isConnected
    later(fn, ms) => this.timers[fn] := this.t + ms
    cancel(fn) => this.timers.Has(fn) ? this.timers.Delete(fn) : ""
    losslessActive() => this.ls
    clock() => ""
    setHotkeys(on) => this.hotkeysOn := on

    ; move the fake clock and run the timers that came due
    Advance(ms) {
        this.t += ms
        due := []
        for cb, at in this.timers
            if at <= this.t
                due.Push(cb)
        for cb in due {
            this.timers.Delete(cb)
            cb()
        }
    }
    Sent(type) {
        n := 0
        for m in this.msgs
            n += m.type == type
        return n
    }
    Pressed(keys) {
        n := 0
        for k in this.keys
            n += k == keys
        return n
    }
}

GlueSetup() {
    global State, VideoEnv
    VideoEnv := FakeEnv()
    State.page := "", State.rules := Decide.New(), State.machine := FsMachine.New()
    State.lossless := LosslessPolicy.New(), State.losslessSentAt := 0
    State.lastFsState := "normal", State.pendingExit := false, State.lastGaveUp := ""
    State.foregroundHwnd := 1, State.chromeHwnd := 1, State.videoHotkeys := false
    State.monitorVideo := true, State.bridgeLog := [], State.currentProgram := "chrome.exe"
    return VideoEnv
}

; a state report from the extension: a playing, ready YouTube video on p1
Report(changes := {}) {
    msg := {type: "state", url: "https://www.youtube.com/watch?v=x", site: "youtube", playable: 1, playing: 1,
        ready: 1, isFullscreen: 0, editableFocused: 0, pageId: "p1", leveled: 1}
    for k, v in changes.OwnProps()
        msg.%k% := v
    OnBridgeMessage(msg)
}

; play → arm → F19 → the page reports fullscreen
EnterFullscreen(env) {
    Report()
    OnBridgeMessage({type: "armed", pageId: "p1"})
    env.Advance(1)
    Report({isFullscreen: 1})
}

Test_glue_playing_ready_arms_and_presses_f19() {
    env := GlueSetup()
    Report({ready: 0})
    Assert(env.Sent("armFullscreen") == 0, "not before ready")
    Report()
    Assert(env.Sent("armFullscreen") == 1, "armed once ready")
    OnBridgeMessage({type: "armed", pageId: "p1"})
    env.Advance(1)
    Assert(env.Pressed("{F19}") == 1)
    Assert(env.Pressed("f") == 0, "no stray f")
}

Test_glue_no_f19_into_another_app() {
    env := GlueSetup()
    Report()
    OnBridgeMessage({type: "armed", pageId: "p1"})
    env.fg := "explorer.exe"
    env.Advance(1)
    Assert(env.Pressed("{F19}") == 0)
}

Test_glue_fullscreen_turns_lossless_on_and_keys_on() {
    env := GlueSetup()
    EnterFullscreen(env)
    Assert(State.machine.state == "fullscreen")
    Assert(env.Pressed(CONFIG.LOSSLESS_HOTKEY) == 1 && env.ls, "Lossless on")
    Assert(env.hotkeysOn, "video keys on")
}

Test_glue_esc_exits_lossless_off_and_stays_out() {
    env := GlueSetup()
    EnterFullscreen(env)
    env.Advance(2000)  ; past the Lossless detection hold-off
    _HK_Esc()
    Assert(env.Sent("exitFullscreen") == 1)
    Report({isFullscreen: 0})
    Assert(!env.ls, "Lossless off")
    armed := env.Sent("armFullscreen")
    Report({isFullscreen: 0, url: "https://www.youtube.com/watch?v=x&t=5"})
    env.Advance(250), _VideoTick()
    Assert(env.Sent("armFullscreen") == armed, "no re-entry while still playing")
}

Test_glue_pause_then_play_reenters_after_manual_exit() {
    env := GlueSetup()
    EnterFullscreen(env)
    _HK_Esc()
    Report({isFullscreen: 0})
    Report({playing: 0, ready: 0})
    armed := env.Sent("armFullscreen")
    Report()
    Assert(env.Sent("armFullscreen") == armed + 1)
}

Test_glue_site_button_exit_counts_as_manual() {
    env := GlueSetup()
    EnterFullscreen(env)
    armed := env.Sent("armFullscreen")
    Report({isFullscreen: 0})  ; same page, not requested
    Assert(env.Sent("armFullscreen") == armed)
    Assert(State.rules.manualExit)
}

Test_glue_reload_or_close_tab_is_not_manual() {
    env := GlueSetup()
    EnterFullscreen(env)
    env.Advance(2000)
    armed := env.Sent("armFullscreen")
    Report({isFullscreen: 0, pageId: "p2"})  ; F5 / Ctrl+W: a new page
    Assert(!env.ls, "Lossless off")
    Assert(env.Sent("armFullscreen") == armed + 1, "the new page auto-enters")
}

Test_glue_b_while_playing_exits_once_paused() {
    env := GlueSetup()
    EnterFullscreen(env)
    _HK_b()
    Assert(env.Pressed("{Space}") == 1)
    Assert(env.Sent("exitFullscreen") == 0, "waits for the pause")
    Report({isFullscreen: 1, playing: 0, ready: 0})
    Assert(env.Sent("exitFullscreen") == 1)
}

Test_glue_b_exits_anyway_if_the_site_never_pauses() {
    env := GlueSetup()
    EnterFullscreen(env)
    _HK_b()
    env.Advance(CONFIG.CLICK_EXIT_WAIT_MS)
    Assert(env.Sent("exitFullscreen") == 1)
}

Test_glue_video_click_exits_after_pause() {
    env := GlueSetup()
    EnterFullscreen(env)
    OnBridgeMessage({type: "videoClick"})
    Report({isFullscreen: 1, playing: 0, ready: 0})
    Assert(env.Sent("exitFullscreen") == 1)
}

Test_glue_retry_uses_fskey_but_not_while_typing() {
    env := GlueSetup()
    Report()
    env.Advance(1001), _VideoTick()
    Assert(env.Pressed("f") == 1, "fsKey retry")

    env := GlueSetup()
    Report()
    Report({editableFocused: 1})
    env.Advance(1001), _VideoTick()
    Assert(env.Pressed("f") == 0, "never while typing")
}

Test_glue_reload_mid_fullscreen_no_lossless_toggle() {
    env := GlueSetup()
    env.ls := true  ; the previous AHK turned scaling on
    Report({isFullscreen: 1})
    Assert(State.machine.state == "fullscreen")
    Assert(env.Pressed(CONFIG.LOSSLESS_HOTKEY) == 0)
}

Test_glue_lossless_waits_for_chrome() {
    env := GlueSetup()
    EnterFullscreen(env)
    env.Advance(2000)
    env.fg := "explorer.exe", env.hwnd := 2
    _CheckForeground()
    Report({isFullscreen: 0, pageId: "p2", playing: 0, ready: 0})  ; tab closed while away
    Assert(env.Pressed(CONFIG.LOSSLESS_HOTKEY) == 1, "held back, not sent to another app")
    env.fg := "chrome.exe", env.hwnd := 1
    _CheckForeground()
    Assert(env.Pressed(CONFIG.LOSSLESS_HOTKEY) == 2 && !env.ls, "sent once Chrome is back")
}

Test_glue_typing_and_disconnect_turn_keys_off() {
    env := GlueSetup()
    EnterFullscreen(env)
    Report({isFullscreen: 1, editableFocused: 1})
    Assert(!env.hotkeysOn, "typing")
    Report({isFullscreen: 1})
    Assert(env.hotkeysOn)
    env.isConnected := false
    VideoEvaluate(false)
    Assert(!env.hotkeysOn, "disconnected")
}

Test_glue_seek_and_speed_keys() {
    env := GlueSetup()
    _HK_e()
    _HK_q()
    _HK_Speed("$5")
    Assert(env.msgs[1].type == "seek" && env.msgs[1].by == CONFIG.SEEK_SECONDS)
    Assert(env.msgs[2].by == -CONFIG.SEEK_SECONDS)
    Assert(env.msgs[3].type == "speed" && env.msgs[3].rate == 0.5)
}

Test_glue_manual_lossless_press() {
    env := GlueSetup()
    EnterFullscreen(env)
    _HK_Lossless()
    Assert(!env.ls && !State.lossless.on, "turned off by hand")
}

TESTS.Push(Test_glue_playing_ready_arms_and_presses_f19, Test_glue_no_f19_into_another_app
    , Test_glue_fullscreen_turns_lossless_on_and_keys_on, Test_glue_esc_exits_lossless_off_and_stays_out
    , Test_glue_pause_then_play_reenters_after_manual_exit, Test_glue_site_button_exit_counts_as_manual
    , Test_glue_reload_or_close_tab_is_not_manual, Test_glue_b_while_playing_exits_once_paused
    , Test_glue_b_exits_anyway_if_the_site_never_pauses, Test_glue_video_click_exits_after_pause
    , Test_glue_retry_uses_fskey_but_not_while_typing, Test_glue_reload_mid_fullscreen_no_lossless_toggle
    , Test_glue_lossless_waits_for_chrome, Test_glue_typing_and_disconnect_turn_keys_off
    , Test_glue_seek_and_speed_keys, Test_glue_manual_lossless_press)

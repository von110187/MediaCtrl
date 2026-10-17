; Lib/Decide.ahk: when to enter/exit fullscreen and when the video keys are on.
; Same cases as the Mac version's tests.

Base() {
    return {
        connected: true, monitorOn: true, chromeFocused: true,
        site: "youtube", playable: true, playing: true, ready: true,
        editableFocused: false, fs: "normal", pageId: "p1",
    }
}

; the Lua lesson: an empty/false override must really replace the field
With(changes) {
    inp := Base()
    for k, v in changes.OwnProps()
        inp.%k% := v
    Assert(!changes.HasOwnProp("site") || inp.site == changes.site, "With() didn't overwrite site")
    return inp
}

Test_enter_when_ready_and_playing() {
    a := Decide.Evaluate(Decide.New(), Base(), false)
    Assert(a.enter == true && a.keys == true)
}

Test_no_enter_until_ready() {
    a := Decide.Evaluate(Decide.New(), With({ready: false}), false)
    Assert(a.enter == false)
}

Test_no_enter_while_entering() {
    a := Decide.Evaluate(Decide.New(), With({fs: "entering"}), false)
    Assert(a.enter == false)
}

Test_manual_exit_blocks_reentry() {
    s := Decide.New()
    Decide.OnUnrequestedExit(s, false, "p1")
    a := Decide.Evaluate(s, Base(), false)
    Assert(a.enter == false && a.keys == true)
}

Test_page_change_exit_allows_reentry() {
    s := Decide.New()
    Decide.OnUnrequestedExit(s, true, "p1")
    a := Decide.Evaluate(s, Base(), false)
    Assert(a.enter == true)
}

Test_paused_in_fullscreen_keeps_keys() {
    a := Decide.Evaluate(Decide.New(), With({playing: false, fs: "fullscreen"}), false)
    Assert(a.keys == true && a.exit == false)
}

Test_stopped_not_fullscreen_clears_manual() {
    s := Decide.New()
    Decide.OnUnrequestedExit(s, false, "p1")
    a := Decide.Evaluate(s, With({playing: false, fs: "normal"}), false)
    Assert(a.keys == false && s.manualExit == false)
}

Test_switch_app_keeps_fullscreen() {
    s := Decide.New()
    Decide.OnUnrequestedExit(s, false, "p1")
    a := Decide.Evaluate(s, With({chromeFocused: false, fs: "fullscreen"}), false)
    Assert(a.keys == false && a.exit == false && s.manualExit == true)
}

Test_manual_exit_survives_app_switch() {
    s := Decide.New()
    Decide.OnUnrequestedExit(s, false, "p1")
    Decide.Evaluate(s, With({chromeFocused: false, fs: "normal"}), false)
    a := Decide.Evaluate(s, Base(), false)
    Assert(a.enter == false)
}

Test_manual_exit_survives_tab_switch() {
    s := Decide.New()
    Decide.OnUnrequestedExit(s, false, "p1")
    Decide.Evaluate(s, With({site: "", pageId: "other"}), true)
    a := Decide.Evaluate(s, Base(), false)
    Assert(a.enter == false)
}

Test_manual_exit_only_for_that_page() {
    s := Decide.New()
    Decide.OnUnrequestedExit(s, false, "p1")
    a := Decide.Evaluate(s, With({pageId: "p2"}), false)
    Assert(a.enter == true)
}

Test_leave_page_needs_three_ticks() {
    s := Decide.New()
    inp := With({playable: false, fs: "fullscreen"})
    Assert(Decide.Evaluate(s, inp, true).exit == false)
    Loop 10
        Decide.Evaluate(s, inp, false)
    Assert(Decide.Evaluate(s, inp, true).exit == false)
    a := Decide.Evaluate(s, inp, true)
    Assert(a.exit == true && a.keys == false)
}

Test_monitor_off_disables_all() {
    a := Decide.Evaluate(Decide.New(), With({monitorOn: false}), false)
    Assert(a.keys == false && a.enter == false)
}

Test_editable_focus_turns_keys_off() {
    a := Decide.Evaluate(Decide.New(), With({editableFocused: true, fs: "fullscreen"}), false)
    Assert(a.keys == false && a.exit == false)
}

Test_disconnected_freezes() {
    s := Decide.New()
    Decide.Evaluate(s, With({fs: "fullscreen"}), true)
    inp := With({connected: false, playable: false, fs: "fullscreen"})
    Loop 5 {
        a := Decide.Evaluate(s, inp, true)
        Assert(a.exit == false && a.enter == false)
    }
    Assert(s.notPlayableTicks == 0)
}

; keys off while disconnected: they can't do anything, and Esc should reach
; Chrome itself
Test_disconnected_turns_keys_off() {
    s := Decide.New()
    Assert(Decide.Evaluate(s, With({fs: "fullscreen"}), false).keys == true)
    a := Decide.Evaluate(s, With({connected: false, fs: "fullscreen"}), false)
    Assert(a.keys == false)
}

Test_disconnected_outside_chrome_keys_off() {
    s := Decide.New()
    Decide.Evaluate(s, With({fs: "fullscreen", playing: false}), false)
    a := Decide.Evaluate(s, With({connected: false, chromeFocused: false, fs: "fullscreen"}), false)
    Assert(a.keys == false)
}

TESTS.Push(Test_enter_when_ready_and_playing, Test_no_enter_until_ready, Test_no_enter_while_entering
    , Test_manual_exit_blocks_reentry, Test_page_change_exit_allows_reentry, Test_paused_in_fullscreen_keeps_keys
    , Test_stopped_not_fullscreen_clears_manual, Test_switch_app_keeps_fullscreen, Test_manual_exit_survives_app_switch
    , Test_manual_exit_survives_tab_switch, Test_manual_exit_only_for_that_page, Test_leave_page_needs_three_ticks
    , Test_monitor_off_disables_all, Test_editable_focus_turns_keys_off, Test_disconnected_freezes
    , Test_disconnected_turns_keys_off, Test_disconnected_outside_chrome_keys_off)

; Lib/LosslessPolicy.ahk: scaling follows confirmed fullscreen; manual presses
; only flip the tracked state.

Test_on_when_fullscreen_confirmed() {
    ls := LosslessPolicy.New()
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true) == "toggle")
    Assert(ls.on == true)
}

Test_off_when_fullscreen_ends() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "normal", "p1", true) == "toggle")
    Assert(ls.on == false)
}

Test_manual_off_reenter_is_automatic() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true)
    LosslessPolicy.OnManualPress(ls)
    Assert(ls.on == false)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "normal", "p1", true) == "", "already off")
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true) == "toggle", "same page re-enters: on again")
}

Test_manual_on_turned_off_on_leaving() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true)
    LosslessPolicy.OnManualPress(ls)
    LosslessPolicy.OnManualPress(ls)
    Assert(ls.on == true)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "normal", "p1", true) == "toggle")
    Assert(ls.on == false)
}

Test_next_page_back_to_automatic() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnManualPress(ls)
    LosslessPolicy.OnFullscreenChange(ls, "normal", "p1", true)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p2", true) == "toggle")
}

Test_manual_press_flips_tracked_state() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnManualPress(ls)
    Assert(ls.on == true && ls.pending == "")
}

Test_defer_until_chrome_foreground() {
    ls := LosslessPolicy.New()
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", false) == "")
    Assert(ls.pending != "")
    Assert(LosslessPolicy.OnChromeForeground(ls) == "toggle")
    Assert(ls.on == true)
}

Test_reload_adopt_fullscreen_assumes_on() {
    ls := LosslessPolicy.New()
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true, true) == "")
    Assert(ls.on == true)
}

Test_detected_state_wins() {
    ls := LosslessPolicy.New()
    LosslessPolicy.SetDetected(ls, true)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true) == "")
}

TESTS.Push(Test_on_when_fullscreen_confirmed, Test_off_when_fullscreen_ends, Test_manual_off_reenter_is_automatic
    , Test_manual_on_turned_off_on_leaving, Test_next_page_back_to_automatic
    , Test_manual_press_flips_tracked_state, Test_defer_until_chrome_foreground
    , Test_reload_adopt_fullscreen_assumes_on, Test_detected_state_wins)

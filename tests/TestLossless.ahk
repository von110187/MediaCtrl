; LosslessPolicy: scaling follows confirmed fullscreen, manual presses hand
; that page to the user (design.md "Lossless Scaling").

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

Test_manual_off_stays_off_for_page() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true)
    LosslessPolicy.OnManualPress(ls, "fullscreen", "p1")
    Assert(ls.on == false)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true) == "")
}

Test_manual_page_stays_manual_on_reenter() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true)
    LosslessPolicy.OnManualPress(ls, "fullscreen", "p1")
    Assert(LosslessPolicy.OnFullscreenChange(ls, "normal", "p1", true) == "", "already off")
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p1", true) == "", "re-enter stays manual")
    LosslessPolicy.OnManualPress(ls, "fullscreen", "p1")
    Assert(ls.on == true)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "normal", "p1", true) == "toggle", "off on leaving")
}

Test_next_page_back_to_automatic() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnManualPress(ls, "fullscreen", "p1")
    LosslessPolicy.OnFullscreenChange(ls, "normal", "p1", true)
    Assert(LosslessPolicy.OnFullscreenChange(ls, "fullscreen", "p2", true) == "toggle")
}

Test_manual_outside_fullscreen_left_alone() {
    ls := LosslessPolicy.New()
    LosslessPolicy.OnManualPress(ls, "normal", "p1")
    Assert(ls.on == true && ls.manualPage == "")
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

TESTS.Push(Test_on_when_fullscreen_confirmed, Test_off_when_fullscreen_ends, Test_manual_off_stays_off_for_page
    , Test_manual_page_stays_manual_on_reenter, Test_next_page_back_to_automatic
    , Test_manual_outside_fullscreen_left_alone, Test_defer_until_chrome_foreground
    , Test_reload_adopt_fullscreen_assumes_on, Test_detected_state_wins)

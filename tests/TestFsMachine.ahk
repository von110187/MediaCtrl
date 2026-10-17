; Lib/FsMachine.ahk: fullscreen requests, confirmations, retries and adoption.
; Same cases as the Mac version's tests.

; a machine that has seen one report, so it is past the "fresh" adopt step
Seen(isFullscreen) {
    m := FsMachine.New()
    FsMachine.Report(m, isFullscreen, false, 0)
    return m
}

Test_enter_confirmed() {
    m := Seen(false)
    Assert(FsMachine.Request(m, "enter", 0) == "nudge")
    Assert(m.state == "entering")
    Assert(FsMachine.Report(m, true, false, 200) == "confirmed")
    Assert(m.state == "fullscreen")
}

Test_no_double_request() {
    m := Seen(false)
    FsMachine.Request(m, "enter", 0)
    Assert(FsMachine.Request(m, "enter", 10) == "")
}

Test_enter_failed_uses_fskey() {
    m := Seen(false)
    FsMachine.Request(m, "enter", 0)
    Assert(FsMachine.EnterFailed(m, 100) == "fsKey")
    Assert(FsMachine.Report(m, true, false, 300) == "confirmed")
}

Test_timeout_retry_then_give_up() {
    m := Seen(false)
    FsMachine.Request(m, "enter", 0)
    Assert(FsMachine.Timeout(m, 1001) == "fsKey")
    Assert(FsMachine.Timeout(m, 1500) == "")
    Assert(FsMachine.Timeout(m, 2002) == "gaveUp")
    Assert(m.state == "normal")
}

Test_unrequested_exit() {
    m := Seen(true)
    Assert(FsMachine.Report(m, false, false, 0) == "unrequestedExit")
    Assert(m.state == "normal")
}

Test_unrequested_exit_page_changed() {
    m := Seen(true)
    Assert(FsMachine.Report(m, false, true, 0) == "unrequestedExit")
}

Test_user_entered_via_site_button() {
    m := Seen(false)
    Assert(FsMachine.Report(m, true, false, 0) == "adopted")
    Assert(m.state == "fullscreen")
}

Test_fresh_machine_adopts_fullscreen() {
    m := FsMachine.New()
    Assert(FsMachine.Report(m, true, false, 0) == "")
    Assert(m.state == "fullscreen")
}

Test_exit_confirmed() {
    m := Seen(true)
    Assert(FsMachine.Request(m, "exit", 0) == "exitCmd")
    Assert(FsMachine.Report(m, false, false, 50) == "confirmed")
}

Test_page_switch_cancels_retry() {
    m := Seen(false)
    FsMachine.Request(m, "enter", 0, "p1")
    Assert(FsMachine.Report(m, false, true, 300, "p2") == "cancelled")
    Assert(m.state == "normal")
    Assert(FsMachine.Timeout(m, 1001) == "")
}

Test_same_page_report_keeps_waiting() {
    m := Seen(false)
    FsMachine.Request(m, "enter", 0, "p1")
    Assert(FsMachine.Report(m, false, false, 300, "p1") == "")
    Assert(m.state == "entering")
}

Test_refused_request_keeps_page() {
    m := Seen(false)
    FsMachine.Request(m, "enter", 0, "p1")
    Assert(FsMachine.Request(m, "enter", 10, "p2") == "")
    Assert(FsMachine.Report(m, true, false, 200, "p1") == "confirmed")
}

TESTS.Push(Test_enter_confirmed, Test_no_double_request, Test_enter_failed_uses_fskey, Test_timeout_retry_then_give_up
    , Test_unrequested_exit, Test_unrequested_exit_page_changed, Test_user_entered_via_site_button
    , Test_fresh_machine_adopts_fullscreen, Test_exit_confirmed, Test_page_switch_cancels_retry
    , Test_same_page_report_keeps_waiting, Test_refused_request_keeps_page)

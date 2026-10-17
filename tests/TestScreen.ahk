; Lib/Screen.ahk: which monitor a window is on, and whether a window covers it.

TwoMonitors() => [{l: 0, t: 0, r: 2560, b: 1440}, {l: 2560, t: 0, r: 6400, b: 2160}]

Test_monitor_of_window_center() {
    mons := TwoMonitors()
    Assert(Screen.MonitorOf({x: 100, y: 100, w: 800, h: 600}, mons) == 1)
    Assert(Screen.MonitorOf({x: 2560, y: 0, w: 3840, h: 2160}, mons) == 2, "fullscreen on the second")
}

Test_monitor_of_straddling_window_uses_center() {
    mons := TwoMonitors()
    ; mostly on the second monitor
    Assert(Screen.MonitorOf({x: 2000, y: 0, w: 2000, h: 1000}, mons) == 2)
}

Test_monitor_of_offscreen_falls_back_to_first() {
    Assert(Screen.MonitorOf({x: -9000, y: -9000, w: 10, h: 10}, TwoMonitors()) == 1)
}

Test_covers_needs_most_of_the_monitor() {
    mon := {l: 2560, t: 0, r: 6400, b: 2160}
    Assert(Screen.Covers({x: 2560, y: 0, w: 3840, h: 2160}, mon), "exact")
    Assert(!Screen.Covers({x: 0, y: 0, w: 2560, h: 1440}, mon), "other monitor")
    Assert(!Screen.Covers({x: 2560, y: 0, w: 800, h: 600}, mon), "small window")
}

Test_top_right_position_on_monitor() {
    mon := {l: 2560, t: 0, r: 6400, b: 2160}
    p := Screen.TopRight(mon, 120, 65, 10)
    Assert(p.x == 6400 - 120 - 65 && p.y == 10)
}

TESTS.Push(Test_monitor_of_window_center, Test_monitor_of_straddling_window_uses_center
    , Test_monitor_of_offscreen_falls_back_to_first, Test_covers_needs_most_of_the_monitor
    , Test_top_right_position_on_monitor)

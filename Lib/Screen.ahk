; ============ SCREEN GEOMETRY ============
; Pure module: no Win*/Monitor* calls — callers pass rects in. Rects are
; {x, y, w, h}; monitors are {l, t, r, b} as MonitorGet returns them.

class Screen {
    ; 1-based index of the monitor holding the rect's center; 1 if none does
    static MonitorOf(rect, monitors) {
        cx := rect.x + rect.w / 2, cy := rect.y + rect.h / 2
        for i, m in monitors
            if cx >= m.l && cx < m.r && cy >= m.t && cy < m.b
                return i
        return 1
    }

    ; rect covers at least `share` of the monitor's area
    static Covers(rect, mon, share := 0.9) {
        w := Max(0, Min(rect.x + rect.w, mon.r) - Max(rect.x, mon.l))
        h := Max(0, Min(rect.y + rect.h, mon.b) - Max(rect.y, mon.t))
        area := (mon.r - mon.l) * (mon.b - mon.t)
        return area > 0 && w * h >= area * share
    }

    ; top-left corner for a box of width w, marginRight from the monitor's
    ; right edge and marginTop from its top
    static TopRight(mon, w, marginRight, marginTop) {
        return {x: mon.r - w - marginRight, y: mon.t + marginTop}
    }
}

#Requires AutoHotkey v2.0
#NoTrayIcon
#Warn All, StdOut
; Runs every Test_* function registered in TESTS by the tests/Test*.ahk files.
; Prints "FAIL <name>: <message>" per failure and "N passed, M failed" at the
; end; exits 1 if anything failed. Run from the repo root:
;   & "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut tests\RunTests.ahk

global TESTS := []

Assert(cond, msg := "") {
    if !cond
        throw Error(msg != "" ? msg : "assertion failed", -1)
}

#Include %A_ScriptDir%\..\Lib\Decide.ahk
#Include %A_ScriptDir%\..\Lib\FsMachine.ahk
#Include %A_ScriptDir%\TestDecide.ahk
#Include %A_ScriptDir%\TestFsMachine.ahk

passed := 0, failed := 0
for fn in TESTS {
    try {
        fn()
        passed += 1
    } catch as e {
        failed += 1
        FileAppend("FAIL " fn.Name ": " e.Message " (line " e.Line ")`n", "*")
    }
}
FileAppend(passed " passed, " failed " failed`n", "*")
ExitApp(failed ? 1 : 0)

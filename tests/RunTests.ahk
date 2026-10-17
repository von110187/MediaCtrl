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
#Include %A_ScriptDir%\..\Lib\LosslessPolicy.ahk
#Include %A_ScriptDir%\..\Lib\Screen.ahk
#Include %A_ScriptDir%\..\Lib\Settings.ahk
#Include %A_ScriptDir%\..\Lib\Tone.ahk
#Include %A_ScriptDir%\..\Config.ahk
#Include %A_ScriptDir%\..\State.ahk
#Include %A_ScriptDir%\..\StateEngine.ahk
#Include %A_ScriptDir%\..\Wasapi.ahk
#Include %A_ScriptDir%\..\Speaker.ahk
#Include %A_ScriptDir%\..\Video.ahk
#Include %A_ScriptDir%\TestDecide.ahk
#Include %A_ScriptDir%\TestFsMachine.ahk
#Include %A_ScriptDir%\TestLossless.ahk
#Include %A_ScriptDir%\TestScreen.ahk
#Include %A_ScriptDir%\TestSettings.ahk
#Include %A_ScriptDir%\TestTone.ahk
#Include %A_ScriptDir%\TestVideoGlue.ahk

passed := 0, failed := 0
for fn in TESTS {
    try {
        fn()
        passed += 1
    } catch as testErr {
        failed += 1
        FileAppend("FAIL " fn.Name ": " testErr.Message " (line " testErr.Line ")`n", "*")
    }
}
FileAppend(passed " passed, " failed " failed`n", "*")
ExitApp(failed ? 1 : 0)

; ============ WASAPI SESSIONS ============
; One loop over the default render endpoint's audio sessions, used by the
; Spotify peak meter (Audio.ahk). COM pointers are released in finally
; blocks, so a failing call mid-loop never leaks them.

; Calls callback(sessionControlPtr, pid, procName) for each session whose
; process name contains procMatch. procMatch "" means every session, including
; ones with no process (pid 0) or an unreadable name (procName ""). The
; pointer is only valid during the call. Returns the number of sessions on the
; endpoint, or -1 on failure (with the message in err).
Wasapi_ForEachSession(procMatch, callback, &err := "") {
    global WASAPI_CLSIDS
    devicePtr := 0, managerPtr := 0, sessionEnumPtr := 0
    try {
        enumerator := ComObject(WASAPI_CLSIDS.MMDeviceEnumerator, WASAPI_CLSIDS.IMMDeviceEnumerator)
        ComCall(4, enumerator, "int", 0, "int", 1, "ptr*", &devicePtr)  ; GetDefaultAudioEndpoint(eRender, eMultimedia)

        managerIID := Buffer(16)
        DllCall("Ole32\CLSIDFromString", "Str", WASAPI_CLSIDS.IAudioSessionManager2, "Ptr", managerIID)
        ComCall(3, devicePtr, "ptr", managerIID, "int", 23, "ptr", 0, "ptr*", &managerPtr)  ; Activate
        ComCall(5, managerPtr, "ptr*", &sessionEnumPtr)  ; GetSessionEnumerator
        ComCall(3, sessionEnumPtr, "int*", &count := 0)

        Loop count {
            ComCall(4, sessionEnumPtr, "int", A_Index - 1, "ptr*", &sessionControlPtr := 0)
            try {
                sessionControl2 := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.IAudioSessionControl2)
                if !sessionControl2
                    continue
                ComCall(14, sessionControl2, "uint*", &pid := 0)  ; GetProcessId
                sessionControl2 := ""

                procName := ""
                try procName := ProcessGetName(pid)
                if procMatch != "" && (pid <= 0 || procName = "" || !InStr(procName, procMatch))
                    continue

                callback(sessionControlPtr, pid, procName)
            } finally {
                ObjRelease(sessionControlPtr)
            }
        }
        return count
    } catch as e {
        err := e.Message
        return -1
    } finally {
        if sessionEnumPtr
            ObjRelease(sessionEnumPtr)
        if managerPtr
            ObjRelease(managerPtr)
        if devicePtr
            ObjRelease(devicePtr)
    }
}

; Loudest IAudioMeterInformation peak (0.0-1.0) among the procMatch sessions,
; or -1 on failure / no matching session.
Wasapi_MaxPeak(procMatch) {
    maxPeak := -1
    if Wasapi_ForEachSession(procMatch, Visit) < 0
        return -1
    return maxPeak

    Visit(sessionControlPtr, *) {
        meterInfo := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.IAudioMeterInformation)
        if !meterInfo
            return
        ComCall(3, meterInfo, "float*", &peak := 0.0)  ; GetPeakValue
        if peak > maxPeak
            maxPeak := peak
    }
}

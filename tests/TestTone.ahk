; Lib/Tone.ahk: the keep-awake tone file — a quiet sine with soft edges.

ReadSample(buf, i) => NumGet(buf, 44 + i * 2, "short")

Test_tone_wav_header_and_length() {
    path := A_Temp . "\mediactrl_test_tone.wav"
    Tone.WriteWav(path, 20, -30, 2)
    try {
        buf := FileRead(path, "RAW")
        Assert(StrGet(buf.Ptr, 4, "CP0") == "RIFF" && StrGet(buf.Ptr + 8, 4, "CP0") == "WAVE", "RIFF/WAVE")
        Assert(NumGet(buf, 24, "uint") == Tone.RATE, "sample rate")
        Assert(NumGet(buf, 34, "ushort") == 16, "16-bit")
        Assert(buf.Size == 44 + Tone.RATE * 2 * 2, "2 s mono")
    } finally {
        FileDelete(path)
    }
}

Test_tone_level_and_soft_edges() {
    path := A_Temp . "\mediactrl_test_tone.wav"
    Tone.WriteWav(path, 20, -30, 2)
    try {
        buf := FileRead(path, "RAW")
        n := (buf.Size - 44) // 2
        peak := 0
        Loop n
            peak := Max(peak, Abs(ReadSample(buf, A_Index - 1)))
        expected := Round(32767 * 10 ** (-30 / 20))
        Assert(Abs(peak - expected) <= expected * 0.02, "peak " peak " vs " expected)
        Assert(ReadSample(buf, 0) == 0 && ReadSample(buf, n - 1) == 0, "starts and ends at silence")
        Assert(Abs(ReadSample(buf, 100)) < expected * 0.05, "fades in")
    } finally {
        FileDelete(path)
    }
}

TESTS.Push(Test_tone_wav_header_and_length, Test_tone_level_and_soft_edges)

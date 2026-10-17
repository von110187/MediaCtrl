; ============ TONE ============
; Writes a short sine-wave WAV (16-bit mono PCM) — the speaker keep-awake
; signal (Speaker.ahk). Soft fade in/out, so the tone never starts or stops
; with a click.

class Tone {
    static RATE := 44100
    static FADE_S := 0.25

    ; hz: pitch; db: peak level in dBFS (0 = full scale, -30 = quiet);
    ; seconds: length
    static WriteWav(path, hz, db, seconds) {
        n := Round(Tone.RATE * seconds)
        fadeN := Max(1, Round(Tone.RATE * Min(Tone.FADE_S, seconds / 4)))
        amp := 32767 * 10 ** (db / 20)
        twoPi := 8 * ATan(1)

        buf := Buffer(44 + n * 2, 0)
        StrPut("RIFF", buf.Ptr, 4, "CP0"), NumPut("uint", 36 + n * 2, buf, 4)
        StrPut("WAVE", buf.Ptr + 8, 4, "CP0"), StrPut("fmt ", buf.Ptr + 12, 4, "CP0")
        NumPut("uint", 16, "ushort", 1, "ushort", 1, "uint", Tone.RATE, "uint", Tone.RATE * 2
            , "ushort", 2, "ushort", 16, buf, 16)  ; PCM, mono, 16-bit
        StrPut("data", buf.Ptr + 36, 4, "CP0"), NumPut("uint", n * 2, buf, 40)

        Loop n {
            i := A_Index - 1
            edge := Min(i, n - 1 - i)  ; samples to the nearer end
            env := edge >= fadeN ? 1 : 0.5 * (1 - Cos(twoPi / 2 * edge / fadeN))
            NumPut("short", Round(amp * env * Sin(twoPi * hz * i / Tone.RATE)), buf, 44 + i * 2)
        }
        FileOpen(path, "w").RawWrite(buf)
    }
}

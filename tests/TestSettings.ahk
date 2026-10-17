; Lib/Settings.ahk: per-PC switches from mediactrl_settings.ini, defaults
; for anything missing or unreadable.

SettingsDefaults() => {
    lossless: {enabled: false, hotkey: "{F1}"},
    leveler:  {targetDb: -20},
}

Test_settings_parse_coerces_to_the_default_type() {
    Assert(SettingsFile.Parse("1", false) == true)
    Assert(SettingsFile.Parse("on", false) == true && SettingsFile.Parse("No", true) == false, "words")
    Assert(SettingsFile.Parse("-14", -20) == -14, "numbers")
    Assert(SettingsFile.Parse("{F2}", "{F1}") == "{F2}", "strings as is")
}

Test_settings_parse_falls_back_on_junk() {
    Assert(SettingsFile.Parse("", true) == true, "empty")
    Assert(SettingsFile.Parse("maybe", false) == false, "not a switch value")
    Assert(SettingsFile.Parse("loud", -20) == -20, "not a number")
}

Test_settings_load_missing_file_gives_defaults() {
    s := SettingsFile.Load(A_Temp . "\mediactrl_no_such_settings.ini", SettingsDefaults())
    Assert(s.lossless.enabled == false && s.lossless.hotkey == "{F1}" && s.leveler.targetDb == -20)
}

Test_settings_load_reads_values_and_keeps_the_rest() {
    path := A_Temp . "\mediactrl_test_settings.ini"
    try FileDelete(path)
    FileAppend("[lossless]`nenabled = yes`n`n[leveler]`ntargetDb = loud`n", path)
    try {
        s := SettingsFile.Load(path, SettingsDefaults())
        Assert(s.lossless.enabled == true, "read")
        Assert(s.lossless.hotkey == "{F1}", "missing key → default")
        Assert(s.leveler.targetDb == -20, "junk → default")
        Assert(SettingsDefaults().lossless.enabled == false, "defaults untouched")
    } finally {
        FileDelete(path)
    }
}

TESTS.Push(Test_settings_parse_coerces_to_the_default_type, Test_settings_parse_falls_back_on_junk
    , Test_settings_load_missing_file_gives_defaults, Test_settings_load_reads_values_and_keeps_the_rest)

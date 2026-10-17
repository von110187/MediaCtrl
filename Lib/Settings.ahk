; ============ PER-PC SETTINGS ============
; Reads mediactrl_settings.ini (gitignored, one per PC) over a set of
; defaults. Anything missing, empty or unreadable keeps its default, so a
; typo can't stop the script from starting. The INI is read with Windows'
; profile API: keep it ASCII (or UTF-16, as IniWrite saves it).

class SettingsFile {
    ; defaults: {section: {key: default, ...}, ...}. Returns a new object of
    ; the same shape; the defaults object is left as it is.
    static Load(path, defaults) {
        out := {}
        for section, keys in defaults.OwnProps() {
            values := {}
            for key, def in keys.OwnProps()
                values.%key% := SettingsFile.Parse(Trim(IniRead(path, section, key, "")), def)
            out.%section% := values
        }
        return out
    }

    ; raw text → the default's type. Numbers (incl. switches, which are 1/0)
    ; take digits or on/off words; strings are taken as they are.
    static Parse(raw, def) {
        if raw == ""
            return def
        if !(def is Number)
            return raw
        if IsNumber(raw)
            return Number(raw)
        switch raw, false {
            case "true", "yes", "on":  return true
            case "false", "no", "off": return false
        }
        return def
    }

    ; first run on a PC: start from the template in the repo
    static EnsureFile(path, templatePath) {
        if !FileExist(path) && FileExist(templatePath)
            FileCopy(templatePath, path)
    }
}

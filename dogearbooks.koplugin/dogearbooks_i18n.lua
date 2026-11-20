local gettext = require("gettext")

local directory = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local aliases = {
    af = "af_ZA",
    bg = "bg_BG",
    it = "it_IT",
    ko = "ko_KR",
    lt = "lt_LT",
    nb = "nb_NO",
    nl = "nl_NL",
    pt = "pt_PT",
    zh = "zh_CN",
    zh_HANS = "zh_CN",
    zh_HANT = "zh_TW",
    zh_HK = "zh_TW",
    zh_MO = "zh_TW",
}
local active_language
local messages

local function readCatalog(language)
    local catalog = loadfile(directory .. "l10n/" .. language .. ".lua")
    if catalog then
        local ok, result = pcall(catalog)
        if ok and type(result) == "table" then return result end
    end
end

local function loadCatalog(language)
    if type(language) ~= "string" then return {} end
    language = language:match("^([A-Za-z_%-]+)")
    if not language then return {} end
    language = language:gsub("-", "_")
    local base, region = language:match("^([A-Za-z]+)_([A-Za-z]+)$")
    base = (base or language):lower()
    language = region and (base .. "_" .. region:upper()) or base
    if language == "c" or language == "posix" or language == "en_US" then return {} end
    return readCatalog(aliases[language] or language)
        or (region and readCatalog(aliases[base] or base))
        or {}
end

return function(message)
    -- KOReader resolves the device locale and applies the user's language override.
    -- Some menu options, such as vi_VN, have a catalog under the base language.
    local language = gettext.current_lang
    if not language or language == "C" then
        language = G_reader_settings and G_reader_settings:readSetting("language") or "C"
    end
    if language ~= active_language then
        active_language = language
        messages = loadCatalog(language)
    end
    return messages[message] or gettext(message)
end

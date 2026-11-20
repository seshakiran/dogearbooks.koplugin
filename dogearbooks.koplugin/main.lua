--[[--
dogearbooks plugin for KOReader.

Allows users to swap and resize their digital bookmark (dogear) icon
directly from the Tools menu, without needing a computer.

Custom dogear designs can be placed in either:
    <plugin_folder>/icons/         (legacy bundled icons)
    <koreader_data_dir>/icons/booknookcharms/  (user-added icons)

@module koplugin.dogearbooks
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage"):extend{ stop_events_propagation = true }
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu"):extend{ modal = true, stop_events_propagation = true }
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("dogearbooks_i18n")

local Screen = Device.screen
local auto_pair_reader
local night_mode_patched

-- IconWidget preserves transparency on reader dog-ears, but KOReader assumes
-- icons are monochrome and skips its usual night-mode color correction.
-- Pre-invert only the source pixels so the final screen inversion restores
-- the intended colors without touching the transparent destination area.
local ColorCharmWidget = IconWidget:extend{}

function ColorCharmWidget:_render()
    if self._bb or self.render_failed then return end
    local ok, err = pcall(IconWidget._render, self)
    if ok and self._bb then return end

    logger.warn("dogearbooks: could not load charm", self.file, err)
    self:free()
    if self.fallback_file and self.fallback_file ~= self.file then
        self.file = self.fallback_file
        self.rotation_angle = self.fallback_rotation
        ok, err = pcall(IconWidget._render, self)
        if ok and self._bb then return end
        logger.warn("dogearbooks: could not load fallback charm", self.file, err)
    end
    self:free()
    self.render_failed = true
end

function ColorCharmWidget:getSize()
    self:_render()
    if not self.charm_size then
        self.charm_size = Geom:new{ w = self.width, h = self.height }
    end
    return self.charm_size
end

function ColorCharmWidget:paintTo(bb, x, y)
    self:_render()
    if not self._bb then return end
    local source = Screen.night_mode and self._bb
    if source then source:invert() end
    local ok, err = pcall(IconWidget.paintTo, self, bb, x, y)
    if source then source:invert() end
    if not ok then
        self:free()
        self.render_failed = true
        logger.warn("dogearbooks: could not paint charm", self.file, err)
    end
end

local CharmPreviewWidget = ColorCharmWidget:extend{}

function CharmPreviewWidget:getSize()
    if self.deferred_preview then
        return self.preview_size
    end
    return ColorCharmWidget.getSize(self)
end

function CharmPreviewWidget:paintTo(bb, x, y)
    if not self.deferred_preview or self._bb then
        ColorCharmWidget.paintTo(self, bb, x, y)
    end
end

function CharmPreviewWidget:loadPreview()
    self:_render()
end

function CharmPreviewWidget:_loadfile()
    local RenderImage = require("ui/renderimage")
    -- Preview buffers belong to the dialog and bypass ImageWidget's shared cache.
    if self.file:lower():match("%.svg$") then
        self._bb, self._is_straight_alpha = RenderImage:renderSVGImageFile(self.file, self.width, self.height)
    else
        self._bb = RenderImage:renderImageFile(self.file, false, self.width, self.height)
    end
    if not self._bb then error("could not render charm preview") end
    self._bb_disposable = true
end

local function screenScaleBySize(size)
    if Screen and Screen.scaleBySize then
        return Screen:scaleBySize(size)
    end
    return size
end

local function safeRegisterAction(name, spec)
    if not Dispatcher or not Dispatcher.registerAction then
        logger.warn("dogearbooks: gesture action registration is unavailable on this KOReader build")
        return false
    end
    local ok, err = pcall(function()
        Dispatcher:registerAction(name, spec)
    end)
    if not ok then
        logger.warn("dogearbooks: could not register action", name, err)
    end
    return ok
end

local function safeRegisterMainMenu(plugin)
    if not plugin.ui or not plugin.ui.menu or not plugin.ui.menu.registerToMainMenu then
        logger.warn("dogearbooks: main menu registration is unavailable on this KOReader build")
        return false
    end
    local ok, err = pcall(function()
        plugin.ui.menu:registerToMainMenu(plugin)
    end)
    if not ok then
        logger.warn("dogearbooks: could not register main menu", err)
    end
    return ok
end

-- Preserve existing settings and assigned gestures after the folder rename.
local S_CUSTOM_ICON      = "bookmarkchrome_custom_icon"
local S_CUSTOM_ICON_NAME = "bookmarkchrome_custom_icon_name"
local S_SCALE_FACTOR     = "bookmarkchrome_scale_factor"
local S_MARGIN_TOP       = "bookmarkchrome_margin_top"
local S_MARGIN_RIGHT     = "bookmarkchrome_margin_right"
local S_RECENT_DESIGNS   = "bookmarkchrome_recent_designs"
local S_FAVORITE_DESIGNS = "booknookcharms_favorite_designs"
local S_FAVORITE_INDEX   = "booknookcharms_favorite_index"
local S_DEFAULT_ICON     = "booknookcharms_default_icon"
local S_DEFAULT_ICON_NAME = "booknookcharms_default_icon_name"
local S_DEFAULT_SCALE    = "booknookcharms_default_scale"
local S_DEFAULT_MARGIN_TOP = "booknookcharms_default_margin_top"
local S_DEFAULT_MARGIN_RIGHT = "booknookcharms_default_margin_right"
local S_DAY_PAIR_ICON  = "booknookcharms_day_pair_icon"
local S_DAY_PAIR_NAME  = "booknookcharms_day_pair_name"
local S_DAY_PAIR_SCALE = "booknookcharms_day_pair_scale"
local S_DAY_PAIR_TOP   = "booknookcharms_day_pair_top"
local S_DAY_PAIR_RIGHT = "booknookcharms_day_pair_right"
local S_NIGHT_PAIR_ICON  = "booknookcharms_night_pair_icon"
local S_NIGHT_PAIR_NAME  = "booknookcharms_night_pair_name"
local S_NIGHT_PAIR_SCALE = "booknookcharms_night_pair_scale"
local S_NIGHT_PAIR_TOP   = "booknookcharms_night_pair_top"
local S_NIGHT_PAIR_RIGHT = "booknookcharms_night_pair_right"
local S_AUTO_PAIR_SWITCH = "booknookcharms_auto_pair_switch"
local S_LAST_PAIR_MODE   = "booknookcharms_last_pair_mode"
local S_FIRST_RUN_DEFAULT = "booknookcharms_first_run_default_applied"
local B_CUSTOM_ICON      = "bookmarkchrome_book_icon"
local B_CUSTOM_ICON_NAME = "bookmarkchrome_book_icon_name"
local B_SCALE_FACTOR     = "bookmarkchrome_book_scale"
local B_MARGIN_TOP       = "bookmarkchrome_book_margin_top"
local B_MARGIN_RIGHT     = "bookmarkchrome_book_margin_right"
-- Margin scaling: top and right increments use the same base step size
local MAX_STEPS = 20
local MIN_SCALE = 0.5
local MAX_SCALE = 6.0

local BookmarkChrome = WidgetContainer:extend{
    name = "dogearbooks",
    is_doc_only = false,
}

-- Supported image extensions for dogear designs.
local SUPPORTED_EXTENSIONS = {
    [".png"] = true,
    [".svg"] = true,
    [".alpha"] = true,
    [".bmp"] = true,
    [".jpg"] = true,
    [".jpeg"] = true,
}

local DEFAULT_NEW_SELECTION_SCALE = 4.0
local DEFAULT_RIBBON_RIGHT_STEPS = 5
local DEFAULT_RIBBON_SELECTION_SCALE = 2.5
local FIRST_RUN_DEFAULT_CHARM = "dogear_soft_original.svg"
local PLUGIN_VERSION = "1.6"
local PLUGIN_AUTHOR = "KitanaCode"
local PLUGIN_FORK_AUTHOR = "Wolfazzo"
local PLUGIN_NAME = "dogearbooks"

local function charmStatus(label, status)
    return _(label) .. " · " .. _(status)
end

local function isRibbonDesign(filename)
    return type(filename) == "string" and filename:lower():match("^ribbon_") ~= nil
end

local function isEInkDesign(filename)
    return filename and filename:lower():match("_eink_") ~= nil
end

local function normalizeDesignName(filename)
    if not filename then return nil end
    local name = tostring(filename):match("([^/]+)$") or tostring(filename)
    name = name:gsub("^ribbon_night_public_", "ribbon_night_")
    name = name:gsub("^dogear_night_public_", "dogear_night_")
    name = name:gsub("^ribbon_public_", "ribbon_")
    name = name:gsub("^dogear_public_", "dogear_")
    -- Ignore the extension so saved selections survive compatible artwork changes.
    name = name:gsub("%.[^%.]+$", "")
    return name
end


--- Compute pixel step size for margins based on current screen.
-- Both top and right use the same step so one increment moves equally.
-- @return step_px, step_px
local function getMarginStepSizes()
    local screen_min = math.min(Screen:getWidth(), Screen:getHeight())
    local base = math.max(2, math.ceil(screen_min / 128))
    return base, base
end

--- Convert step count to pixels for top margin.
local function topStepsToPx(steps)
    local top_step = getMarginStepSizes()
    return steps * top_step
end

--- Convert step count to pixels for right margin.
local function rightStepsToPx(steps)
    local _, right_step = getMarginStepSizes()
    return steps * right_step
end

local function clampNumber(value, default, min_value, max_value)
    local number = tonumber(value)
    if not number or number ~= number then return default end
    return math.max(min_value, math.min(max_value, number))
end

function BookmarkChrome:getDataDogearsDir()
    return DataStorage:getDataDir() .. "/icons/booknookcharms/dogears"
end

function BookmarkChrome:getDataCustomIconsDir()
    return DataStorage:getDataDir() .. "/icons/booknookcharms/custom_icons"
end

function BookmarkChrome:getLegacyIconsDir()
    return DataStorage:getDataDir() .. "/icons/bookmarkchrome"
end

function BookmarkChrome:getLegacyDataDogearsDir()
    return DataStorage:getDataDir() .. "/icons/bookmarkchrome/dogears"
end

function BookmarkChrome:getLegacyDataCustomIconsDir()
    return DataStorage:getDataDir() .. "/icons/bookmarkchrome/custom_icons"
end

function BookmarkChrome:getPluginDogearsDir()
    return self.path .. "/dogears"
end

function BookmarkChrome:getPluginCustomIconsDir()
    return self.path .. "/custom_icons"
end

function BookmarkChrome:getPluginLegacyIconsDir()
    return self.path .. "/icons"
end

function BookmarkChrome:getIconsDir()
    return self:getDataCustomIconsDir()
end

function BookmarkChrome:getPluginIconsDir()
    return self:getPluginDogearsDir()
end

function BookmarkChrome:getPluginRibbonsDir()
    return self.path .. "/ribbons"
end

function BookmarkChrome:getPluginNightDir()
    return self.path .. "/night"
end

function BookmarkChrome:getPluginEInkDir()
    return self.path .. "/eink"
end

function BookmarkChrome:getPluginBearsDir()
    return self.path .. "/bears"
end

function BookmarkChrome:getPluginMoviesDir()
    return self.path .. "/Movies"
end

function BookmarkChrome:getDataRibbonsDir()
    return DataStorage:getDataDir() .. "/icons/booknookcharms/ribbons"
end

function BookmarkChrome:getDataNightDir()
    return DataStorage:getDataDir() .. "/icons/booknookcharms/night"
end

function BookmarkChrome:getDataEInkDir()
    return DataStorage:getDataDir() .. "/icons/booknookcharms/eink"
end

function BookmarkChrome:getLegacyDataRibbonsDir()
    return DataStorage:getDataDir() .. "/icons/bookmarkchrome/ribbons"
end

function BookmarkChrome:getLegacyDataNightDir()
    return DataStorage:getDataDir() .. "/icons/bookmarkchrome/night"
end

function BookmarkChrome:getLegacyDataEInkDir()
    return DataStorage:getDataDir() .. "/icons/bookmarkchrome/eink"
end

local NON_PACK_FOLDERS = { l10n = true, screenshots = true, sheet = true, templates = true }

local function scanDir(dir, list, seen, folders, excluded_folders)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for entry in iter, dir_obj do
        if entry:sub(1, 1) ~= "." then
            local ext = entry:match("(%.[^%.]+)$")
            local want_image = list and ext and SUPPORTED_EXTENSIONS[ext:lower()] and not seen[entry]
            local want_folder = folders and not (excluded_folders and excluded_folders[entry])
            if want_image or want_folder then
                local path = dir .. "/" .. entry
                local mode = lfs.symlinkattributes(path, "mode")
                if mode == "directory" and want_folder then
                    folders[#folders + 1] = path
                elseif want_image and (mode == "file"
                        or (mode == "link" and lfs.attributes(path, "mode") == "file")) then
                    seen[entry] = true
                    list[#list + 1] = { text = entry, path = path }
                end
            end
        end
    end
end

local function sortDesigns(designs)
    table.sort(designs, function(a, b)
        local ar, br = isRibbonDesign(a.text), isRibbonDesign(b.text)
        if ar ~= br then return not ar end
        return a.text < b.text
    end)
end

function BookmarkChrome:getDataPacksDir()
    return DataStorage:getDataDir() .. "/icons/booknookcharms"
end

function BookmarkChrome:scanDesigns()
    local designs, seen, scanned, pending = {}, {}, {}, {}
    local function scan(path, excluded_folders)
        if scanned[path] then return end
        scanned[path] = true
        scanDir(path, designs, seen, pending, excluded_folders)
    end

    -- Preserve the priority of existing assets when filenames collide.
    for _, path in ipairs({
        self:getPluginEInkDir(), self:getPluginDogearsDir(), self:getPluginRibbonsDir(),
        self:getPluginNightDir(), self:getPluginBearsDir(), self:getPluginMoviesDir(),
        self:getDataEInkDir(), self:getPluginCustomIconsDir(), self:getDataDogearsDir(),
        self:getDataRibbonsDir(), self:getDataNightDir(), self:getDataCustomIconsDir(),
        self:getLegacyDataEInkDir(), self:getLegacyDataDogearsDir(), self:getLegacyDataRibbonsDir(),
        self:getLegacyDataNightDir(), self:getLegacyDataCustomIconsDir(),
        self:getPluginLegacyIconsDir(), self:getLegacyIconsDir(),
    }) do
        scan(path)
    end
    scan(self.path, NON_PACK_FOLDERS)
    scan(self:getDataPacksDir())
    local index = 1
    while index <= #pending do
        scan(pending[index])
        index = index + 1
    end
    sortDesigns(designs)
    return designs
end

function BookmarkChrome:applyDogearToLive()
    local view = self.ui and self.ui.view
    local dogear_widget = view and view.dogear
    if not dogear_widget then return end

    local old_region = view.dogear_visible and dogear_widget:getRefreshRegion()
    old_region = old_region and old_region:copy()
    dogear_widget:setupDogear()
    dogear_widget:resetLayout()
    if view.dogear_visible then
        UIManager:setDirty(view.dialog or self.ui.dialog or self.ui, function()
            local region = dogear_widget:getRefreshRegion()
            if old_region and region then
                return "ui", old_region:combine(region)
            end
            region = region or old_region
            if region then return "ui", region end
        end)
    end
end

--- Reset all dogear settings to defaults.
function BookmarkChrome:resetAll()
    local default_icon = G_reader_settings:readSetting(S_DEFAULT_ICON)
    local default_name = G_reader_settings:readSetting(S_DEFAULT_ICON_NAME)
    local resolved_name, resolved_path = self:resolveSavedDesign(default_icon, default_name)

    if resolved_path and resolved_name then
        G_reader_settings:saveSetting(S_DEFAULT_ICON, resolved_path)
        G_reader_settings:saveSetting(S_DEFAULT_ICON_NAME, resolved_name)
        G_reader_settings:saveSetting(S_CUSTOM_ICON, resolved_path)
        G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, resolved_name)
        G_reader_settings:saveSetting(S_SCALE_FACTOR, G_reader_settings:readSetting(S_DEFAULT_SCALE) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_SELECTION_SCALE or DEFAULT_NEW_SELECTION_SCALE))
        G_reader_settings:saveSetting(S_MARGIN_TOP, G_reader_settings:readSetting(S_DEFAULT_MARGIN_TOP) or 0)
        G_reader_settings:saveSetting(S_MARGIN_RIGHT, G_reader_settings:readSetting(S_DEFAULT_MARGIN_RIGHT) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_RIGHT_STEPS or 0))
    else
        if default_icon or default_name then
            G_reader_settings:delSetting(S_DEFAULT_ICON)
            G_reader_settings:delSetting(S_DEFAULT_ICON_NAME)
            G_reader_settings:delSetting(S_DEFAULT_SCALE)
            G_reader_settings:delSetting(S_DEFAULT_MARGIN_TOP)
            G_reader_settings:delSetting(S_DEFAULT_MARGIN_RIGHT)
        end
        G_reader_settings:delSetting(S_CUSTOM_ICON)
        G_reader_settings:delSetting(S_CUSTOM_ICON_NAME)
        G_reader_settings:saveSetting(S_SCALE_FACTOR, DEFAULT_NEW_SELECTION_SCALE)
        G_reader_settings:saveSetting(S_MARGIN_TOP, 0)
        G_reader_settings:saveSetting(S_MARGIN_RIGHT, 0)
    end
    self:applyDogearToLive()
end

function BookmarkChrome:findDesignByName(filename, designs)
    local target = normalizeDesignName(filename)
    if not target then return end
    designs = designs or self:scanDesigns()

    for __, design in ipairs(designs) do
        if design.text == filename or normalizeDesignName(design.text) == target then
            return design
        end
    end
end

function BookmarkChrome:resolveSavedDesign(saved_path, saved_name, designs)
    if type(saved_path) == "string" then
        local legacy_relative = ("/" .. saved_path):match("/booknookcharms%.koplugin/(.+)$")
        if legacy_relative then
            local moved_path = self.path .. "/" .. legacy_relative
            if lfs.attributes(moved_path, "mode") == "file" then
                return saved_name or moved_path:match("([^/]+)$"), moved_path, true
            end
        end
        if lfs.attributes(saved_path, "mode") == "file" then
            return saved_name or saved_path:match("([^/]+)$"), saved_path, not saved_name
        end
    end

    local design = self:findDesignByName(saved_name or saved_path, designs)
    if design then
        return design.text, design.path, true
    end
end


function BookmarkChrome:pushRecent(filename)
    if not filename then return end
    local recent = G_reader_settings:readSetting(S_RECENT_DESIGNS) or {}
    local out = { filename }
    for __, item in ipairs(recent) do
        if item ~= filename and #out < 8 then
            table.insert(out, item)
        end
    end
    G_reader_settings:saveSetting(S_RECENT_DESIGNS, out)
end

function BookmarkChrome:applyLook(filename, full_path, scale, mt, mr, remember_recent, message)
    if not filename or not full_path then return end
    G_reader_settings:saveSetting(S_CUSTOM_ICON, full_path)
    G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, filename)
    G_reader_settings:saveSetting(S_SCALE_FACTOR, scale or DEFAULT_NEW_SELECTION_SCALE)
    G_reader_settings:saveSetting(S_MARGIN_TOP, mt or 0)
    G_reader_settings:saveSetting(S_MARGIN_RIGHT, mr or (isRibbonDesign(filename) and DEFAULT_RIBBON_RIGHT_STEPS or 0))
    if remember_recent ~= false then
        self:pushRecent(filename)
    end
    self:applyDogearToLive()
    if message then
        UIManager:show(InfoMessage:new{ text = message, timeout = 2 })
    end
end

function BookmarkChrome:saveCurrentCharmPath()
    local name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    local icon = G_reader_settings:readSetting(S_CUSTOM_ICON)
    if not name and not icon then return end

    local resolved_name, resolved_path, repaired = self:resolveSavedDesign(icon, name)
    if resolved_name and resolved_path and repaired then
        G_reader_settings:saveSetting(S_CUSTOM_ICON, resolved_path)
        G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, resolved_name)
    end
end

function BookmarkChrome:applyFirstRunDefault()
    if G_reader_settings:readSetting(S_FIRST_RUN_DEFAULT) then return false end
    if G_reader_settings:readSetting(S_CUSTOM_ICON) or G_reader_settings:readSetting(S_CUSTOM_ICON_NAME) then
        G_reader_settings:saveSetting(S_FIRST_RUN_DEFAULT, true)
        return false
    end

    local design = self:findDesignByName(FIRST_RUN_DEFAULT_CHARM)
    if not design then
        G_reader_settings:saveSetting(S_FIRST_RUN_DEFAULT, true)
        return false
    end

    self:applyLook(design.text, design.path, DEFAULT_NEW_SELECTION_SCALE, 0, 0, false)
    G_reader_settings:saveSetting(S_DEFAULT_ICON, design.path)
    G_reader_settings:saveSetting(S_DEFAULT_ICON_NAME, design.text)
    G_reader_settings:saveSetting(S_DEFAULT_SCALE, DEFAULT_NEW_SELECTION_SCALE)
    G_reader_settings:saveSetting(S_DEFAULT_MARGIN_TOP, 0)
    G_reader_settings:saveSetting(S_DEFAULT_MARGIN_RIGHT, 0)
    G_reader_settings:saveSetting(S_FIRST_RUN_DEFAULT, true)
    return true
end

function BookmarkChrome:applyDesign(filename, full_path)
    local is_ribbon = isRibbonDesign(filename)
    local scale = G_reader_settings:readSetting(S_SCALE_FACTOR)
        or G_reader_settings:readSetting(S_DEFAULT_SCALE)
        or (is_ribbon and DEFAULT_RIBBON_SELECTION_SCALE or DEFAULT_NEW_SELECTION_SCALE)
    local top = G_reader_settings:readSetting(S_MARGIN_TOP)
        or G_reader_settings:readSetting(S_DEFAULT_MARGIN_TOP)
    local right = G_reader_settings:readSetting(S_MARGIN_RIGHT)
        or G_reader_settings:readSetting(S_DEFAULT_MARGIN_RIGHT)
    local label = is_ribbon and "Ribbon" or "Corner"

    self:applyLook(filename, full_path, scale, top, right, true, charmStatus(label, "Applied"))
end

function BookmarkChrome:applyOriginalCorner(message)
    local design = self:findDesignByName(FIRST_RUN_DEFAULT_CHARM)
    if design then
        self:applyLook(design.text, design.path, DEFAULT_NEW_SELECTION_SCALE, 0, 0, false, message)
        return true
    end

    G_reader_settings:delSetting(S_CUSTOM_ICON)
    G_reader_settings:delSetting(S_CUSTOM_ICON_NAME)
    G_reader_settings:saveSetting(S_SCALE_FACTOR, DEFAULT_NEW_SELECTION_SCALE)
    G_reader_settings:saveSetting(S_MARGIN_TOP, 0)
    G_reader_settings:saveSetting(S_MARGIN_RIGHT, 0)
    self:applyDogearToLive()
    if message then
        UIManager:show(InfoMessage:new{ text = message, timeout = 2 })
    end
    return false
end

function BookmarkChrome:saveCurrentLookToBook()
    local ds = self.ui and self.ui.doc_settings
    if not ds then return end
    self:saveCurrentCharmPath()
    ds:saveSetting(B_CUSTOM_ICON, G_reader_settings:readSetting(S_CUSTOM_ICON))
    ds:saveSetting(B_CUSTOM_ICON_NAME, G_reader_settings:readSetting(S_CUSTOM_ICON_NAME))
    ds:saveSetting(B_SCALE_FACTOR, G_reader_settings:readSetting(S_SCALE_FACTOR) or DEFAULT_NEW_SELECTION_SCALE)
    ds:saveSetting(B_MARGIN_TOP, G_reader_settings:readSetting(S_MARGIN_TOP) or 0)
    ds:saveSetting(B_MARGIN_RIGHT, G_reader_settings:readSetting(S_MARGIN_RIGHT) or 0)
    UIManager:show(InfoMessage:new{ text = charmStatus("This Book", "Saved"), timeout = 2 })
end

function BookmarkChrome:applyBookLook(show_message)
    local ds = self.ui and self.ui.doc_settings
    if not ds then return false end
    local icon = ds:readSetting(B_CUSTOM_ICON)
    local name = ds:readSetting(B_CUSTOM_ICON_NAME)
    local resolved_name, resolved_path, repaired = self:resolveSavedDesign(icon, name)
    if resolved_name and resolved_path then
        if repaired then
            ds:saveSetting(B_CUSTOM_ICON, resolved_path)
            ds:saveSetting(B_CUSTOM_ICON_NAME, resolved_name)
        end
        self:applyLook(resolved_name, resolved_path,
            ds:readSetting(B_SCALE_FACTOR) or DEFAULT_NEW_SELECTION_SCALE,
            ds:readSetting(B_MARGIN_TOP) or 0,
            ds:readSetting(B_MARGIN_RIGHT) or 0,
            false,
            show_message and charmStatus("This Book", "Restored") or nil)
        return true
    end
    if icon or name then
        self:resetThisBook(false)
        if show_message then
            UIManager:show(InfoMessage:new{ text = charmStatus("This Book", "Missing"), timeout = 2 })
        end
        return false
    end
    if show_message then
        UIManager:show(InfoMessage:new{ text = charmStatus("This Book", "Not saved"), timeout = 2 })
    end
    return false
end

function BookmarkChrome:resetThisBook(show_message)
    local ds = self.ui and self.ui.doc_settings
    if not ds then return end
    ds:delSetting(B_CUSTOM_ICON)
    ds:delSetting(B_CUSTOM_ICON_NAME)
    ds:delSetting(B_SCALE_FACTOR)
    ds:delSetting(B_MARGIN_TOP)
    ds:delSetting(B_MARGIN_RIGHT)
    if show_message ~= false then
        UIManager:show(InfoMessage:new{ text = charmStatus("This Book", "Removed"), timeout = 2 })
    end
end


function BookmarkChrome:setCurrentLookAsDefault()
    local icon = G_reader_settings:readSetting(S_CUSTOM_ICON)
    local name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    local resolved_name, resolved_path = self:resolveSavedDesign(icon, name)

    if not resolved_path or not resolved_name then
        UIManager:show(InfoMessage:new{ text = charmStatus("Current Charm", "None"), timeout = 2 })
        return
    end

    G_reader_settings:saveSetting(S_CUSTOM_ICON, resolved_path)
    G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, resolved_name)
    G_reader_settings:saveSetting(S_DEFAULT_ICON, resolved_path)
    G_reader_settings:saveSetting(S_DEFAULT_ICON_NAME, resolved_name)
    G_reader_settings:saveSetting(S_DEFAULT_SCALE, G_reader_settings:readSetting(S_SCALE_FACTOR) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_SELECTION_SCALE or DEFAULT_NEW_SELECTION_SCALE))
    G_reader_settings:saveSetting(S_DEFAULT_MARGIN_TOP, G_reader_settings:readSetting(S_MARGIN_TOP) or 0)
    G_reader_settings:saveSetting(S_DEFAULT_MARGIN_RIGHT, G_reader_settings:readSetting(S_MARGIN_RIGHT) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_RIGHT_STEPS or 0))

    UIManager:show(InfoMessage:new{ text = charmStatus("Default", "Saved") .. " ✧", timeout = 2 })
end


function BookmarkChrome:getFavoriteDesigns()
    local favorites = G_reader_settings:readSetting(S_FAVORITE_DESIGNS)
    return type(favorites) == "table" and favorites or {}
end

function BookmarkChrome:resolveFavoriteDesigns(favorites)
    local resolved, designs = {}, nil
    for index, entry in ipairs(favorites) do
        if type(entry) == "string" then
            local path = entry:find("/", 1, true) and entry or nil
            if path and lfs.attributes(path, "mode") == "file" then
                resolved[index] = { text = path:match("([^/]+)$"), path = path }
            else
                -- Older favorites stored only the filename. Resolve those
                -- against the same catalog used for restoring saved looks.
                designs = designs or self:scanDesigns()
                local name, resolved_path = self:resolveSavedDesign(path, not path and entry or nil, designs)
                if resolved_path then
                    resolved[index] = { text = name, path = resolved_path }
                end
            end
        end
    end
    return resolved
end

function BookmarkChrome:getFavoritePaths()
    local favorite_paths = {}
    for _, design in pairs(self:resolveFavoriteDesigns(self:getFavoriteDesigns())) do
        favorite_paths[design.path] = true
    end
    return favorite_paths
end

function BookmarkChrome:updateFavorite(design, wanted)
    local favorites = self:getFavoriteDesigns()
    local resolved = self:resolveFavoriteDesigns(favorites)
    local exists = false
    for _, favorite in pairs(resolved) do
        if favorite.path == design.path then
            exists = true
            break
        end
    end

    if wanted == nil then wanted = not exists end
    if wanted == exists then return false end

    for index, favorite in pairs(resolved) do
        favorites[index] = favorite.path
    end
    if wanted then
        table.insert(favorites, 1, design.path)
        while #favorites > 20 do table.remove(favorites) end
    else
        for index = #favorites, 1, -1 do
            if resolved[index] and resolved[index].path == design.path then
                table.remove(favorites, index)
            end
        end
    end
    G_reader_settings:saveSetting(S_FAVORITE_DESIGNS, favorites)
    G_reader_settings:saveSetting(S_FAVORITE_INDEX, 0)
    return true
end

function BookmarkChrome:getCurrentFavoriteDesign()
    local path = G_reader_settings:readSetting(S_CUSTOM_ICON)
    local name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    local text, resolved_path = self:resolveSavedDesign(path, name)
    if resolved_path then return { text = text, path = resolved_path } end
    UIManager:show(InfoMessage:new{ text = charmStatus("Current Charm", "None"), timeout = 2 })
end

function BookmarkChrome:addCurrentToFavorites()
    local design = self:getCurrentFavoriteDesign()
    if not design then return end
    local status = self:updateFavorite(design, true) and "Saved" or "Already saved"
    UIManager:show(InfoMessage:new{ text = charmStatus("Favorites", status) .. " ⭐", timeout = 2 })
end

function BookmarkChrome:removeCurrentFromFavorites()
    local design = self:getCurrentFavoriteDesign()
    if not design then return end
    local status = self:updateFavorite(design, false) and "Removed" or "Not saved"
    UIManager:show(InfoMessage:new{ text = charmStatus("Favorites", status), timeout = 2 })
end

function BookmarkChrome:clearFavorites()
    G_reader_settings:saveSetting(S_FAVORITE_DESIGNS, {})
    G_reader_settings:saveSetting(S_FAVORITE_INDEX, 0)
    UIManager:show(InfoMessage:new{ text = charmStatus("Favorites", "Removed"), timeout = 2 })
end

function BookmarkChrome:applyNextFavoriteCharm()
    local favorites = self:getFavoriteDesigns()
    if #favorites == 0 then
        UIManager:show(InfoMessage:new{ text = _("No favorites yet"), timeout = 2 })
        return false
    end

    local resolved = self:resolveFavoriteDesigns(favorites)
    local start = G_reader_settings:readSetting(S_FAVORITE_INDEX) or 0
    for step = 1, #favorites do
        local index = ((start + step - 1) % #favorites) + 1
        local design = resolved[index]
        if design then
            G_reader_settings:saveSetting(S_FAVORITE_INDEX, index)
            self:applyDesign(design.text, design.path)
            return true
        end
    end

    UIManager:show(InfoMessage:new{ text = charmStatus("Favorites", "Missing"), timeout = 2 })
    return false
end

function BookmarkChrome:pruneMissingFavorites(show_message)
    local favorites = self:getFavoriteDesigns()
    local resolved = self:resolveFavoriteDesigns(favorites)
    local out = {}
    for i = 1, #favorites do
        if resolved[i] then out[#out + 1] = resolved[i].path end
    end
    local removed = #favorites - #out
    if removed > 0 then
        G_reader_settings:saveSetting(S_FAVORITE_DESIGNS, out)
        G_reader_settings:saveSetting(S_FAVORITE_INDEX, 0)
    end
    if show_message then
        local text = removed > 0
            and charmStatus("Favorites", "Updated")
            or charmStatus("Remove Missing Favorites", "None")
        UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
    end
    return removed
end

local function setButtonPreview(button, path, size, deferred)
    local preview = CharmPreviewWidget:new{
        file = path,
        width = size,
        height = size,
        alpha = true,
        fallback_file = "resources/icons/icon-not-found.svg",
        deferred_preview = deferred,
        preview_size = deferred and Geom:new{ w = size, h = size } or nil,
    }
    button.label_widget:free()
    button.label_container[1] = preview
    button.label_widget = preview
    return preview
end

function BookmarkChrome:showGallery(title, designs, action, select, selected_index, empty_message)
    require("dogearbooks_gallery"){
        title = title,
        designs = designs,
        action = action,
        set_preview = setButtonPreview,
        select = select or function(design) self:applyDesign(design.text, design.path) end,
        favorite_paths = function() return self:getFavoritePaths() end,
        toggle_favorite = function(design) self:updateFavorite(design) end,
        selected_index = selected_index,
        empty_message = empty_message or _("No charms found"),
    }
end

function BookmarkChrome:showDesignMenu()
    self:showGallery(_("Charm Library"), self:scanDesigns(), {
        text = _("Restore Original Corner"),
        callback = function()
            self:resetAll()
            UIManager:show(InfoMessage:new{ text = charmStatus("Default", "Restored"), timeout = 2 })
        end,
    })
end

function BookmarkChrome:buildFolderItems(folders)
    table.sort(folders)
    local items = {}
    for _, path in ipairs(folders) do
        local title = path:match("([^/]+)$")
        items[#items + 1] = {
            text = title,
            keep_menu_open = true,
            callback = function() self:showFolderGallery(path, title) end,
        }
    end
    if #items == 0 then
        items[1] = { text = _("No charms found"), enabled = false }
    end
    return items
end

function BookmarkChrome:buildPackFolderItems()
    local folders = {}
    scanDir(self.path, nil, nil, folders, NON_PACK_FOLDERS)
    for _, path in ipairs({ self:getDataPacksDir(), self:getLegacyIconsDir() }) do
        if lfs.attributes(path, "mode") == "directory" then
            folders[#folders + 1] = path
        end
    end
    return self:buildFolderItems(folders)
end

function BookmarkChrome:showPackFolderMenu(title, items)
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    function menu:onMenuSelect(item)
        if item.keep_menu_open and item.callback then
            self:onMenuChoice(item)
            return true
        end
        return Menu.onMenuSelect(self, item)
    end
    UIManager:show(menu)
end

function BookmarkChrome:showFolderGallery(path, title)
    local designs, folders = {}, {}
    scanDir(path, designs, {}, folders)
    sortDesigns(designs)
    local function openSubfolders()
        self:showPackFolderMenu(title, self:buildFolderItems(folders))
    end
    if #folders > 0 and #designs == 0 then
        openSubfolders()
        return
    end
    self:showGallery(title, designs, #folders > 0 and {
        text = _("Folders"),
        callback = openSubfolders,
    } or nil)
end

function BookmarkChrome:buildFavoriteFolderItems()
    local items = self:buildPackFolderItems()
    table.insert(items, 1, {
        text = _("Saved Favorites"),
        keep_menu_open = true,
        callback = function() self:showSavedFavoriteGallery() end,
    })
    return items
end

function BookmarkChrome:showFavoriteLooksMenu()
    self:showPackFolderMenu(_("Favorites"), self:buildFavoriteFolderItems())
end

function BookmarkChrome:showSavedFavoriteGallery()
    local saved = self:getFavoriteDesigns()
    local resolved = self:resolveFavoriteDesigns(saved)
    local favorites, missing = {}, false
    for i = 1, #saved do
        local design = resolved[i]
        if design then
            favorites[#favorites + 1] = design
        else
            missing = true
        end
    end

    local function manageFavorites()
        local items = {
            { text = _("Add Current Charm"), callback = function() self:addCurrentToFavorites() end },
            { text = _("Remove Current Charm"), callback = function() self:removeCurrentFromFavorites() end },
            { text = _("Next Favorite Charm"), callback = function() self:applyNextFavoriteCharm() end },
            { text = _("Clear Favorite Charms"), callback = function() self:clearFavorites() end },
        }
        if missing then
            items[#items + 1] = {
                text = _("Remove Missing Favorites"),
                callback = function() self:pruneMissingFavorites(true) end,
            }
        end
        local menu
        menu = Menu:new{
            title = _("Favorites"),
            item_table = items,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
            close_callback = function() UIManager:close(menu) end,
        }
        UIManager:show(menu)
    end

    self:showGallery(_("Saved Favorites"), favorites, {
        text = _("Manage Charms"),
        callback = manageFavorites,
    }, nil, nil, _("No favorites yet"))
end

--- Build a section label widget, left-aligned.
local function sectionLabel(text, inner_w)
    return LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = screenScaleBySize(28) },
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont", 17),
            bold = true,
        },
    }
end

--- Build a horizontal separator line.
local function separator(inner_w)
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = Size.line.medium },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.medium },
            background = Blitbuffer.COLOR_GRAY,
        },
    }
end

--- Build a framed value display box (makes value fields visually distinct).
local function valueBox(text_widget, box_w, box_h)
    local b = Size.border.default
    return FrameContainer:new{
        bordersize = b,
        radius     = Size.radius.button,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = box_w - b * 2, h = box_h - b * 2 },
            text_widget,
        },
    }
end

local StudioControl = Button:extend{}

function StudioControl:onTapSelectButton()
    if self.enabled then self.callback() end
    return true
end

function BookmarkChrome:showSizeSlider(scale, mt_steps, mr_steps, icon_idx, designs)
    scale = clampNumber(scale or G_reader_settings:readSetting(S_SCALE_FACTOR), 1, MIN_SCALE, MAX_SCALE)
    scale = math.floor(scale * 10 + 0.5) / 10
    mt_steps = clampNumber(mt_steps or G_reader_settings:readSetting(S_MARGIN_TOP), 0, 0, MAX_STEPS)
    mr_steps = clampNumber(mr_steps or G_reader_settings:readSetting(S_MARGIN_RIGHT), 0, 0, MAX_STEPS)

    local originals = {
        scale     = G_reader_settings:readSetting(S_SCALE_FACTOR) or 1,
        mt        = G_reader_settings:readSetting(S_MARGIN_TOP)   or 0,
        mr        = G_reader_settings:readSetting(S_MARGIN_RIGHT) or 0,
        icon      = G_reader_settings:readSetting(S_CUSTOM_ICON),
        icon_name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME),
    }

    -- Take one snapshot for this editor session.
    if not designs then
        designs = self:scanDesigns()
    end
    if icon_idx == nil then
        local saved_icon = G_reader_settings:readSetting(S_CUSTOM_ICON)
        local saved_name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
        icon_idx = 0
        if saved_icon or saved_name then
            for i, d in ipairs(designs) do
                if d.path == saved_icon or normalizeDesignName(d.text) == normalizeDesignName(saved_name) then
                    icon_idx = i
                    break
                end
            end
        end
    end
    -- Clamp icon_idx in case designs changed
    icon_idx = math.max(0, math.min(icon_idx, #designs))

    -- Apply values to settings and update the live dog ear behind the modal
    local function applyLivePreview(ns, nmt, nmr, ni)
        G_reader_settings:saveSetting(S_SCALE_FACTOR, ns)
        G_reader_settings:saveSetting(S_MARGIN_TOP,   nmt)
        G_reader_settings:saveSetting(S_MARGIN_RIGHT, nmr)
        local ni_path = (ni > 0 and designs[ni]) and designs[ni].path or nil
        local ni_name = (ni > 0 and designs[ni]) and designs[ni].text or nil
        if ni_path then
            G_reader_settings:saveSetting(S_CUSTOM_ICON,      ni_path)
            G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, ni_name)
        else
            G_reader_settings:delSetting(S_CUSTOM_ICON)
            G_reader_settings:delSetting(S_CUSTOM_ICON_NAME)
        end
        self:applyDogearToLive()
    end

    -- Layout dimensions
    local dialog_w  = math.floor(Screen:getWidth() * 0.90)
    local pad       = Size.padding.large
    local inner_w   = dialog_w - pad * 2
    local hspan     = Size.span.horizontal_default
    local vspan_sm  = Size.span.vertical_default
    local vspan_lg  = Size.span.vertical_default * 2
    local btn_h     = screenScaleBySize(52)

    local function scaleText(value)
        return string.format("%.1f×", value)
    end
    local scale_value = TextWidget:new{
        text = scaleText(scale),
        face = Font:getFace("cfont", 24),
        bold = true,
    }
    local top_value, right_value
    local top_widget, dialog_frame, preview_btn

    local function updateCharmPreview()
        local design = designs[icon_idx]
        setButtonPreview(preview_btn, design and design.path or "resources/icons/mdlight/dogear.alpha.svg", btn_h)
    end

    local function updatePreview(ns, nmt, nmr, ni)
        if ns == scale and nmt == mt_steps and nmr == mr_steps and ni == icon_idx then return end
        if ns ~= scale then scale_value:setText(scaleText(ns)) end
        if nmt ~= mt_steps then top_value:setText(tostring(nmt), top_value.width) end
        if nmr ~= mr_steps then right_value:setText(tostring(nmr), right_value.width) end
        local charm_changed = ni ~= icon_idx
        scale, mt_steps, mr_steps, icon_idx = ns, nmt, nmr, ni
        if charm_changed then updateCharmPreview() end
        applyLivePreview(scale, mt_steps, mr_steps, icon_idx)
        UIManager:setDirty(top_widget, "ui", dialog_frame.dimen)
    end

    -- === DESIGN section ===
    local icon_btn_w = math.floor(inner_w * 0.18)
    preview_btn = Button:new{
        text = "",
        width = inner_w - icon_btn_w * 2 - hspan * 2,
        height = btn_h,
        callback = function()
            self:showGallery(_("Choose a Charm"), designs, {
                text = _("Restore Original Corner"),
                callback = function() updatePreview(scale, mt_steps, mr_steps, 0) end,
            }, function(_, index)
                updatePreview(scale, mt_steps, mr_steps, index)
            end, icon_idx)
        end,
    }
    updateCharmPreview()

    local icon_row = HorizontalGroup:new{
        align = "center",
        StudioControl:new{
            text = "\u{25C0}",
            width = icon_btn_w,
            enabled = #designs > 0,
            callback = function()
                local new_idx = (icon_idx == 0) and #designs or (icon_idx - 1)
                updatePreview(scale, mt_steps, mr_steps, new_idx)
            end,
        },
        HorizontalSpan:new{ width = hspan },
        preview_btn,
        HorizontalSpan:new{ width = hspan },
        StudioControl:new{
            text = "\u{25B6}",
            width = icon_btn_w,
            enabled = #designs > 0,
            callback = function()
                local new_idx = (icon_idx >= #designs) and 0 or (icon_idx + 1)
                updatePreview(scale, mt_steps, mr_steps, new_idx)
            end,
        },
    }

    -- === SIZE section ===
    local step_btn_w  = math.floor((inner_w - (hspan * 4)) * 0.18)
    local value_box_w = inner_w - (step_btn_w * 4) - (hspan * 4)

    local function clampScale(v)
        return math.max(MIN_SCALE, math.min(MAX_SCALE, math.floor(v * 10 + 0.5) / 10))
    end

    local scale_btn_w = math.floor((inner_w - value_box_w - hspan * 2) / 2)
    local scale_row = HorizontalGroup:new{
        align = "center",
        StudioControl:new{
            text = _("Smaller"),
            width = scale_btn_w,
            callback = function() updatePreview(clampScale(scale - 0.1), mt_steps, mr_steps, icon_idx) end,
        },
        HorizontalSpan:new{ width = hspan },
        valueBox(scale_value, value_box_w, btn_h),
        HorizontalSpan:new{ width = hspan },
        StudioControl:new{
            text = _("Bigger"),
            width = scale_btn_w,
            callback = function() updatePreview(clampScale(scale + 0.1), mt_steps, mr_steps, icon_idx) end,
        },
    }

    -- === POSITION section ===
    local label_w = math.floor(inner_w * 0.20)
    local mbtn_w  = math.floor(inner_w * 0.18)
    local mval_w  = inner_w - label_w - mbtn_w * 2 - hspan * 3

    local function marginValueButton(label, value, on_change)
        local button
        button = StudioControl:new{
            text = tostring(value),
            width = mval_w,
            height = btn_h - 2 * (Size.padding.button + Size.border.button),
            radius = Size.radius.button,
            callback = function()
                local dialog
                dialog = require("ui/widget/inputdialog"):new{
                    title = label,
                    description = "0–" .. MAX_STEPS,
                    input_hint = button.text,
                    input_type = "number",
                    modal = true,
                    stop_events_propagation = true,
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function() UIManager:close(dialog) end,
                            },
                            {
                                text = _("Apply Now"),
                                is_enter_default = true,
                                callback = function()
                                    local steps = dialog:getInputValue()
                                    if steps and steps >= 0 and steps <= MAX_STEPS and steps == math.floor(steps) then
                                        UIManager:close(dialog)
                                        on_change(steps)
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        }
        return button
    end

    top_value = marginValueButton(_("Top"), mt_steps, function(steps)
        updatePreview(scale, steps, mr_steps, icon_idx)
    end)
    right_value = marginValueButton(_("Right"), mr_steps, function(steps)
        updatePreview(scale, mt_steps, steps, icon_idx)
    end)

    local function marginRow(label, value, on_dec, on_inc)
        return HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = label_w, h = btn_h },
                TextWidget:new{ text = label, face = Font:getFace("cfont", 18) },
            },
            HorizontalSpan:new{ width = hspan },
            StudioControl:new{ text = "−", width = mbtn_w, callback = on_dec },
            HorizontalSpan:new{ width = hspan },
            value,
            HorizontalSpan:new{ width = hspan },
            StudioControl:new{ text = "+", width = mbtn_w, callback = on_inc },
        }
    end

    local top_margin_row = marginRow(
        _("Top"), top_value,
        function() updatePreview(scale, math.max(0, mt_steps - 1), mr_steps, icon_idx) end,
        function() updatePreview(scale, math.min(MAX_STEPS, mt_steps + 1), mr_steps, icon_idx) end
    )
    local right_margin_row = marginRow(
        _("Right"), right_value,
        function() updatePreview(scale, mt_steps, math.max(0, mr_steps - 1), icon_idx) end,
        function() updatePreview(scale, mt_steps, math.min(MAX_STEPS, mr_steps + 1), icon_idx) end
    )

    -- === QUICK PRESETS section ===
    local preset_btn_w = math.floor((inner_w - hspan * 2) / 3)
    local function selectedFilename()
        return (icon_idx > 0 and designs[icon_idx]) and designs[icon_idx].text or G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    end
    local function selectedIsRibbon()
        return isRibbonDesign(selectedFilename())
    end
    local preset_row = HorizontalGroup:new{
        align = "center",
        StudioControl:new{
            text = _("Corner"),
            width = preset_btn_w,
            callback = function()
                updatePreview(DEFAULT_NEW_SELECTION_SCALE, 0, 0, icon_idx)
            end,
        },
        HorizontalSpan:new{ width = hspan },
        StudioControl:new{
            text = _("Ribbon"),
            width = preset_btn_w,
            callback = function()
                updatePreview(DEFAULT_RIBBON_SELECTION_SCALE, 0, DEFAULT_RIBBON_RIGHT_STEPS, icon_idx)
            end,
        },
        HorizontalSpan:new{ width = hspan },
        StudioControl:new{
            text = _("Tucked"),
            width = preset_btn_w,
            callback = function()
                if selectedIsRibbon() then
                    updatePreview(2.3, 0, DEFAULT_RIBBON_RIGHT_STEPS, icon_idx)
                else
                    updatePreview(3.0, 0, 0, icon_idx)
                end
            end,
        },
    }

    local function cancel()
        G_reader_settings:saveSetting(S_SCALE_FACTOR, originals.scale)
        G_reader_settings:saveSetting(S_MARGIN_TOP, originals.mt)
        G_reader_settings:saveSetting(S_MARGIN_RIGHT, originals.mr)
        G_reader_settings:saveSetting(S_CUSTOM_ICON, originals.icon)
        G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, originals.icon_name)
        self:applyDogearToLive()
        UIManager:close(top_widget)
        return true
    end

    -- === ACTION buttons ===
    local act_btn_w = math.floor((inner_w - hspan * 2) / 3)
    local actions_row_top = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = _("Set Day") .. " ☀",
            width = act_btn_w,
            callback = function()
                self:saveCurrentAsDayPairCharm()
            end,
        },
        HorizontalSpan:new{ width = hspan },
        Button:new{
            text = _("Save"),
            width = act_btn_w,
            callback = function()
                UIManager:close(top_widget)
                UIManager:show(InfoMessage:new{ text = charmStatus("Current Charm", "Updated"), timeout = 2 })
            end,
        },
        HorizontalSpan:new{ width = hspan },
        Button:new{
            text = _("Set Night") .. " ☾",
            width = act_btn_w,
            callback = function()
                self:saveCurrentAsNightPairCharm()
            end,
        },
    }
    local actions_row_bottom = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = _("Default"),
            width = act_btn_w,
            callback = function()
                self:setCurrentLookAsDefault()
            end,
        },
        HorizontalSpan:new{ width = hspan },
        Button:new{
            text = _("Reset"),
            width = act_btn_w,
            callback = function()
                UIManager:close(top_widget)
                self:applyOriginalCorner(charmStatus("Corner", "Restored"))
            end,
        },
        HorizontalSpan:new{ width = hspan },
        Button:new{
            text = _("Cancel"),
            width = act_btn_w,
            callback = cancel,
        },
    }

    -- === Compose dialog: Bookmark Studio ===
    local card_pad = math.max(Size.padding.default, screenScaleBySize(10))
    local card_w = inner_w

    local header = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = _("Charm Studio") .. " ✨",
            face = Font:getFace("cfont", 24),
            bold = true,
        },
        VerticalSpan:new{ width = math.floor(vspan_sm / 2) },
    }

    local design_card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        radius = Size.radius.button,
        padding = card_pad,
        VerticalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = card_w - card_pad * 2, h = screenScaleBySize(24) },
                TextWidget:new{
                    text = _("Choose a Charm") .. " ◈",
                    face = Font:getFace("smallinfofont", 17),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = vspan_sm },
            icon_row,
        },
    }

    local size_card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        radius = Size.radius.button,
        padding = card_pad,
        VerticalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = card_w - card_pad * 2, h = screenScaleBySize(24) },
                TextWidget:new{
                    text = _("Charm Size") .. " ↕",
                    face = Font:getFace("smallinfofont", 17),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = vspan_sm },
            scale_row,
        },
    }

    local placement_card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        radius = Size.radius.button,
        padding = card_pad,
        VerticalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = card_w - card_pad * 2, h = screenScaleBySize(24) },
                TextWidget:new{
                    text = _("Charm Placement") .. " ⌖",
                    face = Font:getFace("smallinfofont", 17),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = vspan_sm },
            top_margin_row,
            VerticalSpan:new{ width = vspan_sm },
            right_margin_row,
        },
    }

    local presets_card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        radius = Size.radius.button,
        padding = card_pad,
        VerticalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = card_w - card_pad * 2, h = screenScaleBySize(24) },
                TextWidget:new{
                    text = _("Quick Presets") .. " ✦",
                    face = Font:getFace("smallinfofont", 17),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = vspan_sm },
            preset_row,
        },
    }

    dialog_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = pad,
        VerticalGroup:new{
            align = "center",
            header,
            VerticalSpan:new{ width = vspan_lg },
            design_card,
            VerticalSpan:new{ width = vspan_sm },
            size_card,
            VerticalSpan:new{ width = vspan_sm },
            placement_card,
            VerticalSpan:new{ width = vspan_sm },
            presets_card,
            VerticalSpan:new{ width = vspan_lg },
            actions_row_top,
            VerticalSpan:new{ width = vspan_sm },
            actions_row_bottom,
        },
    }

    top_widget = InputContainer:new{
        modal = true,
        stop_events_propagation = true,
        dimen = Screen:getSize(),
        onClose = cancel,
    }
    top_widget[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        MovableContainer:new{ dialog_frame },
    }

    if Device:hasKeys() then
        top_widget.key_events.Close = { { Device.input.group.Back } }
    end

    function top_widget:onCloseWidget()
        if dialog_frame.dimen then UIManager:setDirty(nil, "flashui", dialog_frame.dimen) end
        self:free()
    end

    UIManager:show(top_widget)
end

function BookmarkChrome:patchReaderDogear()
    local ok, err = pcall(function()
        local ReaderDogear = require("apps/reader/modules/readerdogear")

        if not ReaderDogear._dm_patched then
            local orig_setupDogear = ReaderDogear.setupDogear
            local orig_resetLayout = ReaderDogear.resetLayout

            local function applyMarginOffset(rd_self)
                if not (rd_self.vgroup and rd_self.icon and rd_self.top_pad) then return end
                local mt_steps = clampNumber(G_reader_settings:readSetting(S_MARGIN_TOP), 0, 0, MAX_STEPS)
                local mr_steps = clampNumber(G_reader_settings:readSetting(S_MARGIN_RIGHT), 0, 0, MAX_STEPS)
                local mt = topStepsToPx(mt_steps)
                local mr = rightStepsToPx(mr_steps)

                -- Ribbon bookmarks should start at the very top.
                -- Dog-ears keep KOReader's normal dogear_y_offset.
                local top_offset = rd_self._bc_is_ribbon and 0 or (rd_self.dogear_y_offset or 0)
                local icon_h = rd_self._bc_icon_height or rd_self.dogear_size

                -- Update main container dimensions
                if rd_self[1] and rd_self[1].dimen then
                    rd_self[1].dimen.w = Screen:getWidth()
                    rd_self[1].dimen.h = top_offset + icon_h + mt
                end

                -- Apply top margin (VerticalSpan uses .width for its size)
                rd_self.top_pad.width = top_offset + mt

                -- Apply right margin
                local wrapper = rd_self._dm_wrapper
                if mr > 0 then
                    if wrapper then
                        wrapper[2].width = mr
                        wrapper:resetLayout()
                    else
                        wrapper = HorizontalGroup:new{
                            align = "top",
                            rd_self.icon,
                            HorizontalSpan:new{ width = mr },
                        }
                        rd_self._dm_wrapper = wrapper
                        rd_self.vgroup[2] = wrapper
                    end
                else
                    rd_self.vgroup[2] = rd_self.icon
                    if wrapper then
                        wrapper[1] = nil
                        wrapper:free()
                        rd_self._dm_wrapper = nil
                    end
                end

                rd_self.vgroup:resetLayout()
            end

            ReaderDogear.setupDogear = function(rd_self, new_dogear_size)
                local sf = clampNumber(G_reader_settings:readSetting(S_SCALE_FACTOR), 1, MIN_SCALE, MAX_SCALE)
                local size = math.ceil((new_dogear_size or rd_self.dogear_max_size) * sf)
                local icon_path = G_reader_settings:readSetting(S_CUSTOM_ICON)
                if type(icon_path) ~= "string" then icon_path = nil end

                if rd_self.dogear_size == size and rd_self._bc_requested_icon == icon_path then
                    return
                end

                -- Force the stock rebuild for a different file at the same size.
                -- The stock container owns and frees the previous icon and wrapper.
                rd_self.dogear_size = nil
                orig_setupDogear(rd_self, size)
                rd_self._dm_wrapper = nil
                rd_self._bc_requested_icon = icon_path
                rd_self._bc_icon_height = nil
                rd_self._bc_is_ribbon = nil

                if icon_path and lfs.attributes(icon_path, "mode") == "file" and rd_self.icon then
                    local is_ribbon = isRibbonDesign(icon_path:match("([^/]+)$"))
                    local height = is_ribbon and math.floor(size * 1.35) or size
                    local stock_icon = rd_self.icon
                    rd_self.icon = ColorCharmWidget:new{
                        file = icon_path,
                        width = is_ribbon and math.max(1, math.floor(size * 0.85)) or size,
                        height = height,
                        alpha = true,
                        fallback_file = stock_icon.file,
                        fallback_rotation = stock_icon.rotation_angle,
                    }
                    stock_icon:free()
                    rd_self._bc_icon_height = height
                    rd_self._bc_is_ribbon = is_ribbon
                end

                applyMarginOffset(rd_self)
            end

            if orig_resetLayout then
                ReaderDogear.resetLayout = function(rd_self, ...)
                    orig_resetLayout(rd_self, ...)
                    applyMarginOffset(rd_self)
                end
            end

            local orig_updateDogearOffset = ReaderDogear.updateDogearOffset
            if orig_updateDogearOffset then
                ReaderDogear.updateDogearOffset = function(rd_self, ...)
                    orig_updateDogearOffset(rd_self, ...)
                    applyMarginOffset(rd_self)
                end
            end
            ReaderDogear._dm_patched = true
        end
    end)

    if not ok then
        logger.err("BookmarkChrome: patchReaderDogear failed:", err)
    end
end


function BookmarkChrome:onDispatcherRegisterActions()
    safeRegisterAction("booknook_charm_studio", { category="none", event="BookNookCharmStudio", title=PLUGIN_NAME .. " — " .. _("Charm Studio"), reader=true })
    safeRegisterAction("booknook_charm_library", { category="none", event="BookNookCharmLibrary", title=PLUGIN_NAME .. " — " .. _("Charm Library"), reader=true })
    safeRegisterAction("booknook_favorite_charms", { category="none", event="BookNookFavoriteCharms", title=PLUGIN_NAME .. " — " .. _("Favorites"), reader=true })
    safeRegisterAction("booknook_next_favorite_charm", { category="none", event="BookNookNextFavoriteCharm", title=PLUGIN_NAME .. " — " .. _("Next Favorite Charm"), reader=true })
    safeRegisterAction("booknook_charm_types", { category="none", event="BookNookCharmTypes", title=PLUGIN_NAME .. " — " .. _("Charm Types"), reader=true })
    safeRegisterAction("booknook_switch_day_night", { category="none", event="BookNookSwitchDayNight", title=PLUGIN_NAME .. " — " .. _("Switch Day/Night Pair"), reader=true })
    safeRegisterAction("booknook_apply_day_charm", { category="none", event="BookNookApplyDayCharm", title=PLUGIN_NAME .. " — " .. _("Apply Day Charm"), reader=true })
    safeRegisterAction("booknook_apply_night_charm", { category="none", event="BookNookApplyNightCharm", title=PLUGIN_NAME .. " — " .. _("Apply Night Charm"), reader=true })
    safeRegisterAction("booknook_toggle_auto_pair", { category="none", event="BookNookToggleAutoPair", title=PLUGIN_NAME .. " — " .. _("Auto Pair"), reader=true })
    safeRegisterAction("booknook_reset_charm", { category="none", event="BookNookResetCharm", title=PLUGIN_NAME .. " — " .. _("Reset"), reader=true })
end


function BookmarkChrome:ensureReaderAction()
    if self.ui and self.ui.view then return true end
    UIManager:show(InfoMessage:new{ text = _("Open a book first."), timeout = 2 })
    return false
end

function BookmarkChrome:onBookNookCharmStudio()
        if not self:ensureReaderAction() then return true end
self:showSizeSlider()
    return true
end

function BookmarkChrome:onBookNookCharmLibrary()
        if not self:ensureReaderAction() then return true end
self:showDesignMenu()
    return true
end

function BookmarkChrome:onBookNookFavoriteCharms()
        if not self:ensureReaderAction() then return true end
self:showFavoriteLooksMenu()
    return true
end

function BookmarkChrome:onBookNookNextFavoriteCharm()
        if not self:ensureReaderAction() then return true end
self:applyNextFavoriteCharm()
    return true
end

function BookmarkChrome:onBookNookCharmTypes()
        if not self:ensureReaderAction() then return true end
self:showCharmTypesMenu()
    return true
end

function BookmarkChrome:onBookNookSwitchDayNight()
        if not self:ensureReaderAction() then return true end
self:switchDayNightPair()
    return true
end

function BookmarkChrome:onBookNookApplyDayCharm()
        if not self:ensureReaderAction() then return true end
self:applyPairCharm("day")
    return true
end

function BookmarkChrome:onBookNookApplyNightCharm()
        if not self:ensureReaderAction() then return true end
self:applyPairCharm("night")
    return true
end

function BookmarkChrome:onBookNookToggleAutoPair()
        if not self:ensureReaderAction() then return true end
self:toggleAutoDayNightPair()
    return true
end

function BookmarkChrome:onBookNookResetCharm()
        if not self:ensureReaderAction() then return true end
self:resetAll()
    UIManager:show(InfoMessage:new{ text = charmStatus("Default", "Restored"), timeout = 2 })
    return true
end


function BookmarkChrome:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.view and self.ui.menu then
        self._booknook_menu_registered = safeRegisterMainMenu(self)
    end
end

function BookmarkChrome:setDogearPaintOrder()
    local view = self.ui and self.ui.view
    local dogear = view and view.dogear
    if not dogear or view._dogearbooks_paint_wrapped then
        return
    end

    local paint_view = view.paintTo
    local paint_dogear = dogear.paintTo
    if type(paint_view) ~= "function" or type(paint_dogear) ~= "function" then return end
    local defer_dogear = false

    function dogear:paintTo(...)
        if not defer_dogear then
            return paint_dogear(self, ...)
        end
    end

    function view:paintTo(bb, x, y, ...)
        if defer_dogear or not self.dogear_visible or self.dogear ~= dogear then
            return paint_view(self, bb, x, y, ...)
        end

        -- ReaderView can recurse during partial reflow. Defer the dogear until
        -- the outer paint finishes, including all registered view modules.
        defer_dogear = true
        local ok, err = pcall(paint_view, self, bb, x, y, ...)
        defer_dogear = false
        if not ok then error(err, 0) end
        if self.dogear_visible then
            paint_dogear(dogear, bb, x, y)
        end
    end

    view._dogearbooks_paint_wrapped = true
end

function BookmarkChrome:onReaderReady()
    if not self._booknook_menu_registered and self.ui and self.ui.menu then
        self._booknook_menu_registered = safeRegisterMainMenu(self)
    end
    self:ensureAutoPairDefaultOff()
    self:patchReaderDogear()
    local ui = self.ui
    if ui and ui.postReaderReadyCallback and ui.registerPostReaderReadyCallback then
        ui:registerPostReaderReadyCallback(function()
            self:setDogearPaintOrder()
        end)
    else
        self:setDogearPaintOrder()
    end
    local current_icon = G_reader_settings:readSetting(S_CUSTOM_ICON)
    if type(current_icon) == "string" and current_icon:find("booknookcharms.koplugin/", 1, true) then
        self:saveCurrentCharmPath()
    end
    local applied = self:applyBookLook(false) or self:applyFirstRunDefault()
    if self:autoPairEnabled() then
        self:registerAutoPairReader()
    end
    if not self:applyAutoDayNightPair(false, true) and not applied then
        self:applyDogearToLive()
    end
end

function BookmarkChrome:onCloseDocument()
    if auto_pair_reader == self then
        auto_pair_reader = nil
    end
end


function BookmarkChrome:saveCurrentAsDayPairCharm()
    local icon = G_reader_settings:readSetting(S_CUSTOM_ICON)
    local name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    local resolved_name, resolved_path = self:resolveSavedDesign(icon, name)
    if not resolved_path or not resolved_name then
        UIManager:show(InfoMessage:new{ text = charmStatus("Current Charm", "None"), timeout = 2 })
        return
    end
    G_reader_settings:saveSetting(S_CUSTOM_ICON, resolved_path)
    G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, resolved_name)
    G_reader_settings:saveSetting(S_DAY_PAIR_ICON, resolved_path)
    G_reader_settings:saveSetting(S_DAY_PAIR_NAME, resolved_name)
    G_reader_settings:saveSetting(S_DAY_PAIR_SCALE, G_reader_settings:readSetting(S_SCALE_FACTOR) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_SELECTION_SCALE or DEFAULT_NEW_SELECTION_SCALE))
    G_reader_settings:saveSetting(S_DAY_PAIR_TOP, G_reader_settings:readSetting(S_MARGIN_TOP) or 0)
    G_reader_settings:saveSetting(S_DAY_PAIR_RIGHT, G_reader_settings:readSetting(S_MARGIN_RIGHT) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_RIGHT_STEPS or 0))
    UIManager:show(InfoMessage:new{ text = charmStatus("Day", "Saved") .. " ☀", timeout = 2 })
end

function BookmarkChrome:saveCurrentAsNightPairCharm()
    local icon = G_reader_settings:readSetting(S_CUSTOM_ICON)
    local name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    local resolved_name, resolved_path = self:resolveSavedDesign(icon, name)
    if not resolved_path or not resolved_name then
        UIManager:show(InfoMessage:new{ text = charmStatus("Current Charm", "None"), timeout = 2 })
        return
    end
    G_reader_settings:saveSetting(S_CUSTOM_ICON, resolved_path)
    G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, resolved_name)
    G_reader_settings:saveSetting(S_NIGHT_PAIR_ICON, resolved_path)
    G_reader_settings:saveSetting(S_NIGHT_PAIR_NAME, resolved_name)
    G_reader_settings:saveSetting(S_NIGHT_PAIR_SCALE, G_reader_settings:readSetting(S_SCALE_FACTOR) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_SELECTION_SCALE or DEFAULT_NEW_SELECTION_SCALE))
    G_reader_settings:saveSetting(S_NIGHT_PAIR_TOP, G_reader_settings:readSetting(S_MARGIN_TOP) or 0)
    G_reader_settings:saveSetting(S_NIGHT_PAIR_RIGHT, G_reader_settings:readSetting(S_MARGIN_RIGHT) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_RIGHT_STEPS or 0))
    UIManager:show(InfoMessage:new{ text = charmStatus("Night", "Saved") .. " ☾", timeout = 2 })
end

function BookmarkChrome:findPackVariant(path, which)
    if type(path) ~= "string" then return end

    local root = self.path .. "/"
    local relative = path:sub(1, #root) == root and path:sub(#root + 1)
        or path:match("dogearbooks%.koplugin/(.+)$")
    if not relative then return end

    local pack, filename = relative:match("^night/([^/]+)/([^/]+)$")
    local from_night = pack ~= nil
    if from_night == (which == "night") then return end
    if not from_night then
        pack, filename = relative:match("^([^/]+)/([^/]+)$")
    end
    if pack ~= "bears" and pack ~= "Movies" and pack ~= "tv show"
        and pack ~= "princess" and pack ~= "simpson" and pack ~= "family guy" and pack ~= "marvel" then
        return
    end

    local variant_name, variant_path
    if from_night then
        variant_name = filename:gsub("^ribbon_night_", "ribbon_"):gsub("^dogear_night_", "")
        variant_path = root .. pack .. "/" .. variant_name
    else
        variant_name = isRibbonDesign(filename)
            and ("ribbon_night_" .. filename:sub(8)) or ("dogear_night_" .. filename)
        variant_path = root .. "night/" .. pack .. "/" .. variant_name
    end
    if lfs.attributes(variant_path, "mode") == "file" then
        return variant_name, variant_path
    end
end

function BookmarkChrome:applyPackVariant(which, label, current_only)
    local name, path, scale, top, right
    if not current_only then
        local from_day = which == "night"
        name, path = self:findPackVariant(G_reader_settings:readSetting(from_day and S_DAY_PAIR_ICON or S_NIGHT_PAIR_ICON), which)
        if path then
            scale = G_reader_settings:readSetting(from_day and S_DAY_PAIR_SCALE or S_NIGHT_PAIR_SCALE)
            top = G_reader_settings:readSetting(from_day and S_DAY_PAIR_TOP or S_NIGHT_PAIR_TOP)
            right = G_reader_settings:readSetting(from_day and S_DAY_PAIR_RIGHT or S_NIGHT_PAIR_RIGHT)
        end
    end
    if not path then
        name, path = self:findPackVariant(G_reader_settings:readSetting(S_CUSTOM_ICON), which)
        if not path then return false end
        scale = G_reader_settings:readSetting(S_SCALE_FACTOR)
        top = G_reader_settings:readSetting(S_MARGIN_TOP)
        right = G_reader_settings:readSetting(S_MARGIN_RIGHT)
    end

    scale = scale or (isRibbonDesign(name) and DEFAULT_RIBBON_SELECTION_SCALE or DEFAULT_NEW_SELECTION_SCALE)
    self:applyLook(name, path, scale, top, right, false, label)
    return true
end

function BookmarkChrome:applyPairCharm(which, silent, skip_confirmation)
    local icon_key, name_key, scale_key, top_key, right_key, label
    if which == "night" then
        icon_key, name_key, scale_key, top_key, right_key = S_NIGHT_PAIR_ICON, S_NIGHT_PAIR_NAME, S_NIGHT_PAIR_SCALE, S_NIGHT_PAIR_TOP, S_NIGHT_PAIR_RIGHT
        label = charmStatus("Night", "Applied") .. " ☾"
    else
        icon_key, name_key, scale_key, top_key, right_key = S_DAY_PAIR_ICON, S_DAY_PAIR_NAME, S_DAY_PAIR_SCALE, S_DAY_PAIR_TOP, S_DAY_PAIR_RIGHT
        label = charmStatus("Day", "Applied") .. " ☀"
    end
    if skip_confirmation then label = nil end

    local icon = G_reader_settings:readSetting(icon_key)
    local name = G_reader_settings:readSetting(name_key)
    local resolved_name, resolved_path, repaired = self:resolveSavedDesign(icon, name)
    if not resolved_path or not resolved_name then
        if icon or name then
            G_reader_settings:delSetting(icon_key)
            G_reader_settings:delSetting(name_key)
            G_reader_settings:delSetting(scale_key)
            G_reader_settings:delSetting(top_key)
            G_reader_settings:delSetting(right_key)
        end
        if self:applyPackVariant(which, label) then return true end
        if (icon or name) and not silent then
            UIManager:show(InfoMessage:new{ text = charmStatus("Day/Night Pair", "Missing"), timeout = 2 })
        end
        return false
    end
    if repaired then
        G_reader_settings:saveSetting(icon_key, resolved_path)
        G_reader_settings:saveSetting(name_key, resolved_name)
    end

    self:applyLook(resolved_name, resolved_path,
        G_reader_settings:readSetting(scale_key) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_SELECTION_SCALE or DEFAULT_NEW_SELECTION_SCALE),
        G_reader_settings:readSetting(top_key) or 0,
        G_reader_settings:readSetting(right_key) or (isRibbonDesign(resolved_name) and DEFAULT_RIBBON_RIGHT_STEPS or 0),
        false,
        label)
    return true
end

function BookmarkChrome:switchDayNightPair()
    local current = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    local day_name = G_reader_settings:readSetting(S_DAY_PAIR_NAME)
    local night_name = G_reader_settings:readSetting(S_NIGHT_PAIR_NAME)

    if current and day_name and current == day_name then
        self:applyPairCharm("night", true)
    elseif current and night_name and current == night_name then
        self:applyPairCharm("day", true)
    elseif night_name then
        self:applyPairCharm("night", true)
    elseif day_name or (type(current) == "string" and current:find("_night_", 1, true)) then
        self:applyPairCharm("day", true)
    else
        self:applyPairCharm("night", true)
    end
end


function BookmarkChrome:isNightModeActive()
    -- KOReader stores the active night-mode switch in reader settings.
    -- ["night_mode"] is the active KOReader night-mode switch.
    return G_reader_settings:readSetting("night_mode") == true
end


function BookmarkChrome:ensureAutoPairDefaultOff()
    if G_reader_settings:readSetting(S_AUTO_PAIR_SWITCH) == nil then
        G_reader_settings:saveSetting(S_AUTO_PAIR_SWITCH, false)
    end
end

function BookmarkChrome:autoPairEnabled()
    -- Default OFF unless the user explicitly turns Auto Pair on.
    return G_reader_settings:readSetting(S_AUTO_PAIR_SWITCH) == true
end

function BookmarkChrome:toggleAutoDayNightPair()
    if self:autoPairEnabled() then
        G_reader_settings:saveSetting(S_AUTO_PAIR_SWITCH, false)
        if auto_pair_reader == self then auto_pair_reader = nil end
        UIManager:show(InfoMessage:new{ text = charmStatus("Auto Pair", "Off"), timeout = 2 })
    else
        G_reader_settings:saveSetting(S_AUTO_PAIR_SWITCH, true)
        self:registerAutoPairReader()
        UIManager:show(InfoMessage:new{ text = charmStatus("Auto Pair", "On"), timeout = 2 })
        self:applyAutoDayNightPair(true, true)
    end
end

function BookmarkChrome:applyAutoDayNightPair(force, skip_confirmation)
    if not self:autoPairEnabled() then return false end

    local want = self:isNightModeActive() and "night" or "day"
    local last = G_reader_settings:readSetting(S_LAST_PAIR_MODE)

    if not force and last == want then
        local icon_key = want == "night" and S_NIGHT_PAIR_ICON or S_DAY_PAIR_ICON
        local name_key = want == "night" and S_NIGHT_PAIR_NAME or S_DAY_PAIR_NAME
        if G_reader_settings:readSetting(icon_key) or G_reader_settings:readSetting(name_key) then
            return false
        end
        -- A newly opened book may have restored its own original artwork.
        return self:applyPackVariant(want, nil, true)
    end

    local ok = self:applyPairCharm(want, true, skip_confirmation)
    if ok then
        G_reader_settings:saveSetting(S_LAST_PAIR_MODE, want)
    end
    return ok
end



function BookmarkChrome:registerAutoPairReader()
    if not night_mode_patched then
        local ok, listener = pcall(require, "device/devicelistener")
        if not ok or type(listener.onToggleNightMode) ~= "function" then
            logger.warn("dogearbooks: night mode listener is unavailable")
            return
        end

        -- Both KOReader events and AutoWarmth use this handler. The setting
        -- is updated by the end of the original handler.
        local toggleNightMode = listener.onToggleNightMode
        listener.onToggleNightMode = function(device_listener, ...)
            local handled = toggleNightMode(device_listener, ...)
            local reader = auto_pair_reader
            if reader and reader.ui and reader.ui.document then
                local applied, err = pcall(reader.applyAutoDayNightPair, reader, true, true)
                if not applied then
                    logger.warn("dogearbooks: could not apply automatic day/night charm", err)
                end
            end
            return handled
        end
        night_mode_patched = true
    end
    auto_pair_reader = self
end


function BookmarkChrome:buildCharmTypeItems()
    local plugin_night = self:getPluginNightDir() .. "/"
    local data_night = self:getDataNightDir() .. "/"

    local function category(title, matches)
        return {
            text = title,
            keep_menu_open = true,
            callback = function()
                local entries = {}
                for _, design in ipairs(self:scanDesigns()) do
                    if matches(design) then entries[#entries + 1] = design end
                end
                self:showGallery(title, entries)
            end,
        }
    end

    return {
        category(_("Ribbon Charms") .. " ✿", function(design) return isRibbonDesign(design.text) end),
        category(_("Corner Charms") .. " ❖", function(design) return not isRibbonDesign(design.text) end),
        {
            text = _("Polar Bears"),
            keep_menu_open = true,
            callback = function() self:showFolderGallery(self:getPluginBearsDir(), _("Polar Bears")) end,
        },
        {
            text = _("Cinema"),
            keep_menu_open = true,
            callback = function() self:showFolderGallery(self:getPluginMoviesDir(), _("Cinema")) end,
        },
        category(_("Night Charms") .. " ☾", function(design)
            local filename = design.text:lower()
            return filename:find("_night_", 1, true) or filename:match("^night_")
                or design.path:sub(1, #plugin_night) == plugin_night
                or design.path:sub(1, #data_night) == data_night
        end),
        category(_("E-ink Charms") .. " ◐", function(design) return isEInkDesign(design.text) end),
    }
end

function BookmarkChrome:buildDayNightPairItems()
    return {
        {
            text = _("Set Day") .. " ☀",
            keep_menu_open = false,
            callback = function() self:saveCurrentAsDayPairCharm() end,
        },
        {
            text = _("Set Night") .. " ☾",
            keep_menu_open = false,
            callback = function() self:saveCurrentAsNightPairCharm() end,
        },
        {
            text = _("Switch Day/Night Pair") .. " ☀☾",
            keep_menu_open = false,
            callback = function() self:switchDayNightPair() end,
        },
        {
            text = _("Auto Pair") .. " · " .. (self:autoPairEnabled() and _("On") or _("Off")),
            keep_menu_open = false,
            callback = function() self:toggleAutoDayNightPair() end,
        },
        {
            text = _("Apply Now"),
            keep_menu_open = false,
            callback = function() self:applyAutoDayNightPair(true) end,
        },
    }
end



function BookmarkChrome:buildSetCharmItems()
    return {
        {
            text = _("Save Charm to This Book") .. " ✓",
            keep_menu_open = false,
            callback = function()
                self:saveCurrentLookToBook()
            end,
        },
        {
            text = _("Set as default") .. " ✧",
            keep_menu_open = false,
            callback = function()
                self:setCurrentLookAsDefault()
            end,
        },
        {
            text = _("Reset") .. " ↺",
            keep_menu_open = false,
            callback = function()
                self:resetAll()
                UIManager:show(InfoMessage:new{ text = charmStatus("Default", "Restored"), timeout = 2 })
            end,
        },
    }
end

function BookmarkChrome:showHelp()
    UIManager:show(InfoMessage:new{
        text = table.concat({
            PLUGIN_NAME,
            _("Charm Studio") .. " — " .. _("Choose a Charm") .. " · " .. _("Charm Size") .. " · " .. _("Charm Placement"),
            _("Charm Library") .. " — " .. _("Ribbon Charms") .. " · " .. _("Corner Charms") .. " · " .. _("Polar Bears"),
            _("Favorites") .. " — " .. _("Add Current Charm") .. " · " .. _("Next Favorite Charm"),
            _("Day/Night Pair") .. " — " .. _("Set Day") .. " · " .. _("Set Night") .. " · " .. _("Auto Pair"),
            _("Manage Charms") .. " — " .. _("Save Charm to This Book") .. " · " .. _("Set as default"),
        }, "\n\n"),
    })
end

function BookmarkChrome:showTroubleshooting()
    local current_name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME)
    local current_path = G_reader_settings:readSetting(S_CUSTOM_ICON)
    local resolved_name, resolved_path, repaired = self:resolveSavedDesign(current_path, current_name)
    if repaired then
        G_reader_settings:saveSetting(S_CUSTOM_ICON, resolved_path)
        G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, resolved_name)
    end

    local ds = self.ui and self.ui.doc_settings
    local book_name = ds and ds:readSetting(B_CUSTOM_ICON_NAME) or nil
    local book_path = ds and ds:readSetting(B_CUSTOM_ICON) or nil
    local book_resolved = nil
    if ds then
        book_resolved = self:resolveSavedDesign(book_path, book_name) ~= nil
    end

    local default_name = G_reader_settings:readSetting(S_DEFAULT_ICON_NAME)
    local default_path = G_reader_settings:readSetting(S_DEFAULT_ICON)
    local default_resolved = self:resolveSavedDesign(default_path, default_name) ~= nil
    local day_resolved = self:resolveSavedDesign(G_reader_settings:readSetting(S_DAY_PAIR_ICON), G_reader_settings:readSetting(S_DAY_PAIR_NAME)) ~= nil
    local night_resolved = self:resolveSavedDesign(G_reader_settings:readSetting(S_NIGHT_PAIR_ICON), G_reader_settings:readSetting(S_NIGHT_PAIR_NAME)) ~= nil

    local function yesno(value)
        return value and _("Yes") or _("No")
    end

    UIManager:show(InfoMessage:new{
        text = PLUGIN_NAME .. " — " .. _("Troubleshooting")
            .. "\n\n" .. _("Version") .. ": " .. PLUGIN_VERSION
            .. "\n" .. _("Current Charm") .. ": " .. (resolved_name or current_name or _("None"))
            .. "\n" .. _("File") .. ": " .. yesno(resolved_path ~= nil)
            .. "\n" .. _("Default") .. ": " .. yesno(default_resolved)
            .. "\n" .. _("This Book") .. ": " .. yesno(book_resolved)
            .. "\n" .. _("Day") .. ": " .. yesno(day_resolved)
            .. "\n" .. _("Night") .. ": " .. yesno(night_resolved)
            .. "\n" .. _("Auto Pair") .. ": " .. (self:autoPairEnabled() and _("On") or _("Off"))
            .. "\n" .. _("Charm Size") .. ": " .. tostring(G_reader_settings:readSetting(S_SCALE_FACTOR) or DEFAULT_NEW_SELECTION_SCALE)
            .. "\n" .. _("Top") .. " / " .. _("Right") .. ": " .. tostring(G_reader_settings:readSetting(S_MARGIN_TOP) or 0) .. " / " .. tostring(G_reader_settings:readSetting(S_MARGIN_RIGHT) or 0),
    })
end

function BookmarkChrome:showCharmTypesMenu()
    local charm_types_menu
    charm_types_menu = Menu:new{
        title = _("Charm Types") .. " ◇",
        item_table = self:buildCharmTypeItems(),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(charm_types_menu) end,
    }
    UIManager:show(charm_types_menu)
end

function BookmarkChrome:addToMainMenu(menu_items)
    menu_items.dogearbooks = {
        text = PLUGIN_NAME,
        sorting_hint = "typeset",
        sub_item_table_func = function()
            return {
                {
                    text = _("Charm Studio") .. " ✨",
                    keep_menu_open = false,
                    callback = function() self:showSizeSlider() end,
                },
                {
                    text = _("Charm Library") .. " ❤",
                    callback = function() self:showDesignMenu() end,
                },
                {
                    text = _("Folders"),
                    keep_menu_open = true,
                    sub_item_table_func = function() return self:buildPackFolderItems() end,
                },
                {
                    text = _("Favorites") .. " ⭐",
                    keep_menu_open = true,
                    sub_item_table_func = function() return self:buildFavoriteFolderItems() end,
                },
                {
                    text = _("Charm Types") .. " ◇",
                    keep_menu_open = true,
                    sub_item_table_func = function() return self:buildCharmTypeItems() end,
                },
                {
                    text = _("Day/Night Pair") .. " ☀☾",
                    sub_item_table = self:buildDayNightPairItems(),
                },
                {
                    text = _("Manage Charms") .. " ✧",
                    sub_item_table = self:buildSetCharmItems(),
                },
                {
                    text = _("Troubleshooting") .. " ⚙",
                    keep_menu_open = false,
                    callback = function() self:showTroubleshooting() end,
                },
                {
                    text = _("Help") .. " ✎",
                    keep_menu_open = false,
                    callback = function() self:showHelp() end,
                },
                {
                    text = _("About") .. " ⓘ",
                    keep_menu_open = true,
                    sub_item_table = {
                        {
                            text = _("Version") .. " " .. PLUGIN_VERSION,
                            bold = true,
                            keep_menu_open = true,
                            callback = function() end,
                        },
                        {
                            text = _("Made by") .. " " .. PLUGIN_AUTHOR,
                            bold = true,
                            keep_menu_open = true,
                            callback = function() end,
                        },
                        {
                            text = _("Fork modified by") .. " " .. PLUGIN_FORK_AUTHOR,
                            bold = true,
                            keep_menu_open = true,
                            callback = function() end,
                        },
                    },
                },
            }
        end,
    }
end

return BookmarkChrome









local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("dogearbooks_i18n")

local Screen = Device.screen
local GalleryDialog = ButtonDialog:extend{ modal = true, stop_events_propagation = true }
local MAX_PREVIEW_SIZE = 144
local PREVIEW_INTERVAL = 0.015

function GalleryDialog:onTapClose()
    return true
end

function GalleryDialog:onCloseWidget()
    if self.preview_step then
        UIManager:unschedule(self.preview_step)
        self.preview_step = nil
    end
    local region = self.movable.dimen
    if region then UIManager:setDirty(nil, "ui", region) end
    if self.favorite_badge then
        self.favorite_badge:free()
        self.favorite_badge = nil
    end
    self:free()
end

function GalleryDialog:loadPreviews(previews)
    if #previews == 0 then return end

    local index = 1
    self.preview_step = function()
        previews[index]:loadPreview()
        index = index + 1
        if index <= #previews then
            -- A positive delay gives KOReader a chance to process input before the next decode.
            UIManager:scheduleIn(PREVIEW_INTERVAL, self.preview_step)
        else
            self.preview_step = nil
            local region = self.movable.dimen
            if region then UIManager:setDirty(self, "ui", region) end
        end
    end
    UIManager:scheduleIn(PREVIEW_INTERVAL, self.preview_step)
end

local function selectButton(button)
    if button.enabled then button.callback() end
    return true
end

local function paintFavoriteButton(button, bb, x, y)
    Button.paintTo(button, bb, x, y)
    if not button.favorite then return end

    local badge = button.show_parent.favorite_badge
    local size = badge:getSize()
    local padding = Size.padding.button
    local badge_x = x + button.dimen.w - size.w - 2 * padding
    local badge_y = y + padding
    bb:paintRect(badge_x - padding, badge_y, size.w + 2 * padding, size.h, Blitbuffer.COLOR_WHITE)
    badge:paintTo(bb, badge_x, badge_y)
end

return function(options)
    local width = math.floor(math.min(Screen:getWidth() * 0.92, Screen:getHeight() * 1.25))
    local columns = width < Screen:scaleBySize(360) and 2 or 3
    local tile_width = math.max(1, math.floor((width - 2 * Size.border.window - 2 * Size.padding.button
        - (columns - 1) * Size.line.medium) / columns))
    local available_height = math.max(36, Screen:getHeight() - Screen:scaleBySize(230))
    local rows = math.max(1, math.min(3, math.floor(available_height / tile_width)))
    local tile_height = math.min(tile_width, math.floor(available_height / rows))
    local preview_size = math.max(1, math.min(MAX_PREVIEW_SIZE, math.min(tile_width, tile_height) - 4 * Size.padding.button))
    local page_size = rows * columns
    local page_count = math.max(1, math.ceil(#options.designs / page_size))
    local mirrored = BD.mirroredUILayout()
    local favorite_paths = #options.designs > 0 and options.favorite_paths() or {}
    local dialog

    local function showPage(page)
        if dialog then UIManager:close(dialog) end

        local buttons = {}
        local first_index = (page - 1) * page_size + 1
        local last_index = math.min(page * page_size, #options.designs)
        for index = first_index, last_index do
            local design = options.designs[index]
            if (index - first_index) % columns == 0 then
                buttons[#buttons + 1] = {}
            end
            local row = buttons[#buttons]
            row[#row + 1] = {
                id = index,
                text = "",
                width = tile_width,
                height = tile_height,
                callback = function()
                    UIManager:close(dialog)
                    options.select(design, index)
                end,
                hold_callback = function()
                    if dialog.preview_step then return end
                    options.toggle_favorite(design)
                    favorite_paths = options.favorite_paths()
                    for tile_index = first_index, last_index do
                        local tile = dialog:getButtonById(tile_index)
                        tile.favorite = favorite_paths[options.designs[tile_index].path]
                    end
                    local region = dialog.movable.dimen
                    if region then UIManager:setDirty(dialog, "ui", region) end
                end,
            }
        end
        if page_count > 1 then
            buttons[#buttons + 1] = {
                { id = "prev", text = mirrored and "▶" or "◀", enabled = page > 1,
                    callback = function() showPage(page - 1) end },
                { text = page .. " / " .. page_count, enabled = false, font_bold = false },
                { id = "next", text = mirrored and "◀" or "▶", enabled = page < page_count,
                    callback = function() showPage(page + 1) end },
            }
        end

        local actions = {}
        if options.action then
            actions[#actions + 1] = {
                text = options.action.text,
                callback = function()
                    UIManager:close(dialog)
                    options.action.callback()
                end,
            }
        end
        actions[#actions + 1] = { text = _("Cancel"), callback = function() UIManager:close(dialog) end }
        buttons[#buttons + 1] = actions
        dialog = GalleryDialog:new{
            title = last_index == 0 and (options.title .. "\n" .. options.empty_message) or options.title,
            title_align = "center",
            width = width,
            buttons = buttons,
        }
        if last_index >= first_index then
            dialog.favorite_badge = TextWidget:new{
                text = "★",
                face = Font:getFace("cfont", 16),
            }
        end
        local previews = {}
        for index = first_index, last_index do
            local button = dialog:getButtonById(index)
            local preview = options.set_preview(button, options.designs[index].path, preview_size, true)
            button.favorite = favorite_paths[options.designs[index].path]
            button.paintTo = paintFavoriteButton
            previews[#previews + 1] = preview
            button.onTapSelectButton = function(widget)
                if dialog.preview_step then return true end
                return selectButton(widget)
            end
        end
        if page_count > 1 then
            dialog:getButtonById("prev").onTapSelectButton = selectButton
            dialog:getButtonById("next").onTapSelectButton = selectButton
        end
        UIManager:show(dialog)
        dialog:loadPreviews(previews)
    end

    showPage(math.floor((math.max(1, options.selected_index or 1) - 1) / page_size) + 1)
end

-- RGMercs User Module: Power Source Manager
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/powersource_manager.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "PowerSourceManager"
--
-- Watches your equipped Power Source slot. When it depletes, destroys the
-- spent item and equips a fresh one from your inventory - so it doesn't just
-- sit there empty after the old one runs out.
--
-- Which item counts as "the" Power Source is set with a drop target on the
-- Options panel (gear icon on this tab) - the same "Drop Here" control
-- RGMercs uses for Mount Item / Shrink Item.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Icons    = require('mq.ICONS')
local Base     = require("modules.base")
local Config   = require('utils.config')
local Core     = require("utils.core")
local Globals  = require("utils.globals")
local Logger   = require("utils.logger")
local Ui       = require("utils.ui")

local Module   = {
    _version = '1.0',
    _name    = "PowerSourceManager",
    _author  = "Cannonballdex",
    _about   = "Destroys a depleted Power Source and equips a fresh one from inventory automatically.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

Module.FAQ = {
    {
        Question = "Why didn't it equip a replacement?",
        Answer   = "It only equips the specific item dropped onto the Power Source Item control (Options panel, " ..
            "gear icon on this tab). If nothing is set there, or you're out of spares in your bags, nothing will be " ..
            "equipped.",
        Settings_Used = "PSMItemName,PSMAutoReplace",
    },
    {
        Question = "Why was my dropped item rejected?",
        Answer   = "Only items that can actually be worn in the Power Source slot are accepted - anything else is " ..
            "rejected and the previous value is kept, so a stray drag-and-drop can't accidentally point this module " ..
            "at, say, a food item.",
        Settings_Used = "PSMItemName",
    },
}

--- Checks whether a resolved item TLO can be worn in the Power Source slot.
--- @param item any The item TLO to check (e.g. mq.TLO.Cursor or a mq.TLO.FindItem() result).
--- @return boolean isPowerSource True if the item can be equipped in the Power Source slot.
local function ItemIsPowerSource(item)
    return item ~= nil and item() ~= nil and item.WornSlot("powersource")() == true
end

--- Resolves an item by name to a TLO reference, preferring what's on the cursor
--- (since a just-dropped item is still there when this fires) and falling back
--- to an exact-name inventory search.
--- @param itemName string
--- @return any item
local function ResolveItemByName(itemName)
    if mq.TLO.Cursor() and mq.TLO.Cursor.Name() == itemName then
        return mq.TLO.Cursor
    end
    return mq.TLO.FindItem(string.format("=%s", itemName))
end

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['PSMEnabled'] = {
        DisplayName = "Enable Power Source Management",
        Category = Module._name,
        Index = 1,
        Tooltip = "Master toggle for automatically destroying depleted Power Sources and equipping replacements.",
        Default = true,
    },
    ['PSMDestroyDepleted'] = {
        DisplayName = "Destroy Depleted Power Source",
        Category = Module._name,
        Index = 2,
        Tooltip = "Automatically destroy the equipped Power Source once it hits 0 charge.",
        Default = true,
    },
    ['PSMAutoReplace'] = {
        DisplayName = "Auto-Equip Replacement",
        Category = Module._name,
        Index = 3,
        Tooltip = "Automatically equip a fresh Power Source from inventory when the slot is empty or depleted.",
        Default = true,
    },
    ['PSMItemName'] = {
        DisplayName = "Power Source Item",
        Category = Module._name,
        Index = 4,
        Tooltip = "Drop your Power Source item here. Only items that can be worn in the Power Source slot are accepted.",
        Type = "ClickyItem",
        Default = "",
        OnChange = function(oldValue, newValue)
            if newValue == nil or newValue == "" then return end

            if not ItemIsPowerSource(ResolveItemByName(newValue)) then
                Logger.log_error("\arPowerSourceManager: \at%s\ar can't be worn in the Power Source slot - rejected.", newValue)
                Config:SetSetting('PSMItemName', oldValue or "", false, true)
            end
        end,
    },
    ['PSMCheckIntervalSec'] = {
        DisplayName = "Check Interval (Seconds)",
        Category = Module._name,
        Index = 5,
        Tooltip = "How often to check the Power Source slot. It's cheap, but there's no need to check every frame.",
        Default = 5,
        Min = 1,
        Max = 60,
    },
}

Module.CommandHandlers = {
    powersource = {
        usage = "/rgl powersource check",
        about = "Force an immediate Power Source check, bypassing the check interval.",
        handler = function(self, sub)
            if (sub or ""):lower() == "check" then
                self.lastCheck = 0
                self:CheckPowerSource()
                Logger.log_info("\ayPowerSourceManager: forced check complete.")
            end
            return true
        end,
    },
}

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.lastCheck = 0
    self.lastAction = nil
end

function Module:ShouldRender()
    return true
end

--- Picks up whatever is in the Power Source slot right now and puts it on the cursor.
--- @return string|nil name The item name that was in the slot, or nil if the slot was empty.
function Module:PullSlotToCursor()
    local slot = mq.TLO.Me.Inventory('powersource')
    local name = slot() ~= nil and slot.Name() or nil
    if not name then return nil end

    Core.DoCmd('/ctrl /itemnotify powersource leftmouseup')
    mq.delay(1000, function() return mq.TLO.Cursor.ID() ~= nil end)
    return name
end

--- Puts back / stashes whatever is currently on the cursor.
function Module:ClearCursor()
    if not mq.TLO.Cursor.ID() then return end
    Core.DoCmd('/autoinv')
    mq.delay(1000, function() return mq.TLO.Cursor.ID() == nil end)
end

--- Destroys the equipped Power Source if it's fully depleted.
--- @return boolean destroyed True if a depleted Power Source was destroyed.
function Module:DestroyDepleted()
    local slot = mq.TLO.Me.Inventory('powersource')
    if slot() == nil then return false end

    local name = slot.Name()
    local power = slot.Power() or 0
    if power > 0 then return false end

    local pulledName = self:PullSlotToCursor()
    if not pulledName then return false end

    if mq.TLO.Cursor.Name() ~= pulledName or (mq.TLO.Cursor.Power() or 0) ~= 0 then
        -- Didn't get the item we expected, or it's not actually empty. Don't risk destroying the wrong thing.
        self:ClearCursor()
        return false
    end

    Core.DoCmd('/destroy')
    mq.delay(1000, function() return mq.TLO.Cursor.ID() == nil end)

    self.lastAction = string.format("Destroyed spent Power Source: %s", name)
    Logger.log_info("\arPowerSourceManager: \apDestroyed spent Power Source: %s", name)
    return true
end

--- Equips a fresh Power Source from inventory if the slot is empty or depleted.
--- @return boolean equipped True if a replacement was equipped.
function Module:EquipReplacement()
    local slot = mq.TLO.Me.Inventory('powersource')
    if slot() ~= nil and (slot.Power() or 0) > 0 then return false end

    local itemName = Config:GetSetting('PSMItemName')
    if not itemName or itemName == "" then return false end

    local newSource = mq.TLO.FindItem(string.format("=%s", itemName))
    if not ItemIsPowerSource(newSource) then return false end
    if not newSource or not newSource() or (newSource.Power() or 0) <= 0 then return false end

    local newName = newSource.Name()

    Core.DoCmd('/itemnotify "%s" leftmouseup', newName)
    mq.delay(1000, function() return mq.TLO.Cursor.ID() ~= nil end)

    if mq.TLO.Cursor.Name() == newName then
        Core.DoCmd('/ctrl /itemnotify powersource leftmouseup')
        mq.delay(1000, function() return mq.TLO.Me.Inventory('powersource').Name() == newName end)
    end

    if mq.TLO.Window('ConfirmationDialogBox').Open() then
        mq.TLO.Window('ConfirmationDialogBox').Child('CD_Yes_Button').LeftMouseUp()
        mq.delay(500)
    end

    self:ClearCursor()

    local equipped = mq.TLO.Me.Inventory('powersource').Name() == newName
    if equipped then
        self.lastAction = string.format("Equipped Power Source: %s", newName)
        Logger.log_info("\agPowerSourceManager: \atEquipped Power Source: %s", newName)
    end
    return equipped
end

--- If no Power Source Item is configured, adopts whatever's currently equipped as the
--- configured item. Self-heals from the setting ever being empty (a fresh install, a
--- lost/never-saved value, etc.) without needing the user to re-drop it manually.
function Module:LearnEquippedItemIfUnset()
    if Config:GetSetting('PSMItemName') ~= "" then return end

    local slot = mq.TLO.Me.Inventory('powersource')
    local name = slot() ~= nil and slot.Name() or nil
    if not name then return end

    Config:SetSetting('PSMItemName', name)
    self.lastAction = string.format("Learned Power Source from equipped item: %s", name)
    Logger.log_info("\agPowerSourceManager: \ayNo Power Source Item was configured - learned it from your currently equipped item: \at%s", name)
end

--- Runs one full destroy-then-replace pass, ignoring the check interval.
function Module:CheckPowerSource()
    if Config:GetSetting('PSMDestroyDepleted') then
        self:DestroyDepleted()
    end

    if Config:GetSetting('PSMAutoReplace') then
        self:EquipReplacement()
    end
end

function Module:GiveTime()
    if not Config:GetSetting('PSMEnabled') then return end

    self:LearnEquippedItemIfUnset()

    local now = Globals.GetTimeSeconds()
    local interval = Config:GetSetting('PSMCheckIntervalSec') or 5
    if now - self.lastCheck < interval then return end
    self.lastCheck = now

    self:CheckPowerSource()
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    local slot = mq.TLO.Me.Inventory('powersource')
    local name = slot() ~= nil and slot.Name() or nil
    local power = slot() ~= nil and slot.Power() or nil

    ImGui.Text("Equipped Power Source:")
    ImGui.SameLine()
    if not name then
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionFailColor, "None")
    elseif (power or 0) <= 0 then
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionFailColor, "%s (Depleted)", name)
    else
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionPassColor, "%s (%d)", name, power)
    end

    if self.lastAction then
        ImGui.Spacing()
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionMidColor, "Last action: %s", self.lastAction)
    end

    ImGui.Text("Power Source Item:")
    local newItemName, _, itemPressed = Ui.RenderOption("ClickyItem", Config:GetSetting('PSMItemName'), "PSMItemName_tab", false)
    if itemPressed then
        Config:SetSetting('PSMItemName', newItemName)

        -- Dropping an item here is a direct request to use it now, not just a preference for later.
        -- GiveTime() runs on the main script loop and can safely mq.delay(); Render() runs inside
        -- ImGui's draw pass and CANNOT - so just wake the interval check instead of equipping here.
        self.lastCheck = 0
    end
    Ui.Tooltip("Pick up your Power Source item, then click here to drop it in and equip it immediately.")

    ImGui.Spacing()
    if ImGui.SmallButton(Icons.MD_REFRESH .. " Check Now") then
        self.lastCheck = 0
    end
    Ui.Tooltip("Runs a check immediately instead of waiting for the check interval.")
end

return Module

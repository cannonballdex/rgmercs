-- RGMercs User Module: Destroy Mod Rods
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/destroy_mod_rods.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "DestroyModRods"
--
-- Classes without mana (warrior, rogue, monk, berserker) can't use mod rods,
-- so when a mage hands one out it just clutters the cursor or a bag slot.
-- This destroys known mod rods on those characters. It does nothing on any
-- character that has a mana pool.

local mq      = require('mq')
local ImGui   = require('ImGui')
local Base    = require("modules.base")
local Config  = require('utils.config')
local Globals = require("utils.globals")
local Logger  = require("utils.logger")

local Module  = {
    _version = '1.0',
    _name    = "DestroyModRods",
    _author  = "Cannonballdex",
    _about   = "On classes without mana, destroys mod rods from the cursor and (optionally) from your bags.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

-- Exact names; a name also matches with a rank suffix ("Summoned: Modulation Shard" matches "... Modulation Shard IX").
Module.ModRodNames = {
    "Wand of Pelagic Transvergence",
    "Wand of Phantasmal Transvergence",
    "Summoned: Modulation Shard",
    "Summoned: Giant Modulation Shard",
    "Summoned: Large Modulation Shard",
    "Summoned: Dazzling Modulation Shard",
    "Summoned: Radiant Modulation Shard",
    "Summoned: Glowing Modulation Shard",
    "Summoned: Modulation Shard VIII",
    "Rod of Prime Transvergence",
    "Rod of Mystical Transvergence",
    "Rod of Ethereal Transvergence",
    "Rod of Elemental Transvergence",
    "Rod of Arcane Transvergence",
}

-- Leave items alone while you're trading, banking, looting or at a merchant.
Module.BusyWindows = { "TradeWnd", "GiveWnd", "MerchantWnd", "BigBankWnd", "LootWnd", "AdvancedLootWnd", }

Module.FAQ = {
    {
        Question = "Will this ever destroy something that isn't a mod rod?",
        Answer   = "It only destroys an item whose name is on its built-in mod rod list (or that name plus a rank suffix), " ..
            "and it re-checks the name on your cursor right before each /destroy. If anything else is on your cursor it does nothing.",
        Settings_Used = "MRDCheckBags",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['MRDCheckBags'] = {
        DisplayName = "Also Destroy Rods In Bags",
        Category = Module._name,
        Index = 1,
        Tooltip = "Also find mod rods already in your bags and destroy them (out of combat, and not while trading, banking, looting or at a merchant). " ..
            "Off: only rods on your cursor are destroyed.",
        Default = true,
    },
    ['MRDShowTab'] = {
        DisplayName = "Show DestroyModRods Tab",
        Category = Module._name,
        Index = 2,
        Tooltip = "Add a DestroyModRods tab to the main window. Turn off to have it run quietly.",
        Default = true,
    },
}

--- True if name is a known mod rod: an exact list entry, or a list entry followed by a space and a suffix.
---@param name string?
---@return boolean
function Module.IsModRod(name)
    if not name or name == "" then return false end
    for _, rod in ipairs(Module.ModRodNames) do
        if name == rod or name:sub(1, #rod + 1) == rod .. " " then return true end
    end
    return false
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.destroyedCount  = 0
    self.lastDestroyed   = ""
    self.status          = "Starting"
    self.destroyAt       = false -- when to destroy the rod seen on the cursor (short settle delay)
    self.pickupAt        = false -- when we last picked a rod up out of a bag
    self.lastTick        = 0
    self.lastBagScan     = 0
end

function Module:ShouldRender()
    return Config:GetSetting('MRDShowTab') and true or false
end

function Module:AnyBusyWindowOpen()
    for _, wnd in ipairs(Module.BusyWindows) do
        if mq.TLO.Window(wnd).Open() then return true end
    end
    return false
end

function Module:GiveTime()
    local now = Globals.GetTimeSeconds()
    if now - self.lastTick < 0.5 then return end
    self.lastTick = now

    if (mq.TLO.Me.MaxMana() or 0) > 0 then
        self.status = "Inactive: this class has mana"
        return
    end

    local cursorName = mq.TLO.Cursor.Name()
    if cursorName then
        if not Module.IsModRod(cursorName) then
            -- something else is on the cursor; never touch it
            self.destroyAt, self.pickupAt = false, false
            self.status = "Waiting: cursor holds another item"
            return
        end

        if not self.destroyAt then
            self.destroyAt = now + 0.3
            return
        end
        if now < self.destroyAt then return end

        -- re-check right before destroying: /destroy has no confirmation
        if Module.IsModRod(mq.TLO.Cursor.Name()) then
            local name = mq.TLO.Cursor.Name()
            mq.cmd("/destroy")
            self.destroyedCount = self.destroyedCount + 1
            self.lastDestroyed  = name
            Logger.log_info("\ayDestroyModRods: \awdestroyed \am%s\aw (no mana to use it).", name)
        end
        self.destroyAt, self.pickupAt = false, false
        return
    end

    self.destroyAt = false
    self.status = "Watching"

    -- a bag pickup is in flight; give it time to land on the cursor
    if self.pickupAt and now - self.pickupAt < 2 then return end
    self.pickupAt = false

    if not Config:GetSetting('MRDCheckBags') then return end
    if Globals.CurrentState == "Combat" then return end
    if now - self.lastBagScan < 3 then return end
    self.lastBagScan = now
    if self:AnyBusyWindowOpen() then return end

    for _, rod in ipairs(Module.ModRodNames) do
        local item = mq.TLO.FindItem(rod)
        local fullName = item() and item.Name() or nil
        if fullName and Module.IsModRod(fullName) then
            -- /itemnotify needs the full name; /nomodkey so a held Shift can't toggle the slot lock
            mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', fullName)
            self.pickupAt = now
            self.status = "Picking up " .. fullName
            return
        end
    end
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    ImGui.Text("Status:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(0.6, 0.9, 1.0, 1.0), self.status or "")
    ImGui.Text(string.format("Destroyed this session: %d", self.destroyedCount or 0))
    if (self.lastDestroyed or "") ~= "" then
        ImGui.Text("Last destroyed: " .. self.lastDestroyed)
    end
    if ImGui.CollapsingHeader("Mod rods this destroys") then
        for _, rod in ipairs(Module.ModRodNames) do
            ImGui.BulletText(rod)
        end
    end
end

return Module

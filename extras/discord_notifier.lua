-- RGMercs User Module: Discord Notifier
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/discord_notifier.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "DiscordNotifier"
--   3. Set the Discord Webhook URL setting (Discord: Channel Settings ->
--      Integrations -> Webhooks -> New Webhook -> Copy URL).
--
-- Posts to a Discord webhook on events you choose: named mob killed, you
-- died, or your inventory is nearly full. Uses curl.exe (built into Windows
-- 10/11) via os.execute, since MQ Lua has no built-in HTTP client. Writes
-- the JSON payload to a temp file and posts it with curl -d @file, to avoid
-- the nested-quoting mess of passing JSON inline through cmd.exe.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Base     = require("modules.base")
local Config   = require('utils.config')
local Globals  = require("utils.globals")
local Logger   = require("utils.logger")
local Modules  = require("utils.modules")

local Module   = {
    _version = '1.0',
    _name    = "DiscordNotifier",
    _author  = "Cannonballdex",
    _about   = "Posts to a Discord webhook on named kills, death, or low inventory space.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "How do I get a webhook URL?",
        Answer   = "In Discord: Channel Settings -> Integrations -> Webhooks -> New Webhook -> Copy Webhook URL. " ..
            "Paste it into the Discord Webhook URL setting below. Nothing posts until a URL is set.",
        Settings_Used = "DiscordWebhookUrl",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['DiscordWebhookUrl'] = {
        DisplayName = "Discord Webhook URL",
        Category = Module._name,
        Index = 1,
        Tooltip = "Paste a Discord channel webhook URL here. Leave blank to disable posting entirely.",
        Default = "",
    },
    ['DiscordNotifyNamed'] = {
        DisplayName = "Notify on Named Kill",
        Category = Module._name,
        Index = 2,
        Tooltip = "Post when you kill a mob flagged as Named.",
        Default = true,
    },
    ['DiscordNotifyDeath'] = {
        DisplayName = "Notify on Death",
        Category = Module._name,
        Index = 3,
        Tooltip = "Post when you die.",
        Default = true,
    },
    ['DiscordNotifyLowInv'] = {
        DisplayName = "Notify on Low Inventory",
        Category = Module._name,
        Index = 4,
        Tooltip = "Post once when your free inventory slots drop to or below the threshold below.",
        Default = false,
    },
    ['DiscordLowInvThreshold'] = {
        DisplayName = "Low Inventory Threshold",
        Category = Module._name,
        Index = 5,
        Tooltip = "Free inventory slots at or below this triggers the low-inventory notice (once, until it recovers above it).",
        Default = 2,
        Min = 0,
        Max = 20,
    },
}

local function EscapeJson(text)
    text = tostring(text or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("\n", " ")
    text = text:gsub("\r", "")
    return text
end

function Module:Post(message)
    local url = Config:GetSetting('DiscordWebhookUrl')
    if not url or url == "" then return end

    local who     = Globals.CurLoadedChar or mq.TLO.Me.DisplayName() or "RGMercs"
    local content = EscapeJson(string.format("**%s**: %s", who, message))
    local json    = string.format('{"content":"%s"}', content)

    local tmpPath = string.format("%s/rgmercs_discord_payload.json", mq.configDir)
    local f = io.open(tmpPath, "w")
    if not f then
        Logger.log_error("\arDiscordNotifier: could not write temp payload file.")
        return
    end
    f:write(json)
    f:close()

    os.execute(string.format('curl -s -X POST -H "Content-Type: application/json" -d @"%s" "%s" >nul 2>&1', tmpPath, url))
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.lastNamedName = nil
    self.lowInvWarned  = false

    self._slainEvent = "RGMercsDiscordSlain"
    mq.event(self._slainEvent, "You have slain #victim#!", function(_, victim)
        if not Config:GetSetting('DiscordNotifyNamed') then return end
        if self.lastNamedName and victim and victim:lower():find(self.lastNamedName:lower(), 1, true) then
            self:Post(string.format("killed a named mob: **%s**", victim))
        end
    end)
end

function Module:Shutdown()
    if self._slainEvent then
        mq.unevent(self._slainEvent)
        self._slainEvent = nil
    end
    Base.Shutdown(self)
end

function Module:OnDeath()
    if not Config:GetSetting('DiscordNotifyDeath') then return end
    local zone = mq.TLO.Zone() or "an unknown zone"
    self:Post(string.format("died in **%s**.", zone))
end

function Module:GiveTime()
    local target = mq.TLO.Target
    if target() and target.Type() == "NPC" then
        local ok, isNamed = pcall(function() return Modules:ExecModule("Named", "IsNamed", target) end)
        if ok and isNamed then
            self.lastNamedName = target.CleanName() or target.Name()
        end
    end

    if Config:GetSetting('DiscordNotifyLowInv') then
        local free      = mq.TLO.Me.FreeInventory(3)() or 99
        local threshold = Config:GetSetting('DiscordLowInvThreshold') or 2
        if free <= threshold and not self.lowInvWarned then
            self.lowInvWarned = true
            self:Post(string.format("inventory is low: **%d** free slot(s) left.", free))
        elseif free > threshold then
            self.lowInvWarned = false
        end
    end
end

function Module:ShouldRender()
    return true
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    local url = Config:GetSetting('DiscordWebhookUrl')
    if not url or url == "" then
        ImGui.TextColored(ImVec4(1.0, 0.6, 0.2, 1.0), "No webhook URL set - nothing will post. See the FAQ tab.")
    else
        ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), "Webhook configured.")
    end

    ImGui.Spacing()
    if ImGui.SmallButton("Send Test Message") then
        self:Post("test message from RGMercs.")
    end
end

return Module

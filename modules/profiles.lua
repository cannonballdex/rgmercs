local mq       = require('mq')
local ImGui    = require('ImGui')
local Base     = require("modules.base")
local Config   = require('utils.config')
local Core     = require("utils.core")
local Globals  = require("utils.globals")
local Logger   = require("utils.logger")

local Module   = { _version = '1.0', _name = "Profiles", _author = 'Cannonballdex', }
Module.__index = Module
setmetatable(Module, { __index = Base, })

Module.FAQ = {
    {
        Question = "How do I save/load a settings profile?",
        Answer   = "/rgl profile save <name> snapshots your character's current class settings under <name>. " ..
            "/rgl profile load <name> writes that snapshot into the database -- most settings (like Pull settings) " ..
            "apply immediately; any new colors or modules will reload after restarting RGMercs, the same way DB " ..
            "Management's character-to-character copy works. It only works if the profile was saved by a character " ..
            "of the same class as you, to avoid applying class-inappropriate settings. /rgl profile list shows all " ..
            "saved profiles, and /rgl profile delete <name> removes one.",
        Settings_Used = "",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
}

Module.CommandHandlers = {
    profile = {
        usage = "/rgl profile <save|load|list|delete> [name]",
        about = "Save, load, list, or delete named settings profiles.",
        handler = function(self, action, name)
            action = (action or ""):lower()

            if action == "save" then
                if not name or name == "" then
                    Logger.log_error("\arUsage: /rgl profile save <name>")
                    return true
                end
                Config:SaveProfile(name)
                return true
            elseif action == "load" then
                if not name or name == "" then
                    Logger.log_error("\arUsage: /rgl profile load <name>")
                    return true
                end
                Config:LoadProfile(name)
                return true
            elseif action == "delete" then
                if not name or name == "" then
                    Logger.log_error("\arUsage: /rgl profile delete <name>")
                    return true
                end
                Config:DeleteProfile(name)
                return true
            elseif action == "list" then
                local profiles = Config:ListProfiles()
                if #profiles == 0 then
                    Logger.log_info("\ayNo saved profiles.")
                    return true
                end
                Logger.log_info("\aySaved Profiles:")
                for _, p in ipairs(profiles) do
                    Logger.log_info("  \at%s\aw (class: \ag%s\aw)", p.name, p.class)
                end
                return true
            else
                Logger.log_error("\arUsage: /rgl profile <save|load|list|delete> [name]")
                return true
            end
        end,
    },
}

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.newProfileName = ""
    self.pendingDeleteProfile = nil
    self.pendingOverwriteProfile = nil
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    ImGui.TextWrapped("Saved settings can be used on other same-class characters.")
    ImGui.TextColored(ImVec4(1, 0.8, 0.2, 1), "New colors or modules will reload when restarting RGMercs.")
    ImGui.SameLine()
    if ImGui.Button("Restart RGMercs##rg_profile_restart") then
        ImGui.OpenPopup("RGProfileRestartConfirm")
    end

    ImGui.SetNextWindowSize(ImVec2(360, 0), ImGuiCond.Appearing)
    if ImGui.BeginPopup("RGProfileRestartConfirm") then
        ImGui.TextWrapped("Restart RGMercs now? This briefly interrupts whatever it's currently doing, and can take a few seconds.")
        ImGui.Spacing()
        if ImGui.Button("Restart##rg_profile_restart_confirm") then
            -- /timed is handled by MQ2's own timer, not this script instance, so it
            -- survives /lua stop killing us -- queue the relaunch before stopping,
            -- same pattern modules/lootnscoot.lua uses for the identical problem.
            Core.DoCmd('/timed 30 /lua run rgmercs')
            Core.DoCmd('/lua stop rgmercs')
            ImGui.CloseCurrentPopup()
        end
        ImGui.SameLine()
        if ImGui.Button("Cancel##rg_profile_restart_cancel") then
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    end

    ImGui.Separator()

    local profiles = Config:ListProfiles()
    local existing = nil
    for _, p in ipairs(profiles) do
        if p.name == self.newProfileName then existing = p end
    end

    ImGui.SetNextItemWidth(220)
    self.newProfileName = ImGui.InputText("##rg_profile_name", self.newProfileName or "")
    ImGui.SameLine()

    local canSave = self.newProfileName ~= nil and self.newProfileName ~= ""
    if not canSave then ImGui.BeginDisabled() end
    if ImGui.Button("Save Current Settings##rg_profile_save") then
        if existing then
            self.pendingOverwriteProfile = self.newProfileName
            ImGui.OpenPopup("RGProfileOverwriteConfirm")
        else
            Config:SaveProfile(self.newProfileName)
        end
    end
    if not canSave then ImGui.EndDisabled() end
    ImGui.TextDisabled(string.format("Saves as class: %s", Globals.CurLoadedClass))

    ImGui.SetNextWindowSize(ImVec2(380, 0), ImGuiCond.Appearing)
    if ImGui.BeginPopup("RGProfileOverwriteConfirm") then
        ImGui.TextWrapped(string.format("A profile named '%s' already exists (class: %s). Overwrite it with your current settings?",
            self.pendingOverwriteProfile or "", existing and existing.class or "?"))
        ImGui.Spacing()
        if ImGui.Button("Overwrite##rg_profile_overwrite_confirm") then
            Config:SaveProfile(self.pendingOverwriteProfile)
            self.pendingOverwriteProfile = nil
            ImGui.CloseCurrentPopup()
        end
        ImGui.SameLine()
        if ImGui.Button("Cancel##rg_profile_overwrite_cancel") then
            self.pendingOverwriteProfile = nil
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    end

    ImGui.Separator()
    ImGui.Text(string.format("Saved Profiles (%d):", #profiles))
    if #profiles == 0 then
        ImGui.TextDisabled("None yet.")
        return
    end

    if ImGui.BeginTable("rg_profiles_table", 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.SizingStretchProp) then
        ImGui.TableSetupColumn("Name")
        ImGui.TableSetupColumn("Class")
        ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableHeadersRow()

        for _, p in ipairs(profiles) do
            ImGui.TableNextRow()

            ImGui.TableSetColumnIndex(0)
            ImGui.Text(p.name)

            ImGui.TableSetColumnIndex(1)
            ImGui.Text(p.class)

            ImGui.TableSetColumnIndex(2)
            local classMatches = p.class == Globals.CurLoadedClass
            if not classMatches then ImGui.BeginDisabled() end
            if ImGui.Button("Load##rg_profile_load_" .. p.name) then
                Config:LoadProfile(p.name)
            end
            if not classMatches then
                ImGui.EndDisabled()
                if ImGui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled) then
                    ImGui.SetTooltip(string.format("Saved for class %s -- doesn't match your current class %s.", p.class, Globals.CurLoadedClass))
                end
            end

            ImGui.TableSetColumnIndex(3)
            if ImGui.Button("Delete##rg_profile_delete_" .. p.name) then
                self.pendingDeleteProfile = p.name
                ImGui.OpenPopup("RGProfileDeleteConfirm")
            end
        end
        ImGui.EndTable()
    end

    ImGui.SetNextWindowSize(ImVec2(360, 0), ImGuiCond.Appearing)
    if ImGui.BeginPopup("RGProfileDeleteConfirm") then
        ImGui.TextWrapped(string.format("Delete profile '%s'? This can't be undone.", self.pendingDeleteProfile or ""))
        ImGui.Spacing()
        if ImGui.Button("Delete##rg_profile_delete_confirm") then
            Config:DeleteProfile(self.pendingDeleteProfile)
            self.pendingDeleteProfile = nil
            ImGui.CloseCurrentPopup()
        end
        ImGui.SameLine()
        if ImGui.Button("Cancel##rg_profile_delete_cancel") then
            self.pendingDeleteProfile = nil
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    end
end

return Module

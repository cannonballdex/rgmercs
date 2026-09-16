local mq       = require('mq')
local ImGui    = require('ImGui')
local Base     = require("modules.base")
local Config   = require('utils.config')
local Globals  = require("utils.globals")
local Logger   = require("utils.logger")

local Module   = { _version = '1.0', _name = "Profiles", _author = 'Cannonballdex', }
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Profile names are globally unique in the DB, so two characters saving a profile
-- called the same thing would silently overwrite each other. Prefixing with the
-- saving character's name keeps them distinct without needing a schema change.
local function FullProfileName(rawName)
    return string.format("%s_%s", Globals.CurLoadedChar, rawName)
end

Module.FAQ = {
    {
        Question = "How do I save/load a settings profile?",
        Answer   = "/rgl profile save <name> snapshots your character's current class settings, saved as " ..
            "<YourCharacterName>_<name> so different characters saving the same name don't collide. /rgl profile " ..
            "load <name> writes that snapshot into the database and reloads settings automatically (the same " ..
            "reload the Class tab's 'Reload Current Config' button uses), so it takes effect right away without a " ..
            "restart. It only works if the profile was saved by a character of the same class as you, to avoid " ..
            "applying class-inappropriate settings. /rgl profile list shows all saved profiles (with their full " ..
            "stored name), and /rgl profile delete <name> removes one.",
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
                Config:SaveProfile(FullProfileName(name))
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
    self.wantDeleteConfirm = nil
    self.showAllClasses = false
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    ImGui.TextWrapped("Saved settings can be used on other same-class characters.")
    ImGui.Separator()

    local allProfiles = Config:ListProfiles()
    local fullName = self.newProfileName ~= "" and FullProfileName(self.newProfileName) or ""
    local existing = nil
    for _, p in ipairs(allProfiles) do
        if p.name == fullName then existing = p end
    end

    ImGui.SetNextItemWidth(220)
    self.newProfileName = ImGui.InputText("##rg_profile_name", self.newProfileName or "")
    ImGui.SameLine()

    local canSave = self.newProfileName ~= nil and self.newProfileName ~= ""
    if not canSave then ImGui.BeginDisabled() end
    if ImGui.Button("Save Current Settings##rg_profile_save") then
        if existing then
            self.pendingOverwriteProfile = fullName
            ImGui.OpenPopup("RGProfileOverwriteConfirm")
        else
            Config:SaveProfile(fullName)
        end
    end
    if not canSave then ImGui.EndDisabled() end
    ImGui.TextDisabled(string.format("Saves as: %s (class: %s)", canSave and fullName or (Globals.CurLoadedChar .. "_..."), Globals.CurLoadedClass))

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

    local newShowAll, showAllChanged = ImGui.Checkbox("Show all classes##rg_profile_show_all", self.showAllClasses)
    if showAllChanged then self.showAllClasses = newShowAll end

    local profiles = allProfiles
    if not self.showAllClasses then
        profiles = {}
        for _, p in ipairs(allProfiles) do
            if p.class == Globals.CurLoadedClass then profiles[#profiles + 1] = p end
        end
    end

    ImGui.Text(string.format("Saved Profiles (%d):", #profiles))
    if #profiles == 0 then
        ImGui.TextDisabled(self.showAllClasses and "None yet." or string.format("None for %s yet.", Globals.CurLoadedClass))
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
                -- ImGui.OpenPopup() doesn't reliably work called from inside a table
                -- (BeginTable/EndTable) in this binding -- just record the request here
                -- and open the popup after EndTable, same as DB Management's own
                -- confirm popups do in ui/options.lua.
                self.wantDeleteConfirm = p.name
            end
        end
        ImGui.EndTable()
    end

    if self.wantDeleteConfirm then
        self.pendingDeleteProfile = self.wantDeleteConfirm
        self.wantDeleteConfirm = nil
        ImGui.OpenPopup("RGProfileDeleteConfirm")
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

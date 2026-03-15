local mq = require('mq')
local RGMercConfig = require("utils.rgmercs_config")
local RGMercModules = require("utils.rgmercs_modules")

---@class RGMercsModuleType
---@field _name string
---@field _version string
---@field _author string
---@field DoGetState fun(self: table): string

---@type DataType
local rgMercsModuleType = mq.DataType.new('RGMercsModule', {
    Members = {
        Name = function(_, self)
            if not self then
                return 'string', ''
            end

            return 'string', string.format(
                "RGMercs [Module: %s/%s] by: %s",
                tostring(self._name or "Unknown"),
                tostring(self._version or "Unknown"),
                tostring(self._author or "Unknown")
            )
        end,

        State = function(_, self)
            if not self then
                return 'string', 'Unavailable'
            end

            if type(self.DoGetState) == "function" then
                return 'string', tostring(self:DoGetState())
            end

            return 'string', 'Unavailable'
        end,
    },

    Methods = {},

    ToString = function(self)
        return tostring(self and self._name or "")
    end,
})

---@class RGMercsMainType
---@field _name string

---@type DataType
local rgMercsMainType = mq.DataType.new('RGMercsMain', {
    Members = {
        Paused = function()
            return 'bool', RGMercConfig.Globals.PauseMain
        end,

        State = function()
            return 'string', RGMercConfig.Globals.PauseMain and "Paused" or "Running"
        end,
    },

    Methods = {},

    ToString = function(self)
        return tostring(self and self._name or "RGMercs")
    end,
})

---@return MQType|string, table|string|boolean
local function RGMercsTLOHandler(param)
    if not param or param:len() == 0 then
        return rgMercsMainType, RGMercConfig
    end

    local key = param:lower()

    if key == "curable" then
        return 'string', string.format(
            "Disease: %d, Poison: %d, Curse: %d, Corruption: %d",
            mq.TLO.Me.Diseased.ID() or 0,
            mq.TLO.Me.Poisoned.ID() or 0,
            mq.TLO.Me.Cursed.ID() or 0,
            mq.TLO.Me.Corrupted.ID() or 0
        )
    end

    local module = RGMercModules:GetModule(param)
    return rgMercsModuleType, module or false
end

mq.AddTopLevelObject('RGMercs', RGMercsTLOHandler)
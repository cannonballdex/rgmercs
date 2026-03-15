local RGMercConfig = require("utils.rgmercs_config")
local RGMercsLogger = require("utils.rgmercs_logger")

local Module = {
    _version = '0.1a',
    _author = 'Derple',
}
Module.__index = Module

local default_module_order = {
    "Class",
    "Movement",
    "Pull",
    "Drag",
    "Charm",
    "Mez",
    "Travel",
    -- "Exp",
    "Named",
    "Perf",
    -- "Loot",
    "Contributors",
    "FAQ",
}

local emu_module_order = {
    "Class",
    "Movement",
    "Pull",
    "Drag",
    "Charm",
    "Mez",
    "Travel",
    -- "Exp",
    "Named",
    "Perf",
    "Loot",
    "Contributors",
    "FAQ",
}

---@return table
function Module.load()
    local buildType = RGMercConfig.Globals.BuildType
    local module_order = buildType == "Emu" and emu_module_order or default_module_order

    local newModule = setmetatable({
        modules = {
            Movement = require("modules.movement"):New(),
            Travel = require("modules.travel"):New(),
            Class = require("modules.class"):New(),
            Pull = require("modules.pull"):New(),
            Drag = require("modules.drag"):New(),
            Mez = require("modules.mez"):New(),
            Charm = require("modules.charm"):New(),
            Loot = buildType == "Emu" and require("modules.loot"):New() or nil,
            -- Exp = require("modules.experience"):New(),
            Named = require("modules.named"):New(),
            Perf = require("modules.performance"):New(),
            Contributors = require("modules.contributors"):New(),
            FAQ = require("modules.faq"):New(),
        },
        module_order = module_order,
    }, Module)

    return newModule
end

function Module:GetModuleList()
    return self.modules
end

function Module:GetModuleOrderedNames()
    return self.module_order
end

---@param m string
---@return table|nil
function Module:GetModule(m)
    if not m then
        return nil
    end

    for name, module in pairs(self.modules) do
        if name:lower() == m:lower() then
            return module
        end
    end

    return nil
end

function Module:ExecModule(m, fn, ...)
    if not m or not fn then
        RGMercsLogger.log_error("ExecModule called with invalid arguments: module=%s fn=%s", tostring(m), tostring(fn))
        return nil
    end

    local module = self:GetModule(m)
    if not module then
        RGMercsLogger.log_error("\arModule: \at%s\ar not found!", tostring(m))
        return nil
    end

    local method = module[fn]
    if type(method) ~= "function" then
        RGMercsLogger.log_error("\arFunction: \at%s\ar not found on module: \at%s\ar!", tostring(fn), tostring(m))
        return nil
    end

    return method(module, ...)
end

function Module:ExecAll(fn, ...)
    local ret = {}

    if not fn then
        RGMercsLogger.log_error("ExecAll called with invalid function name: %s", tostring(fn))
        return ret
    end

    for _, name in ipairs(self.module_order) do
        local startTime = os.clock() * 1000
        local module = self.modules[name]

        if module then
            local method = module[fn]
            if type(method) == "function" then
                ret[name] = method(module, ...)
            else
                ret[name] = nil
            end

            if fn == "GiveTime" and self.modules.Perf then
                self.modules.Perf:OnFrameExec(name, (os.clock() * 1000) - startTime)
            end
        else
            ret[name] = nil
        end
    end

    return ret
end

return Module
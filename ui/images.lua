local mq              = require('mq')
local Globals         = require('utils.globals')

local ImagesUI        = { _version = '1.0', _name = "ImagesUI", _author = 'Cannonballdex', }
ImagesUI.__index      = ImagesUI
-- Icon Rendering
ImagesUI.cannonballdexImg      = mq.CreateTexture(mq.TLO.Lua.Dir() .. "/rgmercs/extras/cannonballdex_60.png")
ImagesUI.burnImg      = mq.CreateTexture(mq.TLO.Lua.Dir() .. "/rgmercs/extras/cannonballdex2_60.png")
ImagesUI.imgDisplayed = ImagesUI.cannonballdexImg

function ImagesUI:InitLoader()
    math.randomseed(Globals.GetTimeSeconds())
    local images = { self.cannonballdexImg, self.burnImg, }
    self.imgDisplayed = images[math.floor(math.random(1000, ((#images + 1) * 1000) - 1) / 1000)]
end

return ImagesUI

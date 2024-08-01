mp = "scripts/MaxYari/MercyCAO/"

local core = require("openmw.core")
local ui = require("openmw.ui")
local gutils = require(mp .. "scripts/gutils")

DebugLevel = 2

if core.API_REVISION < 64 then
    return ui.showMessage("Mercy: CAO requiers a newer version of OpenMW, please update.")
end

gutils.print("Hi! Mercy: CAO BETA is now E-N-G-A-G-E-D", 0)

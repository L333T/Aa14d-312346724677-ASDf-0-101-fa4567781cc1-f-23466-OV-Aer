-- Compatibility bridge: all subsystem diagnostics share the session log.
local log = require("errorlog")
local debuglog = {}
local count = 0
function debuglog.line(tag, fmt, ...)
    if not log.enabled() then return end
    count=count+1
    log.trail(tag, fmt, ...)
end
function debuglog.flush() return false end
function debuglog.tick() end
function debuglog.reset(note)
    count=0
    if note then log.info("Run started: %s", tostring(note)) end
end
function debuglog.path() return log.path() end
function debuglog.count() return count end
return debuglog

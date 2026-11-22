-- audio/server.lua
-- Superfície de exports server-side equivalente ao xsound.

local function Send(src, state, data)
    TriggerClientEvent('solis:audio', src, state, data)
end

local exportsList = {
    PlayUrl = function(src, id, url, volume, loop)
        Send(src, 'play', { soundId = id, url = url, volume = volume, loop = loop })
    end,

    PlayUrlPos = function(src, id, url, volume, pos, loop)
        Send(src, 'playpos', { soundId = id, url = url, volume = volume, position = pos, loop = loop })
    end,

    Position = function(src, id, pos)
        Send(src, 'position', { soundId = id, position = pos })
    end,

    Distance = function(src, id, dist)
        Send(src, 'distance', { soundId = id, distance = dist })
    end,

    Destroy = function(src, id)
        Send(src, 'destroy', { soundId = id })
    end,

    Pause = function(src, id)
        Send(src, 'pause', { soundId = id })
    end,

    Resume = function(src, id)
        Send(src, 'resume', { soundId = id })
    end,

    setVolume = function(src, id, volume)
        Send(src, 'volume', { soundId = id, volume = volume })
    end,

    setTimeStamp = function(src, id, time)
        Send(src, 'timestamp', { soundId = id, time = time })
    end,

    DestroyAll = function(src)
        Send(src, 'destroyall', {})
    end
}

for name, fn in pairs(exportsList) do
    exports(name, fn)
end

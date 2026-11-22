-- audio/client.lua
-- Motor de áudio embutido no recurso (absorvido do xsound + fork de filtro DSP).
-- Fornece a mesma superfície de exports do xsound, agora em exports.solis_sound.

local RES = GetCurrentResourceName()
-- As duas formas servem a mesma página. A primeira é a recomendada (contexto
-- seguro, callbacks same-origin); a segunda existe porque algumas builds só
-- carregam DUI pelo esquema nui://. As recriações alternam entre elas.
local ENGINE_PAGES = {
    'https://cfx-nui-' .. RES .. '/html/audio.html',
    'nui://' .. RES .. '/html/audio.html'
}

Audio = {}

local sounds = {}
local dui = nil
local engineReady = false
local lastPing = 0
local createdAt = 0
local rebuilds = 0

local function Send(msg)
    if not dui or not engineReady then return end
    SendDuiMessage(dui, json.encode(msg))
end

-- ==========================================
-- RELÓGIO DE REPRODUÇÃO (SEM CONSULTAR A DUI)
-- ==========================================
-- O tempo é derivado do GetGameTimer: não há polling na página, nenhuma
-- mensagem por tick e o valor é exato enquanto o áudio roda linearmente.
function Audio.Time(id)
    local s = sounds[id]
    if not s then return 0 end
    if not s.playing or not s.startedAt then return s.time or 0.0 end

    local elapsed = (GetGameTimer() - s.startedAt) / 1000.0
    local t = (s.time or 0.0) + elapsed
    if s.duration and s.duration > 0.5 and t > s.duration then t = s.duration end
    return t
end

function Audio.Exists(id)
    return sounds[id] ~= nil
end

function Audio.Get(id)
    return sounds[id]
end

function Audio.IsPlaying(id)
    local s = sounds[id]
    return s ~= nil and s.playing == true
end

function Audio.Duration(id)
    local s = sounds[id]
    return (s and s.duration) or 0.0
end

function Audio.HasDynamic()
    for _, s in pairs(sounds) do
        if s.dynamic then return true end
    end
    return false
end

function Audio.Count()
    local n = 0
    for _ in pairs(sounds) do n = n + 1 end
    return n
end

-- ==========================================
-- CONTROLE
-- ==========================================
local function GetDef(id)
    return {
        id = id,
        url = '',
        vol = 1.0,
        pos = nil,
        dist = 1000.0,
        loop = false,
        dynamic = false,
        playing = false,
        time = 0.0,
        startedAt = nil,
        duration = 0.0,
        muffled = false,
        params = nil,
        onEnd = nil,
        onStart = nil
    }
end

local function StopExisting(id)
    if sounds[id] then
        Send({ t = 'stop', id = id })
        sounds[id] = nil
    end
end

function Audio.Play(id, url, vol, loop)
    StopExisting(id)

    local s = GetDef(id)
    s.url = url
    s.vol = vol or 0.5
    s.loop = loop == true
    s.playing = true
    s.startedAt = GetGameTimer()

    sounds[id] = s
    Send({ t = 'play', id = id, url = url, vol = s.vol, loop = s.loop, dynamic = false })
    return s
end

function Audio.PlayPos(id, url, vol, pos, loop)
    StopExisting(id)

    local s = GetDef(id)
    s.url = url
    s.vol = vol or 0.5
    s.pos = pos
    s.dist = s.dist
    s.loop = loop == true
    s.dynamic = true
    s.playing = true
    s.startedAt = GetGameTimer()

    sounds[id] = s
    Send({
        t = 'play', id = id, url = url, vol = s.vol, loop = s.loop,
        dynamic = true, x = pos.x, y = pos.y, z = pos.z
    })
    return s
end

function Audio.Destroy(id)
    StopExisting(id)
end

function Audio.StopAll()
    for id in pairs(sounds) do
        Send({ t = 'stop', id = id })
    end
    sounds = {}
end

function Audio.Pause(id)
    local s = sounds[id]
    if not s or not s.playing then return end
    s.time = Audio.Time(id)
    s.playing = false
    s.startedAt = nil
    Send({ t = 'pause', id = id })
end

function Audio.Resume(id)
    local s = sounds[id]
    if not s or s.playing then return end
    s.playing = true
    s.startedAt = GetGameTimer()
    Send({ t = 'resume', id = id })
end

function Audio.Seek(id, time)
    local s = sounds[id]
    if not s then return end
    time = tonumber(time) or 0.0
    if time < 0 then time = 0 end
    s.time = time
    if s.playing then s.startedAt = GetGameTimer() end
    Send({ t = 'seek', id = id, time = time })
end

function Audio.SetVolume(id, vol)
    local s = sounds[id]
    if not s then return end
    s.vol = vol
    Send({ t = 'volume', id = id, vol = vol })
end

function Audio.Distance(id, dist)
    local s = sounds[id]
    if not s then return end
    s.dist = dist
    Send({ t = 'dist', id = id, dist = dist })
end

function Audio.Position(id, pos)
    local s = sounds[id]
    if not s or not pos then return end
    s.pos = pos
    Send({ t = 'pos', id = id, x = pos.x, y = pos.y, z = pos.z })
end

function Audio.Muffle(id, on, params)
    local s = sounds[id]
    if not s then return end
    s.muffled = on == true
    s.params = params
    Send({ t = 'muffle', id = id, muffled = s.muffled, params = params })
end

function Audio.OnEnd(id, fn)
    local s = sounds[id]
    if s then s.onEnd = fn end
end

function Audio.OnStart(id, fn)
    local s = sounds[id]
    if s then s.onStart = fn end
end

-- ==========================================
-- DUI (PÁGINA DO MOTOR)
-- ==========================================
-- Reenvia o estado inteiro. É chamado quando a página do motor (re)carrega:
-- recriar a DUI nunca deixa uma música "presa" porque tudo volta do zero.
function Audio.Sync()
    for id, s in pairs(sounds) do
        if s.url ~= '' then
            if s.playing then
                Send({
                    t = 'play', id = id, url = s.url, vol = s.vol, loop = s.loop,
                    dynamic = s.dynamic, dist = s.dist,
                    x = s.pos and s.pos.x or 0, y = s.pos and s.pos.y or 0, z = s.pos and s.pos.z or 0,
                    time = Audio.Time(id)
                })
            else
                Send({
                    t = 'play', id = id, url = s.url, vol = s.vol, loop = s.loop,
                    dynamic = s.dynamic, dist = s.dist, paused = true,
                    x = s.pos and s.pos.x or 0, y = s.pos and s.pos.y or 0, z = s.pos and s.pos.z or 0,
                    time = s.time or 0
                })
            end

            if s.muffled then
                Send({ t = 'muffle', id = id, muffled = true, params = s.params })
            end
        end
    end
end

local function CreateEngine()
    if dui then
        pcall(DestroyDui, dui)
        dui = nil
    end

    engineReady = false
    lastPing = 0
    createdAt = GetGameTimer()
    dui = CreateDui(ENGINE_PAGES[(rebuilds % #ENGINE_PAGES) + 1], 1280, 720)

    -- Nativo opcional: só existe em algumas builds do client.
    if type(CreateDuiText) == 'function' then
        pcall(CreateDuiText, dui)
    end
end

CreateEngine()

CreateThread(function()
    while true do
        Wait(4000)

        if not engineReady then
            -- Página criada cedo demais (arquivos ainda não servidos) nunca manda
            -- ping. Sem isto o motor ficava morto para sempre, em silêncio.
            if createdAt ~= 0 and (GetGameTimer() - createdAt) > 9000 then
                if rebuilds < 12 then
                    rebuilds = rebuilds + 1
                    print(('[solis_sound] motor de áudio sem resposta; recriando (%d/12)'):format(rebuilds))
                    CreateEngine()
                elseif rebuilds == 12 then
                    rebuilds = 13
                    print('[solis_sound] motor de áudio não carregou: verifique se html/audio.html e html/audio.js estão no files do fxmanifest.')
                end
            end
        elseif lastPing ~= 0 and (GetGameTimer() - lastPing) > 14000 then
            -- Ping a cada 3s: 14s sem ping = DUI morta (crash do CEF / troca de resolução).
            CreateEngine()
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= RES then return end
    if dui then pcall(DestroyDui, dui) end
end)

-- ==========================================
-- RETORNOS DA PÁGINA DO MOTOR
-- ==========================================
RegisterNUICallback('audio/ping', function(data, cb)
    lastPing = GetGameTimer()

    -- `origin` mostra em qual página o motor realmente subiu (https ou nui://).
    -- Só a https tem Referer para o YouTube.
    if not engineReady then
        engineReady = true
        rebuilds = 0
        print(('[solis_sound] motor de áudio pronto. (%s)'):format((data and data.origin) or '?'))
        Audio.Sync()
    end

    -- Reenviado a cada boot da página (inclusive depois de recriar a DUI).
    -- O player do YouTube mora em uma página https: a partir do nui:// não há
    -- Referer nenhum e o embed responde 153.
    if data and data.boot then
        local player = Config.Audio.YoutubePlayer
        if not player or player == '' then
            player = ('https://cfx-nui-%s/html/player.html'):format(RES)
        end

        local sc = Config.SoundCloud or {}
        Send({
            t = 'config',
            youtubePlayer = player,
            soundCloudWidget = sc.WidgetUrl or 'https://w.soundcloud.com/player/'
        })
    end

    if cb then cb(true) end
end)

RegisterNUICallback('audio/ready', function(data, cb)
    local s = sounds[data.id]
    if s and s.onStart then
        local ok, err = pcall(s.onStart, data.id)
        if not ok then print(('[solis_sound] onStart %s: %s'):format(data.id, err)) end
    end
    if cb then cb(true) end
end)

RegisterNUICallback('audio/duration', function(data, cb)
    local s = sounds[data.id]
    if s then s.duration = tonumber(data.time) or 0.0 end
    if cb then cb(true) end
end)

-- Stream direto do SoundCloud: a DUI pede, o servidor resolve e devolvemos
-- por mensagem (o post da DUI é fire-and-forget, sem resposta de callback).
RegisterNUICallback('audio/scStream', function(data, cb)
    local url = data and data.url
    if type(url) == 'string' and url ~= '' then
        TriggerServerEvent('solis:sv:scStream', data.id, { url = url })
    end
    if cb then cb(true) end
end)

RegisterNetEvent('solis:audio:scStream', function(soundId, result, err)
    if type(result) == 'table' and type(result.url) == 'string' and result.url ~= '' then
        Send({ t = 'scStream', id = soundId, result = result })
    else
        -- Sem stream direto, cai para o widget (ainda toca, só sem DSP).
        Send({ t = 'scStreamFailed', id = soundId })
    end
end)

RegisterNUICallback('audio/ended', function(data, cb)
    local s = sounds[data.id]
    if s then
        s.playing = false
        s.startedAt = nil
        s.time = s.duration or s.time
        if s.onEnd then
            local ok, err = pcall(s.onEnd, data.id)
            if not ok then print(('[solis_sound] onEnd %s: %s'):format(data.id, err)) end
        end
    end
    if cb then cb(true) end
end)

RegisterNUICallback('audio/failed', function(data, cb)
    print(('[solis_sound] falha ao carregar áudio "%s": %s'):format(tostring(data.id), tostring(data.message)))
    local s = sounds[data.id]
    if s then
        s.playing = false
        s.startedAt = nil
    end
    if cb then cb(true) end
end)

-- ==========================================
-- POSIÇÃO DO OUVINTE
-- ==========================================
CreateThread(function()
    local last = GetEntityCoords(PlayerPedId())

    while true do
        local sleep = 1000

        if Audio.HasDynamic() then
            sleep = Config.Audio.Refresh
            local pos = GetEntityCoords(PlayerPedId())

            if #(pos - last) >= Config.Audio.Moved then
                last = pos
                Send({ t = 'listener', x = pos.x, y = pos.y, z = pos.z })
            end
        end

        Wait(sleep)
    end
end)

-- ==========================================
-- COMPATIBILIDADE xsound (server -> client)
-- ==========================================
RegisterNetEvent('solis:audio', function(state, data)
    if type(data) ~= 'table' then return end
    local id = data.soundId

    if state == 'play' then
        Audio.Play(id, data.url, data.volume, data.loop)
    elseif state == 'playpos' then
        Audio.PlayPos(id, data.url, data.volume, data.position, data.loop)
    elseif state == 'position' then
        Audio.Position(id, data.position)
    elseif state == 'distance' then
        Audio.Distance(id, data.distance)
    elseif state == 'destroy' then
        Audio.Destroy(id)
    elseif state == 'pause' then
        Audio.Pause(id)
    elseif state == 'resume' then
        Audio.Resume(id)
    elseif state == 'volume' then
        Audio.SetVolume(id, data.volume)
    elseif state == 'timestamp' then
        Audio.Seek(id, data.time)
    end
end)

-- ==========================================
-- EXPORTS (mesmos nomes do xsound)
-- ==========================================
exports('PlayUrl', function(id, url, vol, loop) return Audio.Play(id, url, vol, loop) end)
exports('PlayUrlPos', function(id, url, vol, pos, loop) return Audio.PlayPos(id, url, vol, pos, loop) end)
exports('Destroy', function(id) Audio.Destroy(id) end)
exports('Pause', function(id) Audio.Pause(id) end)
exports('Resume', function(id) Audio.Resume(id) end)
exports('setVolume', function(id, vol) Audio.SetVolume(id, vol) end)
exports('setVolumeMax', function(id, vol) Audio.SetVolume(id, vol) end)
exports('Distance', function(id, dist) Audio.Distance(id, dist) end)
exports('Position', function(id, pos) Audio.Position(id, pos) end)
exports('setTimeStamp', function(id, time) Audio.Seek(id, time) end)
exports('getTimeStamp', function(id) return Audio.Time(id) end)
exports('getMaxDuration', function(id) return Audio.Duration(id) end)
exports('soundExists', function(id) return Audio.Exists(id) end)
exports('isPlaying', function(id) return Audio.IsPlaying(id) end)
exports('onPlayEnd', function(id, fn) Audio.OnEnd(id, fn) end)
exports('onPlayStart', function(id, fn) Audio.OnStart(id, fn) end)
exports('setMuffled', function(id, on, params) Audio.Muffle(id, on, params) end)

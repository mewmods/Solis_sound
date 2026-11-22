-- client.lua — solis_sound
local RES = GetCurrentResourceName()

-- Chamadas ao servidor com retorno. A ponte não depende de framework:
-- ver bridge/client.lua.
local Server = Bridge.getInterface()

-- ==========================================
-- ESTADO
-- ==========================================
local me = {
    kind = 'headphones',   -- headphones | vehicle | stage
    sessId = 'headphones',
    netId = 0,
    stageId = nil,
    name = 'Fones privados',
    url = nil,
    title = '',
    thumb = '',
    vol = 0.5,
    playing = false,
    owns = true
}

local queue = {}
local qIndex = 0
local repeatMode = 0
local shuffleOn = false

local localVolume = 1.0
local muted = false

local jam = nil            -- { code, hostName, isHost, canControl, mode }
local applyingJam = false   -- evita reenviar ao servidor o play que veio da Jam
local prompt = nil         -- { id, text }
local uiOpen = false

local heldVeh = {}         -- [netId] = { vol, url, state }
local heldStage = {}       -- [stageId] = { vol, url, state }

-- ==========================================
-- PONTE COM A INTERFACE
-- ==========================================
local function Ui(msg)
    SendNUIMessage(msg)
    TriggerEvent('fphone2:syncSpotifive', msg)
end

local function Toast(kind, text, title)
    Ui({ type = 'toast', kind = kind, text = text, title = title })
end

-- ==========================================
-- PERMISSÃO NA JAM
-- ==========================================
-- O anfitrião sempre controla; os demais só depois que ele liberar
-- (jam.canControl). Fora de uma Jam não existe restrição.
local function JamCanControl()
    if not jam then return true end
    return jam.isHost == true or jam.canControl == true
end

local function JamDeny()
    Toast('warning', 'Nesta jam você está apenas como ouvinte.', 'Jam')
end

-- ==========================================
-- VOLUME INDIVIDUAL
-- ==========================================
local function ListenVol(base)
    if muted then return 0.0 end
    return (base or 0.5) * localVolume
end

local function SaveVolumePrefs()
    SetResourceKvpInt('solis_local_volume', math.floor(localVolume * 100))
    SetResourceKvpInt('solis_local_muted', muted and 1 or 0)
end

CreateThread(function()
    local saved = GetResourceKvpInt('solis_local_volume')
    if saved and saved > 0 then localVolume = saved / 100.0 end
    if GetResourceKvpInt('solis_local_muted') == 1 then muted = true end
end)

-- ==========================================
-- FONES (PROP)
-- ==========================================
local HP = Config.Headphones or {}
local HP_PROP = HP.Prop or 2

local wearingPhones = false
local savedEarProp = nil
local phonesPed = 0
local warnedPhones = false

local function UpdateHeadphones()
    local ped = PlayerPedId()
    if not DoesEntityExist(ped) or IsEntityDead(ped) then return end

    -- Respawn/troca de personagem: o prop não sobrevive ao ped novo.
    if wearingPhones and phonesPed ~= ped then
        wearingPhones = false
        savedEarProp = nil
    end

    -- Fone no ouvido enquanto o jogador está no modo individual com uma faixa
    -- carregada (tocando ou pausada). Sem faixa, ninguém sai de fone por aí.
    local shouldWear = HP.Enabled ~= false and me.kind == 'headphones' and (me.playing == true or me.url ~= nil)

    if shouldWear and not wearingPhones then
        local model = GetEntityModel(ped)
        local drawable = nil

        if model == GetHashKey('mp_m_freemode_01') then
            drawable = HP.Male or 41
        elseif model == GetHashKey('mp_f_freemode_01') then
            drawable = HP.Female or 22
        end

        if not drawable then return end

        -- Drawable fora da lista do ped não aparece (e antes falhava calado).
        local variations = (GetNumberOfPedPropDrawableVariations and GetNumberOfPedPropDrawableVariations(ped, HP_PROP)) or 0
        if variations > 0 and drawable > variations - 1 then
            if not warnedPhones then
                warnedPhones = true
                print(('[solis_sound] prop %d drawable %d não existe neste ped; ajuste Config.Headphones.'):format(HP_PROP, drawable))
            end
            return
        end

        local current = GetPedPropIndex(ped, HP_PROP)
        savedEarProp = {
            item = current,
            texture = (current ~= -1) and GetPedPropTextureIndex(ped, HP_PROP) or 0
        }

        SetPedPropIndex(ped, HP_PROP, drawable, 0, false)
        wearingPhones = true
        phonesPed = ped
    elseif not shouldWear and wearingPhones then
        if savedEarProp and savedEarProp.item ~= -1 then
            SetPedPropIndex(ped, HP_PROP, savedEarProp.item, savedEarProp.texture, false)
        else
            ClearPedProp(ped, HP_PROP)
        end

        savedEarProp = nil
        wearingPhones = false
        phonesPed = 0
    end
end

AddEventHandler('onResourceStop', function(name)
    if name ~= RES then return end
    if not wearingPhones then return end

    local ped = PlayerPedId()
    if not DoesEntityExist(ped) then return end

    if savedEarProp and savedEarProp.item ~= -1 then
        SetPedPropIndex(ped, HP_PROP, savedEarProp.item, savedEarProp.texture, false)
    else
        ClearPedProp(ped, HP_PROP)
    end
end)

-- ==========================================
-- SOM DE SESSÃO
-- ==========================================
local function VehicleSoundId(netId) return 'veh_' .. netId end
local function StageSoundId(stageId) return 'stg_' .. tostring(stageId) end

local function SoundIdOf(sessId)
    if sessId == 'headphones' then return 'hp' end
    if sessId:find('^vehicle_') then return VehicleSoundId(tonumber(sessId:sub(9))) end
    if sessId:find('^stage_') then return StageSoundId(sessId:sub(7)) end
    return nil
end

local function VehicleCoords(netId)
    if not NetworkDoesNetworkIdExist(netId) then return nil end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity == 0 or not DoesEntityExist(entity) then return nil end
    return GetEntityCoords(entity)
end

local function MuffleParams()
    local cfg = Config.VehicleFilter or {}
    local profiles = cfg.Profiles or {}
    local profile = profiles[cfg.Profile or ''] or profiles.medio or {}

    return {
        cutoff = profile.Cutoff or 260.0,
        resonance = profile.Resonance or 2.4,
        bassFreq = profile.BassFreq or 95.0,
        bassGain = profile.BassGain or 10.0,
        bassQ = profile.BassQ or 1.7,
        smooth = profile.Smoothing or 0.12
    }
end

local function IsMotorcycle(vehicle)
    local class = GetVehicleClass(vehicle)
    return class == 8 or class == 13
end

local function DoorsOpen(vehicle)
    for index = 0, 5 do
        if GetVehicleDoorAngleRatio(vehicle, index) > 0.0 then return true end
    end
    return not AreAllVehicleWindowsIntact(vehicle)
end

local function ShouldMuffle(netId)
    if not NetworkDoesNetworkIdExist(netId) then return false end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return false end

    if IsPedInVehicle(PlayerPedId(), vehicle, false) then return false end
    if IsMotorcycle(vehicle) then return false end
    if DoorsOpen(vehicle) then return false end

    return true
end

-- Aplica um volume recebido do servidor (ou do próprio UI) imediatamente.
-- Antes o valor só era guardado em heldVeh/heldStage e aplicado no tick
-- espacial seguinte, o que dava ~300 ms de atraso em cada ajuste.
local function ApplyControlVolume(sessId, base)
    local soundId = SoundIdOf(sessId)
    if not soundId then return end

    local vol = ListenVol(base)

    if sessId:find('^vehicle_') then
        local netId = tonumber(sessId:sub(9))
        local held = netId and heldVeh[netId]

        if held then held.vol = base end

        if netId and ShouldMuffle(netId) then
            vol = vol * (Config.MuffledVolume or 0.95)
        end

        if held and held.state then held.state.vol = vol end
    elseif sessId:find('^stage_') then
        local stageId = sessId:sub(7)
        local held = heldStage[stageId]

        if held then
            held.vol = base
            if held.state then held.state.vol = vol end
        end
    end

    Audio.SetVolume(soundId, vol)
end

local function ReleaseSound(sessId)
    local soundId = SoundIdOf(sessId)
    if soundId then Audio.Destroy(soundId) end

    if sessId:find('^vehicle_') then
        heldVeh[tonumber(sessId:sub(9))] = nil
    elseif sessId:find('^stage_') then
        heldStage[sessId:sub(7)] = nil
    end
end

-- ==========================================
-- FILA
-- ==========================================
local playGeneration = 0
local lastEndGeneration = -1
local lastEndAt = 0

local AdvanceQueue

local function QueueState()
    return {
        type = 'queue',
        queue = queue,
        index = math.max(qIndex - 1, 0),
        repeatMode = repeatMode,
        shuffle = shuffleOn,
        playing = me.playing,
        owns = me.owns,
        track = queue[qIndex] or nil
    }
end

local function PushQueue()
    Ui(QueueState())
end

local function CurrentTime()
    if me.kind == 'headphones' then return Audio.Time('hp') end
    if me.kind == 'vehicle' and me.netId ~= 0 then return Audio.Time(VehicleSoundId(me.netId)) end
    if me.kind == 'stage' and me.stageId then return Audio.Time(StageSoundId(me.stageId)) end
    return 0
end

local function CurrentDuration()
    if me.kind == 'headphones' then return Audio.Duration('hp') end
    if me.kind == 'vehicle' and me.netId ~= 0 then return Audio.Duration(VehicleSoundId(me.netId)) end
    if me.kind == 'stage' and me.stageId then return Audio.Duration(StageSoundId(me.stageId)) end
    return 0
end

local function MaybeTrackEnded()
    if not me.owns then return end

    local now = GetGameTimer()
    if playGeneration == lastEndGeneration then return end
    if (now - lastEndAt) < 800 then return end

    lastEndGeneration = playGeneration
    lastEndAt = now

    CreateThread(function()
        Wait(0)
        if AdvanceQueue then AdvanceQueue() end
    end)
end

local function StartPlayback(song, startTime)
    playGeneration = playGeneration + 1
    me.url = song.url
    me.title = song.title
    me.thumb = song.thumb or ''
    me.playing = true
    me.owns = true

    if me.kind == 'headphones' then
        Audio.Play('hp', song.url, ListenVol(me.vol), false)
        if startTime and startTime > 1 then Audio.Seek('hp', startTime) end
        Audio.OnEnd('hp', MaybeTrackEnded)
    elseif me.kind == 'vehicle' then
        TriggerServerEvent('solis:sv:play', me.sessId, song.url, me.vol, startTime or 0, song.title, me.thumb, queue, math.max(qIndex - 1, 0))
    elseif me.kind == 'stage' then
        TriggerServerEvent('solis:sv:play', me.sessId, song.url, me.vol, startTime or 0, song.title, me.thumb)
    end

    if jam and JamCanControl() and not applyingJam then
        TriggerServerEvent('solis:sv:jam', jam.code, 'play', {
            url = song.url,
            title = song.title,
            thumb = me.thumb,
            time = startTime or 0,
            queue = queue,
            queueIndex = math.max(qIndex - 1, 0)
        })
    end

    UpdateHeadphones()
    PushQueue()
end

local function PlayIndex(index, startTime, record)
    local song = queue[index]
    if not song then return false end

    qIndex = index
    StartPlayback(song, startTime)

    if record then
        TriggerServerEvent('solis:sv:recent', song)
    end

    return true
end

local function StopPlayback()
    me.playing = false

    if me.kind == 'headphones' then
        Audio.Destroy('hp')
    elseif me.kind == 'vehicle' then
        TriggerServerEvent('solis:sv:control', me.sessId, 'stop')
    elseif me.kind == 'stage' then
        TriggerServerEvent('solis:sv:control', me.sessId, 'stop')
    end

    if jam and JamCanControl() then
        TriggerServerEvent('solis:sv:jam', jam.code, 'pause', { time = 0 })
    end

    UpdateHeadphones()
    PushQueue()
end

AdvanceQueue = function()
    if #queue == 0 then
        StopPlayback()
        return
    end

    if repeatMode == 2 then
        PlayIndex(qIndex, 0, false)
        return
    end

    if shuffleOn and #queue > 1 then
        local nextIndex = math.random(1, #queue)
        if nextIndex == qIndex then nextIndex = (nextIndex % #queue) + 1 end
        PlayIndex(nextIndex, 0, true)
        return
    end

    if qIndex + 1 <= #queue then
        PlayIndex(qIndex + 1, 0, true)
        return
    end

    if repeatMode == 1 then
        PlayIndex(1, 0, true)
        return
    end

    StopPlayback()
end

local function Skip(direction)
    if #queue == 0 then
        PushQueue()
        return
    end

    local target

    if shuffleOn and #queue > 1 then
        target = math.random(1, #queue)
        if target == qIndex then target = (target % #queue) + 1 end
    else
        target = qIndex + direction

        if target > #queue then
            if repeatMode == 1 then
                target = 1
            else
                StopPlayback()
                return
            end
        elseif target < 1 then
            target = (repeatMode == 1) and #queue or 1
        end
    end

    if target < 1 then target = 1 end
    if target > #queue then target = #queue end

    PlayIndex(target, 0, true)
end

-- ==========================================
-- TROCA DE DISPOSITIVO
-- ==========================================
local function SwitchToHeadphones()
    local time = CurrentTime()
    local wasPlaying = me.playing
    local url, title, thumb, vol = me.url, me.title, me.thumb, me.vol

    if me.kind ~= 'headphones' then
        local previous = me.sessId
        ReleaseSound(previous)
        pcall(function() Server.leave(previous) end)
    end

    me.kind = 'headphones'
    me.sessId = 'headphones'
    me.netId = 0
    me.stageId = nil
    me.name = 'Fones privados'
    me.owns = true

    if url and wasPlaying then
        Audio.Play('hp', url, ListenVol(vol), false)
        if time > 1 then Audio.Seek('hp', time) end
        Audio.OnEnd('hp', MaybeTrackEnded)
    end

    UpdateHeadphones()

    Ui({
        type = 'focus',
        state = {
            kind = me.kind, name = me.name, title = me.title, thumb = me.thumb,
            playing = me.playing, volume = me.vol, owns = me.owns
        }
    })
    PushQueue()
end

local function SetFocused(info)
    if type(info) ~= 'table' or not info.sessId then return end

    if info.kind == 'jam' then
        jam = { code = info.jamCode, hostName = info.name, isHost = false, mode = 'own' }
    end

    if me.kind == 'headphones' then
        Audio.Destroy('hp')
    end

    me.kind = (info.kind == 'stage') and 'stage' or (info.kind == 'jam' and 'headphones') or 'vehicle'
    me.sessId = info.sessId
    me.netId = tonumber(info.netId) or 0
    me.stageId = info.stageId
    me.name = info.name or 'Dispositivo'
    me.url = info.url
    me.title = info.title or 'Nenhuma música tocando'
    me.thumb = info.thumb or ''
    me.vol = tonumber(info.vol) or 0.5
    me.playing = info.playing == true
    me.owns = info.focus == true

    UpdateHeadphones()

    Ui({
        type = 'focus',
        state = {
            kind = me.kind, name = me.name, title = me.title, thumb = me.thumb,
            playing = me.playing, volume = me.vol, owns = me.owns
        }
    })
    PushQueue()
end

-- ==========================================
-- GERENCIADOR DE ÁUDIO ESPACIAL
-- ==========================================
local MUFFLE_REFRESH = Config.Audio.MuffleRefresh
local MAX_MISSES = Config.Audio.TrackingMaxMisses

CreateThread(function()
    while true do
        -- Com som aberto, porta/vidro e volume têm que responder no frame:
        -- um tick de 300 ms deixava o filtro chegar depois que o carro já
        -- tinha fechado (e parecia só ter atenuação de volume).
        local sleep = (next(heldVeh) or next(heldStage)) and 0 or 1000

        if sleep == 0 then
            local ped = PlayerPedId()
            local playerCoords = GetEntityCoords(ped)
            local now = GetGameTimer()

            for netId, held in pairs(heldVeh) do
                local soundId = VehicleSoundId(netId)
                local vehicle = NetworkDoesNetworkIdExist(netId) and NetworkGetEntityFromNetworkId(netId) or 0

                if vehicle ~= 0 and DoesEntityExist(vehicle) then
                    held.state = held.state or { vol = -1, dist = -1, muffled = nil, pos = nil, at = 0 }
                    held.misses = 0

                    local state = held.state
                    local inside = IsPedInVehicle(ped, vehicle, false)
                    local base = ListenVol(held.vol)
                    local distance, muffled, position, volume

                    if inside then
                        position = playerCoords
                        distance = 1000.0
                        muffled = false
                        volume = base
                    else
                        local motorcycle = IsMotorcycle(vehicle)
                        local open = not motorcycle and DoorsOpen(vehicle)

                        position = GetEntityCoords(vehicle)

                        if motorcycle then
                            distance = Config.Distances.Motorbike
                            muffled = false
                            volume = base
                        elseif open then
                            distance = Config.Distances.VehicleOpen
                            muffled = false
                            volume = base
                        else
                            distance = Config.Distances.VehicleClosed
                            muffled = true
                            volume = base * (Config.MuffledVolume or 0.95)
                        end
                    end

                    if not state.pos or #(position - state.pos) > 0.5 then
                        state.pos = position
                        Audio.Position(soundId, position)
                    end

                    if state.dist ~= distance then
                        state.dist = distance
                        Audio.Distance(soundId, distance)
                    end

                    if state.muffled ~= muffled or (now - state.at) >= MUFFLE_REFRESH then
                        state.muffled = muffled
                        state.at = now
                        Audio.Muffle(soundId, muffled, muffled and MuffleParams() or nil)
                    end

                    if state.vol ~= volume then
                        state.vol = volume
                        Audio.SetVolume(soundId, volume)
                    end
                else
                    held.misses = (held.misses or 0) + 1
                    if held.misses > 20 then
                        Audio.Destroy(soundId)
                        heldVeh[netId] = nil
                    end
                end
            end

            for stageId, held in pairs(heldStage) do
                local stage = Config.Stages[stageId]
                if stage then
                    held.state = held.state or { vol = -1 }
                    local volume = ListenVol(held.vol)

                    if held.state.vol ~= volume then
                        held.state.vol = volume
                        Audio.SetVolume(StageSoundId(stageId), volume)
                    end
                else
                    heldStage[stageId] = nil
                end
            end
        end

        Wait(sleep)
    end
end)

-- ==========================================
-- ENTRAR NO SOM JÁ TOCANDO
-- ==========================================
RegisterNetEvent('solis:cl:play', function(data)
    if type(data) ~= 'table' or not data.url then return end

    -- O controlador de carro/palco NÃO toca localmente no StartPlayback: ele
    -- depende deste eco para criar/trocar o som (Audio.PlayPos). Descarta-lo
    -- deixava a música antiga tocando enquanto a UI mostrava a nova. Para
    -- fones este handler não faz nada (o som já é criado localmente).
    -- O caso "já estou tocando esta URL" é tratado pelos checks abaixo.

    if data.kind == 'vehicle' then
        local netId = tonumber(data.netId)
        if not netId then return end

        local soundId = VehicleSoundId(netId)
        local existing = Audio.Get(soundId)

        if existing and existing.url == data.url then
            Audio.Seek(soundId, data.time or 0)
            heldVeh[netId] = heldVeh[netId] or { state = nil }
            heldVeh[netId].vol = data.vol or 0.5
            heldVeh[netId].url = data.url
            Audio.SetVolume(soundId, ListenVol(data.vol))
            return
        end

        local coords = VehicleCoords(netId) or GetEntityCoords(PlayerPedId())

        Audio.PlayPos(soundId, data.url, ListenVol(data.vol), coords, false)
        Audio.Distance(soundId, Config.Distances.VehicleClosed)
        Audio.Seek(soundId, data.time or 0)
        Audio.Muffle(soundId, ShouldMuffle(netId), MuffleParams())

        heldVeh[netId] = { vol = data.vol or 0.5, url = data.url, state = nil }

        if me.kind == 'vehicle' and me.netId == netId then
            me.playing = true
            me.url = data.url
            me.title = data.title or me.title
            me.thumb = data.thumb or me.thumb
            UpdateHeadphones()
            PushQueue()
        end
    elseif data.kind == 'stage' then
        local stageId = tostring(data.stageId)
        local stage = Config.Stages[stageId]
        if not stage then return end

        local soundId = StageSoundId(stageId)
        local existing = Audio.Get(soundId)

        if existing and existing.url == data.url then
            Audio.Seek(soundId, data.time or 0)
            heldStage[stageId] = heldStage[stageId] or { state = nil }
            heldStage[stageId].vol = data.vol or 0.5
            Audio.SetVolume(soundId, ListenVol(data.vol))
            return
        end

        Audio.PlayPos(soundId, data.url, ListenVol(data.vol), stage.coords, false)
        Audio.Distance(soundId, stage.radius)
        Audio.Seek(soundId, data.time or 0)

        heldStage[stageId] = { vol = data.vol or 0.5, url = data.url, state = nil }

        if me.kind == 'stage' and me.stageId == stageId then
            me.playing = true
            me.url = data.url
            me.title = data.title or me.title
            me.thumb = data.thumb or me.thumb
            PushQueue()
        end
    end
end)

RegisterNetEvent('solis:cl:control', function(sessId, action, value)
    local soundId = SoundIdOf(sessId)
    if not soundId then return end

    if sessId == me.sessId then
        if action == 'pause' or action == 'stop' then me.playing = false end
        if action == 'resume' then me.playing = true end
        if action == 'volume' then me.vol = tonumber(value) or me.vol end
        UpdateHeadphones()
        PushQueue()
    end

    if action == 'pause' or action == 'stop' then
        Audio.Pause(soundId)
    elseif action == 'resume' then
        Audio.Resume(soundId)
    elseif action == 'seek' then
        Audio.Seek(soundId, value)
    elseif action == 'volume' then
        ApplyControlVolume(sessId, tonumber(value) or 0.5)
    end
end)

RegisterNetEvent('solis:cl:sessionEnded', function(sessId)
    ReleaseSound(sessId)

    if sessId == me.sessId then
        local url, title, thumb, wasPlaying = me.url, me.title, me.thumb, me.playing

        me.kind = 'headphones'
        me.sessId = 'headphones'
        me.netId = 0
        me.stageId = nil
        me.name = 'Fones privados'
        me.owns = true
        me.playing = false
        me.url = url
        me.title = title
        me.thumb = thumb

        UpdateHeadphones()

        Ui({
            type = 'focus',
            state = {
                kind = me.kind, name = me.name, title = title, thumb = thumb,
                playing = false, volume = me.vol, owns = true
            }
        })
        PushQueue()

        if wasPlaying then
            Toast('warning', 'A sessão foi encerrada.', 'Áudio')
        end
    end
end)

RegisterNetEvent('solis:cl:sessionLeft', function(sessId)
    ReleaseSound(sessId)
    if sessId == me.sessId then SwitchToHeadphones() end
end)

RegisterNetEvent('solis:cl:granted', function(info)
    SetFocused(info)
    Toast('success', 'Conectado a ' .. (info.name or 'dispositivo'), 'Bluetooth')
end)

RegisterNetEvent('solis:cl:denied', function()
    Toast('error', 'A conexão foi recusada.', 'Bluetooth')
end)

RegisterNetEvent('solis:cl:sessions', function(list)
    Ui({ type = 'sessions', list = list or {} })
end)

RegisterNetEvent('solis:cl:toast', function(kind, text, title)
    Toast(kind, text, title)
end)

RegisterNetEvent('solis:cl:playlists', function(list)
    Ui({ type = 'playlists', list = list or {} })
end)

-- Importação do Spotify: uma faixa resolvida por vez atualiza a linha na UI.
RegisterNetEvent('solis:cl:playlistTrack', function(id, index, song)
    Ui({ type = 'playlistTrack', id = id, index = index, song = song })
end)

-- ==========================================
-- PROMPTS (Y / U)
-- ==========================================
RegisterNetEvent('solis:cl:prompt', function(data)
    prompt = { id = data.id, text = data.text }
    Ui({ type = 'prompt', text = data.text })
end)

local function AnswerPrompt(accepted)
    if not prompt then return end
    TriggerServerEvent('solis:sv:answer', prompt.id, accepted)
    prompt = nil
    Ui({ type = 'prompt', text = nil })
end

RegisterCommand('+solisAccept', function() AnswerPrompt(true) end, false)
RegisterCommand('-solisAccept', function() end, false)
RegisterCommand('+solisDeny', function() AnswerPrompt(false) end, false)
RegisterCommand('-solisDeny', function() end, false)

RegisterKeyMapping('+solisAccept', 'Solis: aceitar pedido', 'keyboard', 'Y')
RegisterKeyMapping('+solisDeny', 'Solis: recusar pedido', 'keyboard', 'U')

-- ==========================================
-- JAM
-- ==========================================
local function JamState()
    if not jam then return nil end
    return {
        code = jam.code,
        hostName = jam.hostName,
        isHost = jam.isHost,
        canControl = jam.canControl == true,
        mode = jam.mode,
        members = jam.members or {}
    }
end

RegisterNetEvent('solis:cl:jamMembers', function(members)
    if not jam then return end

    jam.members = members or {}

    -- O anfitrião pode liberar/remover o controle de cada membro a qualquer
    -- momento: a permissão vem na própria lista.
    local mySource = GetPlayerServerId(PlayerId())

    for _, member in ipairs(jam.members) do
        if member.source == mySource then
            jam.canControl = member.canControl == true
            break
        end
    end

    Ui({ type = 'jam', jam = JamState() })
end)

RegisterNetEvent('solis:cl:jamEvent', function(text)
    Ui({ type = 'jamEvent', text = text })
end)

RegisterNetEvent('solis:cl:jamEnded', function()
    jam = nil
    Ui({ type = 'jam', jam = nil })
    Toast('info', 'A Jam foi encerrada.', 'Jam')
end)

RegisterNetEvent('solis:cl:jamInvite', function(data)
    jam = { code = data.code, hostName = data.hostName, isHost = false, canControl = false, mode = 'own' }
    Ui({ type = 'jam', jam = JamState() })
    Toast('info', data.hostName .. ' convidou você para uma Jam.', 'Jam')
end)

RegisterNetEvent('solis:cl:jamApply', function(action, playback, mode, senderSrc)
    if not jam then return end

    local mySource = GetPlayerServerId(PlayerId())

    if jam.mode == 'own' then
        if action == 'play' then
            if senderSrc ~= mySource then
                local song = { url = playback.url, title = playback.title, thumb = playback.thumb }
                queue = { song }
                qIndex = 1
                me.vol = playback.volume or me.vol

                -- O play veio do servidor: aplicar aqui não pode voltar como
                -- uma nova ação (isso viraria um loop entre os membros).
                applyingJam = true
                StartPlayback(song, playback.time or 0)
                applyingJam = false

                me.owns = false
            end
        elseif action == 'pause' then
            local soundId = SoundIdOf(me.sessId)
            me.playing = false
            if soundId then Audio.Pause(soundId) end
        elseif action == 'resume' then
            local soundId = SoundIdOf(me.sessId)
            me.playing = true
            if soundId then Audio.Resume(soundId) end
        elseif action == 'seek' then
            local soundId = SoundIdOf(me.sessId)
            if soundId then Audio.Seek(soundId, playback.time or 0) end
        end

        UpdateHeadphones()
    end

    Ui({ type = 'jamPlayback', action = action, playback = playback })
    PushQueue()
end)

-- ==========================================
-- INTERESSE ESPACIAL
-- ==========================================
local interestKey = nil
local lastInterestAt = 0
local lastRangeState = nil

CreateThread(function()
    while true do
        Wait(Config.Net.ScanInterval)

        local ped = PlayerPedId()
        if DoesEntityExist(ped) and not IsEntityDead(ped) then
            local coords = GetEntityCoords(ped)
            local radiusSq = Config.Net.InterestRadius * Config.Net.InterestRadius

            local vehicles, stages = {}, {}
            local count = 0

            for _, vehicle in ipairs(GetGamePool('CVehicle')) do
                if DoesEntityExist(vehicle) then
                    local target = GetEntityCoords(vehicle)
                    local dx, dy, dz = coords.x - target.x, coords.y - target.y, coords.z - target.z

                    if (dx * dx + dy * dy + dz * dz) <= radiusSq then
                        local netId = NetworkGetNetworkIdFromEntity(vehicle)
                        if netId ~= 0 then
                            vehicles[#vehicles + 1] = netId
                            count = count + 1
                            if count >= Config.Net.InterestMaxVehicles then break end
                        end
                    end
                end
            end

            for stageId, stage in pairs(Config.Stages) do
                local dx, dy = coords.x - stage.coords.x, coords.y - stage.coords.y
                local reach = stage.radius + 25.0
                if (dx * dx + dy * dy) <= reach * reach then
                    stages[#stages + 1] = stageId
                end
            end

            table.sort(vehicles)
            table.sort(stages)

            local key = table.concat(vehicles, ',') .. '|' .. table.concat(stages, ',')
            local heartbeat = (GetGameTimer() - lastInterestAt) >= Config.Net.Heartbeat

            if key ~= interestKey or heartbeat then
                interestKey = key
                lastInterestAt = GetGameTimer()
                TriggerServerEvent('solis:sv:interest', vehicles, stages)
            end

            -- Aviso de sinal fraco só quando muda de estado.
            if me.kind == 'vehicle' and me.netId ~= 0 then
                local vehicleCoords = VehicleCoords(me.netId)
                local out = vehicleCoords ~= nil and #(coords - vehicleCoords) > Config.Net.RangeWarn

                if out ~= lastRangeState then
                    lastRangeState = out
                    Ui({ type = 'range', out = out, name = me.name })
                end
            elseif lastRangeState ~= nil then
                lastRangeState = nil
                Ui({ type = 'range', out = false })
            end
        end
    end
end)

-- Lista de sessões reconciliada de tempos em tempos (só quem abriu a UI pede).
CreateThread(function()
    while true do
        Wait(Config.Net.SessionPoll)
        if uiOpen then
            Ui({ type = 'sessions', list = Server.sessions() or {} })
        end
    end
end)

-- ==========================================
-- PROGRESSO
-- ==========================================
CreateThread(function()
    while true do
        local sleep = 1000

        if me.playing then
            sleep = 500

            local time = CurrentTime()
            local duration = CurrentDuration()

            if uiOpen then
                Ui({ type = 'progress', time = time, duration = duration })
            end

            if me.owns and duration > 5 and time >= (duration - 0.6) then
                MaybeTrackEnded()
            end
        end

        UpdateHeadphones()
        Wait(sleep)
    end
end)

-- ==========================================
-- MARCADORES DOS PALCOS
-- ==========================================
CreateThread(function()
    for _, stage in pairs(Config.Stages) do
        local blip = stage.mapBlip
        if blip and blip.enable then
            local handle = AddBlipForCoord(stage.coords.x, stage.coords.y, stage.coords.z)
            SetBlipSprite(handle, blip.sprite or 484)
            SetBlipColour(handle, blip.color or 4)
            SetBlipScale(handle, blip.scale or 0.8)
            SetBlipAsShortRange(handle, false)

            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(blip.name or stage.label)
            EndTextCommandSetBlipName(handle)
        end
    end

    while true do
        local sleep = 1000
        local ped = PlayerPedId()

        if DoesEntityExist(ped) then
            local coords = GetEntityCoords(ped)

            for _, stage in pairs(Config.Stages) do
                local marker = stage.marker
                if marker and marker.enable then
                    local drawDist = marker.drawDist or 40.0
                    if #(coords - stage.coords) <= drawDist then
                        sleep = 0
                        DrawMarker(
                            marker.type or 1,
                            stage.coords.x, stage.coords.y, stage.coords.z - 1.0,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            marker.scale.x, marker.scale.y, marker.scale.z,
                            marker.color.r, marker.color.g, marker.color.b, marker.color.a,
                            false, false, 2, false, nil, nil, false
                        )
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

-- ==========================================
-- API EXTERNA: PONTE NUI -> SERVER
-- ==========================================
-- Busca/resolução rodam no servidor (CORS, credenciais e cota). A NUI só pede
-- e recebe pelo reqId; o timeout evita promise pendurada sem internet.
local apiPending = {}
local apiSeq = 0

local function ApiRequest(eventName, resultEvent, payload, cb, timeoutMs)
    apiSeq = apiSeq + 1
    local reqId = apiSeq
    apiPending[reqId] = cb

    TriggerServerEvent(eventName, reqId, payload)

    SetTimeout(timeoutMs or 15000, function ()
        if not apiPending[reqId] then return end
        apiPending[reqId] = nil
        cb({ error = 'timeout' })
    end)
end

local function ApiAnswer(reqId, res)
    local cb = apiPending[reqId]
    if not cb then return end
    apiPending[reqId] = nil
    cb(res)
end

RegisterNetEvent('solis:cl:apiResult', function (reqId, res)
    ApiAnswer(reqId, res)
end)

-- SoundCloud (a API devolve argumentos posicionais; normaliza aqui).
RegisterNetEvent('solis:cl:scResult', function (reqId, songs, err)
    ApiAnswer(reqId, { songs = songs or {}, error = err })
end)

RegisterNetEvent('solis:cl:scResolveResult', function (reqId, song, err)
    ApiAnswer(reqId, { song = song, error = err })
end)

RegisterNUICallback('scSearch', function (data, cb)
    ApiRequest('solis:sv:scSearch', 'solis:cl:apiResult', data and data.query or '', cb)
end)

RegisterNUICallback('scResolve', function (data, cb)
    ApiRequest('solis:sv:scResolve', 'solis:cl:apiResult', data and data.url or '', cb)
end)

-- Spotify: catálogo + resolução em lote (pode levar mais que 15 s).
RegisterNUICallback('spotifySearch', function (data, cb)
    ApiRequest('solis:sv:spotifySearch', 'solis:cl:apiResult', data and data.query or '', cb)
end)

RegisterNUICallback('spotifyLink', function (data, cb)
    ApiRequest('solis:sv:spotifyLink', 'solis:cl:apiResult', data and data.url or '', cb)
end)

RegisterNUICallback('spotifyBatch', function (data, cb)
    ApiRequest('solis:sv:spotifyBatch', 'solis:cl:apiResult', data and data.songs or {}, cb, 120000)
end)

-- YouTube publico: busca, video e playlist quando a Data API esgota a cota.
RegisterNUICallback('ytFallback', function (data, cb)
    ApiRequest('solis:sv:ytFallback', 'solis:cl:apiResult', data or {}, cb, 30000)
end)

-- ==========================================
-- PAYLOAD / NUI
-- ==========================================
local function BootPayload()
    return {
        apiKey = Config.YoutubeAPIKey,
        soundCloud = { enabled = Config.SoundCloud and Config.SoundCloud.Enabled ~= false },
        spotify = {
            enabled = Config.Spotify and Config.Spotify.Enabled == true
                and type(Config.Spotify.ClientId) == 'string' and Config.Spotify.ClientId ~= ''
                and type(Config.Spotify.ClientSecret) == 'string' and Config.Spotify.ClientSecret ~= ''
        },
        state = {
            kind = me.kind,
            name = me.name,
            title = me.title,
            thumb = me.thumb,
            url = me.url,
            playing = me.playing,
            volume = me.vol,
            owns = me.owns,
            time = CurrentTime(),
            duration = CurrentDuration()
        },
        queue = queue,
        index = math.max(qIndex - 1, 0),
        repeatMode = repeatMode,
        shuffle = shuffleOn,
        volume = { ["local"] = localVolume, muted = muted },
        sessions = Server.sessions() or {},
        jam = JamState(),
        limits = { sessions = Config.Limits.MaxSessions, queue = Config.Limits.MaxQueue }
    }
end

RegisterNUICallback('boot', function(_, cb)
    uiOpen = true
    cb(BootPayload())
end)

RegisterNUICallback('close', function(_, cb)
    uiOpen = false
    SetNuiFocus(false, false)
    cb('ok')
end)

-- A página carrega junto com o resource; se o jogador abrir o painel antes do CEF
-- terminar, a mensagem de abertura se perde. O ready reenvia o estado atual.
RegisterNUICallback('ready', function(_, cb)
    if uiOpen then
        Ui({ type = 'visibility', open = true, boot = BootPayload() })
    end
    cb('ok')
end)

RegisterNUICallback('play', function(data, cb)
    if type(data) ~= 'table' then return cb('error') end

    if not JamCanControl() then
        JamDeny()
        return cb(QueueState())
    end

    local incoming = {}

    if type(data.queue) == 'table' then
        for _, song in ipairs(data.queue) do
            if type(song) == 'table' and type(song.url) == 'string' and song.url ~= '' then
                incoming[#incoming + 1] = {
                    url = song.url,
                    title = song.title or 'Música',
                    thumb = song.thumb or '',
                    provider = song.provider == 'soundcloud' and 'soundcloud' or 'youtube'
                }
            end
            if #incoming >= Config.Limits.MaxQueue then break end
        end
    end

    if #incoming == 0 then
        if type(data.url) ~= 'string' or data.url == '' then return cb('error') end
        incoming = { {
            url = data.url, title = data.title or 'Música', thumb = data.thumb or '',
            provider = data.provider == 'soundcloud' and 'soundcloud' or 'youtube'
        } }
    end

    queue = incoming
    qIndex = math.floor(tonumber(data.index) or 0) + 1

    if qIndex < 1 then qIndex = 1 end
    if qIndex > #queue then qIndex = #queue end

    PlayIndex(qIndex, 0, true)
    cb(QueueState())
end)

RegisterNUICallback('control', function(data, cb)
    if type(data) ~= 'table' then return cb('error') end

    local action = data.action
    local value = tonumber(data.value) or 0

    -- Volume é sempre pessoal; o resto mexe na Jam de todos.
    if action ~= 'volume' and not JamCanControl() then
        JamDeny()
        return cb('ok')
    end

    if action == 'pause' then
        me.playing = false
        if me.kind == 'headphones' then Audio.Pause('hp') else TriggerServerEvent('solis:sv:control', me.sessId, 'pause') end
        if jam and JamCanControl() then TriggerServerEvent('solis:sv:jam', jam.code, 'pause', {}) end
        UpdateHeadphones()
    elseif action == 'resume' then
        me.playing = true
        if me.kind == 'headphones' then Audio.Resume('hp') else TriggerServerEvent('solis:sv:control', me.sessId, 'resume') end
        if jam and JamCanControl() then TriggerServerEvent('solis:sv:jam', jam.code, 'resume', {}) end
        UpdateHeadphones()
    elseif action == 'seek' then
        local target = tonumber(data.time) or 0
        if target < 0 then target = 0 end

        if me.kind == 'headphones' then
            Audio.Seek('hp', target)
        else
            TriggerServerEvent('solis:sv:control', me.sessId, 'seek', target)
        end

        if jam and JamCanControl() then TriggerServerEvent('solis:sv:jam', jam.code, 'seek', { time = target }) end
    elseif action == 'volume' then
        me.vol = math.max(0.0, math.min(1.0, value))

        if me.kind == 'headphones' then
            Audio.SetVolume('hp', ListenVol(me.vol))
        else
            -- Aplica localmente no mesmo frame; o echo do servidor só confirma.
            ApplyControlVolume(me.sessId, me.vol)
            TriggerServerEvent('solis:sv:control', me.sessId, 'volume', me.vol)
        end
    end

    PushQueue()
    cb('ok')
end)

RegisterNUICallback('queue', function(data, cb)
    local action = data and data.action

    if action == 'next' or action == 'prev' then
        if not JamCanControl() then
            JamDeny()
        elseif action == 'next' then
            Skip(1)
        else
            Skip(-1)
        end
    end

    cb(QueueState())
end)

RegisterNUICallback('repeat', function(data, cb)
    if not JamCanControl() then
        JamDeny()
        return cb(QueueState())
    end

    repeatMode = math.max(0, math.min(2, math.floor(tonumber(data and data.mode) or 0)))
    PushQueue()
    cb(QueueState())
end)

RegisterNUICallback('shuffle', function(data, cb)
    if not JamCanControl() then
        JamDeny()
        return cb(QueueState())
    end

    shuffleOn = data and data.on == true
    PushQueue()
    cb(QueueState())
end)

RegisterNUICallback('volumeLocal', function(data, cb)
    local value = tonumber(data and data.value)
    if value then
        localVolume = math.max(0.0, math.min(1.0, value))
        muted = (localVolume == 0.0)
        SaveVolumePrefs()
        for netId, held in pairs(heldVeh) do
            ApplyControlVolume('vehicle_' .. netId, held.vol or 0.5)
        end
        for stageId, held in pairs(heldStage) do
            ApplyControlVolume('stage_' .. stageId, held.vol or 0.5)
        end
        if me.kind == 'headphones' then Audio.SetVolume('hp', ListenVol(me.vol)) end
    end

    cb({ ["local"] = localVolume, muted = muted })
end)

RegisterNUICallback('sessions', function(_, cb)
    cb(Server.sessions() or {})
end)

RegisterNUICallback('sessionsFocus', function(data, cb)
    local list = Server.sessions() or {}
    for _, info in ipairs(list) do
        if info.sessId == data.sessId then
            if info.kind == 'jam' then
                jam = {
                    code = info.jamCode,
                    hostName = info.name,
                    isHost = info.isHost == true,
                    canControl = info.canControl == true,
                    mode = 'own'
                }
                Ui({ type = 'jam', jam = JamState() })
            else
                SetFocused(info)
            end
            cb('ok')
            return
        end
    end
    cb('error')
end)

RegisterNUICallback('sessionsLeave', function(data, cb)
    local sessId = data and data.sessId
    if not sessId then return cb('error') end

    if sessId:find('^jam_') then
        TriggerServerEvent('solis:sv:jamLeave', sessId:sub(5))
        jam = nil
        Ui({ type = 'jam', jam = nil })
        cb('ok')
        return
    end

    ReleaseSound(sessId)
    cb(Server.leave(sessId) and 'ok' or 'error')

    if sessId == me.sessId then SwitchToHeadphones() end
end)

RegisterNUICallback('bluetooth', function(_, cb)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local vehicles, stages = {}, {}
    local reach = Config.Bluetooth.ScanRadius

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(vehicle) then
            local target = GetEntityCoords(vehicle)
            local dx, dy, dz = coords.x - target.x, coords.y - target.y, coords.z - target.z

            if (dx * dx + dy * dy + dz * dz) <= reach * reach then
                local netId = NetworkGetNetworkIdFromEntity(vehicle)
                if netId ~= 0 then
                    local model = GetEntityModel(vehicle)
                    local name = GetLabelText(GetDisplayNameFromVehicleModel(model))
                    if name == 'NULL' then name = GetDisplayNameFromVehicleModel(model) end

                    vehicles[#vehicles + 1] = {
                        netId = netId,
                        plate = GetVehicleNumberPlateText(vehicle),
                        name = name
                    }
                end
            end
        end
    end

    for stageId, stage in pairs(Config.Stages) do
        local dx, dy = coords.x - stage.coords.x, coords.y - stage.coords.y
        local radius = stage.radius + 25.0
        if (dx * dx + dy * dy) <= radius * radius then
            stages[#stages + 1] = { id = stageId, name = stage.label }
        end
    end

    cb(Server.scan({ vehicles = vehicles, stages = stages }) or { paired = {}, others = {} })
end)

RegisterNUICallback('bluetoothConnect', function(data, cb)
    if type(data) ~= 'table' or type(data.device) ~= 'table' then return cb({ ok = false }) end

    local device = data.device
    local handoff = nil

    if data.handoff == true then
        handoff = {
            url = me.url,
            title = me.title,
            thumb = me.thumb,
            volume = me.vol,
            playing = me.playing,
            time = CurrentTime(),
            queue = queue,
            queueIndex = math.max(qIndex - 1, 0)
        }
    end

    local payload = {
        kind = device.kind,
        netId = device.netId,
        stageId = device.stageId,
        plate = device.plate,
        name = device.name,
        driver = false
    }

    if device.kind == 'vehicle' and IsPedInAnyVehicle(PlayerPedId(), false) then
        local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        if NetworkGetNetworkIdFromEntity(vehicle) == device.netId then
            payload.driver = GetPedInVehicleSeat(vehicle, -1) == PlayerPedId()
        end
    end

    local result = Server.connect(payload, handoff)

    if result and result.ok == true then
        if me.kind == 'headphones' then Audio.Destroy('hp') end
        SetFocused(result.session)
        Ui({ type = 'sessions', list = Server.sessions() or {} })
        cb({ status = 'connected' })
    elseif result and result.ok == 'pending' then
        cb({ status = 'pending', message = result.message })
    else
        cb({ status = 'error', message = (result and result.message) or 'Falha ao conectar.' })
    end
end)

RegisterNUICallback('bluetoothAuto', function(data, cb)
    cb(Server.autoReconnect(data.plate, data.on == true) and 'ok' or 'error')
end)

RegisterNUICallback('bluetoothForget', function(data, cb)
    cb(Server.forget(data.plate) and 'ok' or 'error')
end)

RegisterNUICallback('headphones', function(_, cb)
    SwitchToHeadphones()
    cb('ok')
end)

RegisterNUICallback('playlists', function(_, cb)
    cb(Server.playlists() or {})
end)

RegisterNUICallback('playlistSongs', function(data, cb)
    cb(Server.playlistSongs(data.id, data.offset or 0) or { songs = {}, total = 0 })
end)

RegisterNUICallback('playlistQueue', function(data, cb)
    cb(Server.playlistQueue(data.id, data.from) or {})
end)

RegisterNUICallback('playlistCreate', function(data, cb)
    TriggerServerEvent('solis:sv:playlistCreate', data.name, data.songs)
    cb('ok')
end)

RegisterNUICallback('playlistDelete', function(data, cb)
    TriggerServerEvent('solis:sv:playlistDelete', data.id)
    cb('ok')
end)

RegisterNUICallback('playlistAdd', function(data, cb)
    TriggerServerEvent('solis:sv:playlistAdd', data.id, data.song)
    cb('ok')
end)

RegisterNUICallback('playlistMove', function(data, cb)
    TriggerServerEvent('solis:sv:playlistMove', data.id, data.from, data.to)
    cb('ok')
end)

RegisterNUICallback('playlistRemove', function(data, cb)
    TriggerServerEvent('solis:sv:playlistRemove', data.id, data.index)
    cb('ok')
end)

RegisterNUICallback('nearbyPlayers', function(_, cb)
    cb(Server.nearbyPlayers() or {})
end)

RegisterNUICallback('airdropSend', function(data, cb)
    TriggerServerEvent('solis:sv:playlistAirdrop', data.id, data.passport)
    cb('ok')
end)

RegisterNUICallback('collabInvite', function(data, cb)
    TriggerServerEvent('solis:sv:playlistInvite', data.id, data.passport)
    cb('ok')
end)

RegisterNUICallback('recent', function(_, cb)
    cb(Server.recent() or {})
end)

RegisterNUICallback('jamCreate', function(_, cb)
    local result = Server.jamCreate({
        url = me.url,
        title = me.title,
        thumb = me.thumb,
        volume = me.vol,
        playing = me.playing,
        time = CurrentTime(),
        queue = queue,
        queueIndex = math.max(qIndex - 1, 0)
    })

    if result and result.ok then
        jam = {
            code = result.jam.code,
            hostName = result.jam.hostName,
            isHost = true,
            canControl = true,
            mode = 'own',
            members = result.jam.members
        }
        Ui({ type = 'jam', jam = JamState() })
    end

    cb(result or { ok = false })
end)

RegisterNUICallback('jamJoin', function(data, cb)
    local result = Server.jamJoin(data.code, data.mode or 'own')

    if result and result.ok then
        jam = {
            code = result.jam.code,
            hostName = result.jam.hostName,
            isHost = result.jam.isHost,
            canControl = result.jam.canControl == true or result.jam.isHost == true,
            mode = data.mode or 'own',
            members = result.jam.members
        }

        Ui({ type = 'jam', jam = JamState() })
        Ui({ type = 'sessions', list = Server.sessions() or {} })
    end

    cb(result or { ok = false })
end)

RegisterNUICallback('jamLeave', function(_, cb)
    local code = jam and jam.code
    jam = nil
    Ui({ type = 'jam', jam = nil })
    cb(code and Server.jamLeave(code) and 'ok' or 'error')
    Ui({ type = 'sessions', list = Server.sessions() or {} })
end)

RegisterNUICallback('jamEnd', function(_, cb)
    local code = jam and jam.code
    jam = nil
    Ui({ type = 'jam', jam = nil })
    cb(code and Server.jamEnd(code) and 'ok' or 'error')
end)

RegisterNUICallback('jamKick', function(data, cb)
    local result = jam and Server.jamKick(jam.code, data.passport)
    cb(result or { ok = false })
end)

RegisterNUICallback('jamAllow', function(data, cb)
    local result = jam and Server.jamAllow(jam.code, data.passport, data.allowed == true)
    cb(result or { ok = false })
end)

RegisterNUICallback('jamInvite', function(data, cb)
    if jam then TriggerServerEvent('solis:sv:jamInvite', jam.code, data.passport) end
    cb('ok')
end)

RegisterNUICallback('jamCode', function(_, cb)
    cb(JamState() and JamState().code or '')
end)

-- ==========================================
-- COMANDOS
-- ==========================================
local function ApplyLocalVolume(value)
    localVolume = math.max(0.0, math.min(1.0, value))
    muted = (localVolume == 0.0)
    SaveVolumePrefs()

    for netId, held in pairs(heldVeh) do
        held.state = nil
        Audio.SetVolume(VehicleSoundId(netId), ListenVol(held.vol))
    end
    for stageId, held in pairs(heldStage) do
        held.state = nil
        Audio.SetVolume(StageSoundId(stageId), ListenVol(held.vol))
    end
    if me.kind == 'headphones' then Audio.SetVolume('hp', ListenVol(me.vol)) end

    Ui({ type = 'localVolume', ["local"] = localVolume, muted = muted })
end

RegisterCommand('som', function(_, args)
    local arg = args and args[1]

    if not arg or arg == '' then
        if uiOpen then
            uiOpen = false
            SetNuiFocus(false, false)
            Ui({ type = 'visibility', open = false })
        else
            uiOpen = true
            SetNuiFocus(true, true)
            Ui({ type = 'visibility', open = true, boot = BootPayload() })
        end
        return
    end

    local lower = string.lower(arg)

    if lower == 'off' or lower == 'mute' or lower == 'mudo' or lower == '0' then
        ApplyLocalVolume(0.0)
        Toast('warning', 'Volume individual mutado.', 'Solis')
        return
    end

    if lower == 'on' then
        ApplyLocalVolume(localVolume <= 0.0 and 1.0 or localVolume)
        Toast('success', ('Volume individual em %d%%.'):format(math.floor(localVolume * 100)), 'Solis')
        return
    end

    local value = tonumber(lower) or tonumber(args and args[2])
    if value then
        value = math.max(0, math.min(100, value))
        ApplyLocalVolume(value / 100.0)
        Toast('success', ('Volume individual em %d%%.'):format(value), 'Solis')
        return
    end

    Toast('error', 'Uso: /som, /som [1-100], /som on ou /som off.', 'Solis')
end, false)

RegisterCommand('som1', function(_, args)
    ExecuteCommand('som ' .. table.concat(args or {}, ' '))
end, false)

-- ==========================================
-- EXPORTS (integração com o celular)
-- ==========================================
exports('PlayPhoneMusic', function(url, title, thumb)
    if not JamCanControl() then JamDeny(); return end
    if type(url) ~= 'string' or url == '' then return end
    if not url:find('http') then url = 'https://www.youtube.com/watch?v=' .. url end

    queue = { { url = url, title = title or 'Música do celular', thumb = thumb or '' } }
    qIndex = 1
    PlayIndex(1, 0, true)
end)

exports('PausePhoneMusic', function()
    me.playing = false
    if me.kind == 'headphones' then Audio.Pause('hp') else TriggerServerEvent('solis:sv:control', me.sessId, 'pause') end
    UpdateHeadphones()
end)

exports('ResumePhoneMusic', function()
    me.playing = true
    if me.kind == 'headphones' then Audio.Resume('hp') else TriggerServerEvent('solis:sv:control', me.sessId, 'resume') end
    UpdateHeadphones()
end)

exports('SeekPhoneMusic', function(time)
    if not JamCanControl() then JamDeny(); return end

    local target = math.max(0, tonumber(time) or 0)
    if me.kind == 'headphones' then
        Audio.Seek('hp', target)
    else
        TriggerServerEvent('solis:sv:control', me.sessId, 'seek', target)
    end
end)

exports('SetPhoneVolume', function(volume)
    me.vol = math.max(0.0, math.min(1.0, tonumber(volume) or 0.5))
    if me.kind == 'headphones' then
        Audio.SetVolume('hp', ListenVol(me.vol))
    else
        TriggerServerEvent('solis:sv:control', me.sessId, 'volume', me.vol)
    end
end)

exports('GetPhoneAudioState', function()
    return {
        playing = me.playing,
        currentTime = CurrentTime(),
        duration = CurrentDuration(),
        volume = me.vol,
        mode = me.kind,
        device = me.name
    }
end)

exports('GetIndividualVolume', function()
    return localVolume, muted
end)

exports('SetIndividualVolume', function(volume)
    ApplyLocalVolume(tonumber(volume) or localVolume)
end)

-- ==========================================
-- PONTE fphone2 (contrato mantido)
-- ==========================================
RegisterNetEvent('spotifive:bridge:requestInit', function(cb)
    if cb then cb(BootPayload()) end
end)

AddEventHandler('spotifive:bridge:requestInit', function(cb)
    if cb then cb(BootPayload()) end
end)

AddEventHandler('spotifive:bridge:handleAction', function(action, data, cb)
    data = data or {}

    if action == 'playMusic' then
        queue = { { url = data.url, title = data.title or 'Música', thumb = data.thumb or '' } }
        qIndex = 1
        PlayIndex(1, 0, true)
    elseif action == 'controlMusic' then
        local control = data.action
        if control == 'pause' then
            me.playing = false
            if me.kind == 'headphones' then Audio.Pause('hp') else TriggerServerEvent('solis:sv:control', me.sessId, 'pause') end
        elseif control == 'resume' then
            me.playing = true
            if me.kind == 'headphones' then Audio.Resume('hp') else TriggerServerEvent('solis:sv:control', me.sessId, 'resume') end
        elseif control == 'seek' then
            local target = math.max(0, tonumber(data.time) or 0)
            if me.kind == 'headphones' then Audio.Seek('hp', target) else TriggerServerEvent('solis:sv:control', me.sessId, 'seek', target) end
        elseif control == 'volume' then
            me.vol = math.max(0.0, math.min(1.0, tonumber(data.value) or 0.5))
            if me.kind == 'headphones' then Audio.SetVolume('hp', ListenVol(me.vol)) else TriggerServerEvent('solis:sv:control', me.sessId, 'volume', me.vol) end
        end
        UpdateHeadphones()
    elseif action == 'setIndividualVolume' then
        ApplyLocalVolume(tonumber(data.value) or localVolume)
    elseif action == 'switchToHeadphones' then
        SwitchToHeadphones()
    end

    if cb then cb('ok') end
end)

-- server.lua — solis_sound
-- Toda a verdade sobre sessões de áudio vive aqui. O cliente pede, o servidor
-- valida e só então fala com quem precisa ouvir (nunca com -1).

-- Base do servidor: bridge/server.lua (Config.Framework). Nada aqui fala
-- com vRP/QBCore/ESX direto.
local RES = GetCurrentResourceName()
local API = {}
Bridge.bindInterface(RES, API)

local Limits = Config.Limits
local Net = Config.Net
local RL = Config.RateLimit

-- ==========================================
-- CACHE DE JOGADOR
-- ==========================================
local Players = {}   -- [src] = { passport }
local Names = {}     -- [passport] = { name, at }
local NameCount = 0
local Plates = {}    -- [plate] = { passport, at }

local function PassportOf(src)
    local p = Players[src]
    if p and p.passport then return p.passport end

    local passport = Bridge.GetId(src)
    if not passport then return nil end

    Players[src] = Players[src] or {}
    Players[src].passport = passport
    return passport
end

local function NameOf(passport)
    if not passport then return 'Cidadão' end

    local now = os.time()
    local cached = Names[passport]
    if cached and (now - cached.at) < 300 then return cached.name end

    local name = Bridge.GetName(passport) or 'Cidadão'

    if not Names[passport] then NameCount = NameCount + 1 end
    if NameCount > 4000 then
        Names = {}
        NameCount = 1
    end

    Names[passport] = { name = name, at = now }
    return name
end

local function PlateOwner(plate)
    if not plate or plate == '' then return nil end

    local now = os.time()
    local cached = Plates[plate]
    if cached and (now - cached.at) < 120 then return cached.passport end

    local passport = Bridge.GetPlateOwner(plate)
    Plates[plate] = { passport = passport, at = now }
    return passport
end

local function PedCoords(src)
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    return GetEntityCoords(ped)
end

-- ==========================================
-- ANTI-FLOOD
-- ==========================================
local Buckets = {}

local function Allowed(src, isWrite)
    local now = GetGameTimer()
    local b = Buckets[src]

    if not b or (now - b.at) > RL.Window then
        b = { actions = 0, writes = 0, at = now }
        Buckets[src] = b
    end

    if isWrite then
        if b.writes >= RL.Writes then return false end
        b.writes = b.writes + 1
    end

    if b.actions >= RL.Actions then return false end
    b.actions = b.actions + 1
    return true
end

-- ==========================================
-- SANITIZAÇÃO
-- ==========================================
local function Trim(value, maxLen)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' then return nil end
    if #value > maxLen then value = value:sub(1, maxLen) end
    return value
end

local function SafeUrl(value, maxLen)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('%s', '')
    if #value > (maxLen or Limits.MaxUrl) then return nil end
    if not value:match("^https?://[%w%-%._~:/?#%[%]@!$&'()*+,;=%%]+$") then return nil end
    return value
end

local function Clamp(value, minV, maxV)
    if type(value) ~= 'number' or value ~= value then return minV end
    if value < minV then return minV end
    if value > maxV then return maxV end
    return value
end

local function SongProvider(song)
    return (type(song) == 'table' and song.provider == 'soundcloud') and 'soundcloud' or 'youtube'
end

local function TrimQueue(list)
    local out = {}
    if type(list) ~= 'table' then return out end

    for _, song in ipairs(list) do
        if #out >= Limits.MaxQueue then break end
        if type(song) == 'table' then
            local url = SafeUrl(song.url)
            if url then
                out[#out + 1] = {
                    url = url,
                    title = Trim(song.title, Limits.MaxTitle) or 'Música',
                    thumb = SafeUrl(song.thumb, Limits.MaxThumb) or '',
                    provider = SongProvider(song)
                }
            end
        end
    end

    return out
end

local function SongPayload(song)
    if type(song) ~= 'table' then return nil end
    local url = SafeUrl(song.url)
    if not url then return nil end
    return {
        url = url,
        title = Trim(song.title, Limits.MaxTitle) or 'Música',
        thumb = SafeUrl(song.thumb, Limits.MaxThumb) or '',
        provider = SongProvider(song)
    }
end

-- ==========================================
-- SOUNDCLOUD (API INTERNA DO SITE)
-- ==========================================
local SC = Config.SoundCloud or {}
local scClientId = Trim(SC.ClientId or '', 128) or ''

local function UrlEncode(value)
    return (tostring(value or ''):gsub('([^%w%-_%.~])', function (c)
        return string.format('%%%02X', string.byte(c))
    end))
end

-- ==========================================
-- YOUTUBE PUBLICO (fallback da Data API)
-- ==========================================
-- A Data API tem limite baixo de search_list por dia. Quando a chave esgota a
-- cota, continuamos lendo os dados publicos da pagina do proprio YouTube.
-- Nada de proxy externo: a requisicao sai do servidor do recurso.
local ytCache = {}
local YT_CACHE_TTL = 300

local YT_HEADERS = {
    ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36',
    ['Accept-Language'] = 'pt-BR,pt;q=0.9,en;q=0.8'
}

local function YtText(value)
    if type(value) == 'string' then return value end
    if type(value) ~= 'table' then return '' end

    if type(value.simpleText) == 'string' then return value.simpleText end
    if type(value.runs) == 'table' then
        local out = ''
        for _, run in ipairs(value.runs) do
            out = out .. tostring(run.text or '')
        end
        return out
    end
    return ''
end

local function YtDecode(value)
    if type(value) ~= 'string' then return '' end

    value = (value:gsub('&amp;', '&'))
    value = (value:gsub('&quot;', '"'))
    value = (value:gsub('&#39;', "'"))
    value = (value:gsub('&#x27;', "'"))
    value = (value:gsub('&lt;', '<'))
    value = (value:gsub('&gt;', '>'))
    value = (value:gsub('&#(%d+);', function (n)
        local code = tonumber(n) or 0
        if code > 0 and code < 256 then return string.char(code) end
        return ''
    end))
    return value
end

local function YtDuration(value)
    local total = 0
    for part in tostring(value or ''):gmatch('%d+') do
        total = (total * 60) + tonumber(part)
    end
    return total
end

local function YtExtractJson(html, marker)
    if type(html) ~= 'string' then return nil end

    local startAt = string.find(html, marker, 1, true)
    if not startAt then return nil end
    startAt = startAt + #marker

    local endAt = string.find(html, ';</script>', startAt, true) or #html
    if endAt <= startAt then return nil end
    return html:sub(startAt, endAt - 1)
end

local function YtInitialData(html)
    local markers = { 'var ytInitialData = ', 'ytInitialData = ' }
    for _, marker in ipairs(markers) do
        local jsonText = YtExtractJson(html, marker)
        if jsonText then
            local ok, data = pcall(json.decode, jsonText)
            if ok and type(data) == 'table' then return data end
        end
    end
    return nil
end

local function YtPlayerResponse(html)
    local markers = { 'var ytInitialPlayerResponse = ', 'ytInitialPlayerResponse = ' }
    for _, marker in ipairs(markers) do
        local jsonText = YtExtractJson(html, marker)
        if jsonText then
            local ok, data = pcall(json.decode, jsonText)
            if ok and type(data) == 'table' then return data end
        end
    end
    return nil
end

local function YtWalk(node, visit, limit)
    if type(node) ~= 'table' then return end
    if visit(node) then return end

    if #node > 0 then
        for i = 1, #node do
            YtWalk(node[i], visit, limit)
            if limit() then return end
        end
    else
        for _, child in pairs(node) do
            YtWalk(child, visit, limit)
            if limit() then return end
        end
    end
end

local function YtSongFromRenderer(renderer)
    local id = renderer.videoId
    if type(id) ~= 'string' or #id ~= 11 then return nil end

    local thumb = ''
    local thumbs = renderer.thumbnail and renderer.thumbnail.thumbnails
    if type(thumbs) == 'table' and #thumbs > 0 then
        local pick = math.min(2, #thumbs)
        thumb = tostring(thumbs[pick].url or thumbs[1].url or '')
    end

    local artist = YtDecode(YtText(renderer.ownerText
        or renderer.longBylineText
        or renderer.shortBylineText
        or renderer.byLineText))
    if artist == '' then artist = 'YouTube' end

    return {
        url = 'https://www.youtube.com/watch?v=' .. id,
        title = YtDecode(YtText(renderer.title)),
        artist = artist,
        thumb = thumb,
        provider = 'youtube',
        duration = YtDuration(YtText(renderer.lengthText))
    }
end

local function YtSongFromLockup(lockup)
    if type(lockup) ~= 'table' then return nil end
    if lockup.contentType and lockup.contentType ~= 'LOCKUP_CONTENT_TYPE_VIDEO' then return nil end

    local id = lockup.contentId
    if type(id) ~= 'string' or #id ~= 11 then return nil end

    local meta = (lockup.metadata and lockup.metadata.lockupMetadataViewModel) or {}

    local title = ''
    if type(meta.title) == 'table' then
        title = YtDecode(YtText(meta.title.content or meta.title))
    end

    local artist = 'YouTube'
    local rows = meta.metadata
        and meta.metadata.contentMetadataViewModel
        and meta.metadata.contentMetadataViewModel.metadataRows
    if type(rows) == 'table' and type(rows[1]) == 'table' then
        local parts = rows[1].metadataParts
        if type(parts) == 'table' and type(parts[1]) == 'table' then
            local text = parts[1].text
            local name = type(text) == 'table' and (text.content or YtText(text)) or ''
            if name ~= '' then artist = YtDecode(tostring(name)) end
        end
    end

    local thumb = ''
    local thumbVm = lockup.contentImage and lockup.contentImage.thumbnailViewModel
    local sources = thumbVm and thumbVm.image and thumbVm.image.sources
    if type(sources) == 'table' and #sources > 0 then
        local pick = math.min(2, #sources)
        thumb = tostring(sources[pick].url or sources[1].url or '')
    end

    local duration = 0
    local overlays = thumbVm and thumbVm.overlays
    if type(overlays) == 'table' then
        for _, overlay in ipairs(overlays) do
            local badges = overlay.thumbnailBottomOverlayViewModel
                and overlay.thumbnailBottomOverlayViewModel.badges
            if type(badges) == 'table' and type(badges[1]) == 'table' then
                local badge = badges[1].thumbnailBadgeViewModel
                if type(badge) == 'table' then
                    duration = YtDuration(YtDecode(tostring(badge.text or '')))
                    if duration > 0 then break end
                end
            end
        end
    end

    return {
        url = 'https://www.youtube.com/watch?v=' .. id,
        title = title,
        artist = artist,
        thumb = thumb,
        provider = 'youtube',
        duration = duration
    }
end

local function YtParseSearch(html)
    local data = YtInitialData(html)
    if not data then return {} end

    local songs = {}
    YtWalk(data, function (node)
        if type(node.videoRenderer) == 'table' then
            local song = YtSongFromRenderer(node.videoRenderer)
            if song then songs[#songs + 1] = song end
            return true
        end
        if type(node.lockupViewModel) == 'table' then
            local song = YtSongFromLockup(node.lockupViewModel)
            if song then songs[#songs + 1] = song end
            return true
        end
        return false
    end, function () return #songs >= 18 end)
    return songs
end

local function YtParsePlaylist(html)
    local data = YtInitialData(html)
    if not data then return {}, 'Playlist do YouTube' end

    local songs, title = {}, ''
    YtWalk(data, function (node)
        if type(node.playlistMetadataRenderer) == 'table' and title == '' then
            title = YtDecode(YtText(node.playlistMetadataRenderer.title))
            return true
        end
        if type(node.playlistVideoRenderer) == 'table' then
            local song = YtSongFromRenderer(node.playlistVideoRenderer)
            if song then songs[#songs + 1] = song end
            return true
        end
        if type(node.lockupViewModel) == 'table' then
            local song = YtSongFromLockup(node.lockupViewModel)
            if song then songs[#songs + 1] = song end
            return true
        end
        return false
    end, function () return #songs >= 100 end)

    if title == '' then title = 'Playlist do YouTube' end
    return songs, title
end

local function YtMeta(html, property)
    if type(html) ~= 'string' then return '' end

    local value = html:match('<meta%s+property="' .. property .. '"%s+content="([^"]+)"')
    if not value then
        value = html:match('<meta%s+content="([^"]+)"%s+property="' .. property .. '"')
    end
    return YtDecode(value or '')
end

local function YtParseVideo(html, videoId)
    local response = YtPlayerResponse(html)
    local details = response and response.videoDetails

    if type(details) ~= 'table' or not details.videoId then
        local id = videoId
        if type(id) ~= 'string' or #id ~= 11 then return nil end
        return {
            url = 'https://www.youtube.com/watch?v=' .. id,
            title = YtMeta(html, 'og:title'),
            artist = 'YouTube',
            thumb = YtMeta(html, 'og:image'),
            provider = 'youtube',
            duration = 0
        }
    end

    local thumb = ''
    local thumbs = details.thumbnail and details.thumbnail.thumbnails
    if type(thumbs) == 'table' and #thumbs > 0 then
        local pick = math.min(2, #thumbs)
        thumb = tostring(thumbs[pick].url or thumbs[1].url or '')
    end
    if thumb == '' then thumb = YtMeta(html, 'og:image') end

    local artist = YtDecode(YtText(details.author))
    if artist == '' then artist = 'YouTube' end

    return {
        url = 'https://www.youtube.com/watch?v=' .. details.videoId,
        title = YtDecode(YtText(details.title)),
        artist = artist,
        thumb = thumb,
        provider = 'youtube',
        duration = tonumber(details.lengthSeconds) or 0
    }
end

local function YtFetch(path, cb)
    PerformHttpRequest('https://www.youtube.com' .. path, function (status, body)
        if status ~= 200 or type(body) ~= 'string' then cb(nil); return end
        cb(body)
    end, 'GET', '', YT_HEADERS)
end

RegisterNetEvent('solis:sv:ytFallback', function (reqId, data)
    local src = source

    if not Allowed(src, false) then
        TriggerClientEvent('solis:cl:apiResult', src, reqId, { songs = {}, error = 'rate_limited' })
        return
    end

    data = type(data) == 'table' and data or {}
    local kind = tostring(data.kind or '')
    local payload = tostring(data.query or data.videoId or data.playlistId or '')

    local answer = function (res)
        TriggerClientEvent('solis:cl:apiResult', src, reqId, res)
    end

    if payload == '' then
        answer({ songs = {}, error = 'empty' })
        return
    end

    local cacheKey = kind .. ':' .. string.lower(payload)
    local cached = ytCache[cacheKey]
    if cached and (os.time() - cached.at) < YT_CACHE_TTL then
        answer(cached.res)
        return
    end

    local path
    if kind == 'search' then
        path = '/results?search_query=' .. UrlEncode(payload)
    elseif kind == 'video' then
        path = '/watch?v=' .. UrlEncode(payload)
    elseif kind == 'playlist' then
        path = '/playlist?list=' .. UrlEncode(payload)
    else
        answer({ songs = {}, error = 'invalid' })
        return
    end

    YtFetch(path, function (html)
        local res

        if not html then
            res = { songs = {}, error = 'network' }
        elseif kind == 'search' then
            res = { songs = YtParseSearch(html) }
        elseif kind == 'video' then
            local song = YtParseVideo(html, payload)
            res = song and { songs = { song } } or { songs = {}, error = 'not_found' }
        else
            local songs, title = YtParsePlaylist(html)
            res = { songs = songs, title = title }
        end

        if not res.error then
            ytCache[cacheKey] = { at = os.time(), res = res }
        end
        answer(res)
    end)
end)

local function ScRequest(path, params, cb)
    if not SC.Enabled or scClientId == '' then
        cb(nil, 'disabled')
        return
    end

    local query = {}
    for key, value in pairs(params or {}) do
        query[#query + 1] = UrlEncode(key) .. '=' .. UrlEncode(value)
    end
    query[#query + 1] = 'client_id=' .. UrlEncode(scClientId)

    local url
    if path:match('^https?://') then
        -- URL absoluta devolvida pela API (ex.: /media/.../stream/hls).
        -- Não pode receber o ApiBase: isso geraria "...comhttps://...".
        local separator = path:find('?', 1, true) and '&' or '?'
        url = path .. separator .. table.concat(query, '&')
    else
        url = (SC.ApiBase or 'https://api-v2.soundcloud.com') .. path .. '?' .. table.concat(query, '&')
    end

    PerformHttpRequest(url, function (status, body)
        if status ~= 200 or type(body) ~= 'string' then
            cb(nil, 'http_' .. tostring(status))
            return
        end

        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' then
            cb(nil, 'bad_json')
            return
        end

        cb(data)
    end, 'GET', '', {
        ['Accept'] = 'application/json; charset=utf-8',
        ['Origin'] = SC.SiteUrl or 'https://soundcloud.com',
        ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'
    })
end

local function ScSong(track)
    if type(track) ~= 'table' then return nil end

    -- O widget precisa do permalink (página da faixa), não do uri da API.
    local url = SafeUrl(track.permalink_url)
    if not url then return nil end

    local user = type(track.user) == 'table' and track.user or {}
    local thumb = SafeUrl(track.artwork_url or user.avatar_url or '', Limits.MaxThumb) or ''
    thumb = thumb:gsub('-large%.', '-t500x500.')

    return {
        url = url,
        title = Trim(track.title, Limits.MaxTitle) or 'Faixa do SoundCloud',
        artist = Trim(user.username or 'SoundCloud', Limits.MaxTitle) or 'SoundCloud',
        thumb = thumb,
        provider = 'soundcloud',
        scId = track.id and tostring(track.id) or '',
        scDuration = tonumber(track.duration) or 0
    }
end

local function ScSearch(query, cb)
    query = Trim(query, 120)
    if not query then cb({}, 'empty'); return end

    ScRequest('/search/tracks', {
        q = query,
        limit = SC.SearchLimit or 18,
        linked_partitioning = 1
    }, function (data, err)
        if err then cb({}, err); return end

        local songs = {}
        for _, track in ipairs(data.collection or {}) do
            local song = ScSong(track)
            if song then songs[#songs + 1] = song end
        end
        cb(songs)
    end)
end

local function ScResolve(rawUrl, cb)
    local url = SafeUrl(rawUrl)
    if not url then cb(nil, 'invalid_url'); return end

    ScRequest('/resolve', { url = url }, function (data, err)
        if err then cb(nil, err); return end
        cb(ScSong(data))
    end)
end

-- Resolve o stream direto (HLS/MP3) da faixa. Tocar num <audio> com CORS é o
-- que permite aplicar o grafo WebAudio (lowpass) — o widget do SoundCloud é
-- cross-origin e não deixa o DSP alcançar o áudio.
local function ScStream(song, cb)
    if type(song) ~= 'table' then cb(nil, 'invalid'); return end

    local function withTrack(track)
        if type(track) ~= 'table' or track.id == nil then cb(nil, 'no_track'); return end

        local media = type(track.media) == 'table' and track.media.transcodings or nil
        if type(media) ~= 'table' or #media == 0 then cb(nil, 'no_media'); return end

        local chosen = nil
        local kind = ''
        -- progressivo (MP3) é preferido: toca direto, sem hls.js. Trechos
        -- "snipped" de 30s não contam — o HLS costuma ter a faixa completa.
        for _, item in ipairs(media) do
            if type(item) == 'table' and type(item.url) == 'string'
                and item.format and item.format.protocol == 'progressive'
                and item.snipped ~= true then
                chosen = item; kind = 'mp3'; break
            end
        end
        if not chosen then
            for _, item in ipairs(media) do
                if type(item) == 'table' and type(item.url) == 'string'
                    and item.format and item.format.protocol == 'hls' then
                    chosen = item; kind = 'hls'; break
                end
            end
        end
        if not chosen then cb(nil, 'no_transcoding'); return end

        local params = {}
        if track.track_authorization and track.track_authorization ~= '' then
            params.track_authorization = track.track_authorization
        end

        ScRequest(chosen.url, params, function (resolved, err)
            if err or type(resolved) ~= 'table' or not resolved.url then
                cb(nil, err or 'no_stream_url')
                return
            end
            cb({ url = resolved.url, kind = kind, duration = tonumber(track.duration) or 0 })
        end)
    end

    local trackId = song.scId
    if trackId and trackId ~= '' then
        ScRequest('/tracks/' .. UrlEncode(trackId), {}, withTrack)
    else
        local permalink = SafeUrl(song.url)
        if not permalink then cb(nil, 'invalid_url'); return end
        ScRequest('/resolve', { url = permalink }, withTrack)
    end
end

RegisterNetEvent('solis:sv:scSearch', function (reqId, query)
    local src = source

    if not Allowed(src, false) then
        TriggerClientEvent('solis:cl:scResult', src, reqId, {}, 'rate_limited')
        return
    end

    ScSearch(query, function (songs, err)
        TriggerClientEvent('solis:cl:scResult', src, reqId, songs, err)
    end)
end)

RegisterNetEvent('solis:sv:scResolve', function (reqId, url)
    local src = source

    if not Allowed(src, false) then
        TriggerClientEvent('solis:cl:scResolveResult', src, reqId, nil, 'rate_limited')
        return
    end

    ScResolve(url, function (song, err)
        TriggerClientEvent('solis:cl:scResolveResult', src, reqId, song, err)
    end)
end)

-- O motor de áudio pede o stream direto para poder aplicar o DSP.
RegisterNetEvent('solis:sv:scStream', function (soundId, song)
    local src = source
    if not Allowed(src, false) then return end

    ScStream(song, function (result, err)
        TriggerClientEvent('solis:audio:scStream', src, soundId, result, err)
    end)
end)

-- ==========================================
-- SESSÕES
-- ==========================================
local Sessions = {}   -- [sessId] = session
local ByUser = {}     -- [src] = { [sessId] = true }
local Watchers = {}   -- [sessId] = { [src] = true }  (quem está perto)
local Interests = {}  -- [src] = { [sessId] = true }
local Jams = {}       -- [code] = jam
local Pending = {}    -- [reqId] = request
local RequestId = 0

local function Elapsed(sess)
    local t = sess.base or 0
    if sess.playing and sess.startedAt then
        t = t + math.max(0, os.time() - sess.startedAt)
    end
    return t
end

local function Touch(sess)
    sess.startedAt = sess.playing and os.time() or nil
end

local function SessionCount(src)
    local n = 0
    local set = ByUser[src]
    if set then
        for _ in pairs(set) do n = n + 1 end
    end
    return n
end

local function PlayEvent(sess)
    return {
        sessId = sess.id,
        kind = sess.kind,
        netId = sess.netId,
        stageId = sess.stageId,
        url = sess.url,
        vol = sess.vol,
        time = Elapsed(sess),
        title = sess.title,
        thumb = sess.thumb
    }
end

local function SessionInfo(sess, src)
    return {
        sessId = sess.id,
        kind = sess.kind,
        netId = sess.netId,
        stageId = sess.stageId,
        plate = sess.plate,
        name = sess.name,
        title = sess.title,
        thumb = sess.thumb,
        url = sess.url,
        vol = sess.vol,
        playing = sess.playing,
        time = Elapsed(sess),
        queue = sess.queue,
        queueIndex = sess.queueIndex,
        focus = (sess.controller == src)
    }
end

local PushSessions
local GetJamPlayback
local BustPlaylist, FetchPlaylists, SyncCollaborators

-- ==========================================
-- SPOTIFY (WEB API - SÓ CATÁLOGO)
-- ==========================================
-- A Web API não devolve áudio reproduzível. As faixas do Spotify são usadas
-- como metadados e resolvidas para YouTube/SoundCloud antes de entrar na fila.
local SP = Config.Spotify or {}
local spToken = nil
local spTokenUntil = 0
local spFetching = false
local spWaiters = {}

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function Base64Encode(input)
    local out = {}
    local n = #input
    local i = 1

    while i <= n do
        local a = input:byte(i)
        local b = (i + 1 <= n) and input:byte(i + 1) or 0
        local c = (i + 2 <= n) and input:byte(i + 2) or 0
        local packed = a * 65536 + b * 256 + c

        local i1 = math.floor(packed / 262144) % 64
        local i2 = math.floor(packed / 4096) % 64
        local i3 = math.floor(packed / 64) % 64
        local i4 = packed % 64

        out[#out + 1] = B64:sub(i1 + 1, i1 + 1)
        out[#out + 1] = B64:sub(i2 + 1, i2 + 1)
        out[#out + 1] = (i + 1 <= n) and B64:sub(i3 + 1, i3 + 1) or '='
        out[#out + 1] = (i + 2 <= n) and B64:sub(i4 + 1, i4 + 1) or '='

        i = i + 3
    end

    return table.concat(out)
end

local function SpFetchToken(cb)
    if spFetching then
        spWaiters[#spWaiters + 1] = cb
        return
    end
    spFetching = true

    local basic = Base64Encode(SP.ClientId .. ':' .. SP.ClientSecret)

    PerformHttpRequest(SP.TokenUrl or 'https://accounts.spotify.com/api/token', function (status, body)
        spFetching = false

        local token = nil
        if status == 200 and type(body) == 'string' then
            local ok, data = pcall(json.decode, body)
            if ok and type(data) == 'table' and data.access_token then
                token = data.access_token
                spToken = token
                spTokenUntil = GetGameTimer() + math.max(60, (tonumber(data.expires_in) or 3600) - 120) * 1000
            end
        end

        for _, waiter in ipairs(spWaiters) do waiter(token) end
        spWaiters = {}

        cb(token)
    end, 'POST', 'grant_type=client_credentials', {
        ['Authorization'] = 'Basic ' .. basic,
        ['Content-Type'] = 'application/x-www-form-urlencoded'
    })
end

local function SpToken(cb)
    if spToken and GetGameTimer() < spTokenUntil then
        cb(spToken)
        return
    end
    SpFetchToken(cb)
end

local function SpEnabled()
    return SP.Enabled == true
        and type(SP.ClientId) == 'string' and SP.ClientId ~= ''
        and type(SP.ClientSecret) == 'string' and SP.ClientSecret ~= ''
end

local function SpRequest(path, params, cb, retried)
    if not SpEnabled() then cb(nil, 'disabled'); return end

    SpToken(function (token)
        if not token then cb(nil, 'auth'); return end

        local query = {}
        for key, value in pairs(params or {}) do
            query[#query + 1] = UrlEncode(key) .. '=' .. UrlEncode(value)
        end

        local url = (SP.ApiBase or 'https://api.spotify.com/v1') .. path
        if #query > 0 then url = url .. '?' .. table.concat(query, '&') end

        PerformHttpRequest(url, function (status, body)
            if status == 401 and not retried then
                spToken = nil
                SpRequest(path, params, cb, true)
                return
            end

            if status ~= 200 or type(body) ~= 'string' then
                cb(nil, 'http_' .. tostring(status))
                return
            end

            local ok, data = pcall(json.decode, body)
            if not ok or type(data) ~= 'table' then cb(nil, 'bad_json'); return end

            cb(data)
        end, 'GET', '', {
            ['Authorization'] = 'Bearer ' .. token,
            ['Accept'] = 'application/json'
        })
    end)
end

local function SpSong(track)
    if type(track) ~= 'table' or type(track.id) ~= 'string' or track.id == '' then return nil end

    local images = (type(track.album) == 'table' and track.album.images) or {}
    local thumb = ''
    for _, image in ipairs(images) do
        if type(image.url) == 'string' then thumb = image.url; break end
    end
    thumb = SafeUrl(thumb, Limits.MaxThumb) or ''

    local artists = track.artists or {}
    local artist = (artists[1] and artists[1].name) or 'Spotify'
    local external = track.external_ids or {}

    return {
        url = 'https://open.spotify.com/track/' .. track.id,
        title = Trim(track.name, Limits.MaxTitle) or 'Faixa do Spotify',
        artist = Trim(artist, Limits.MaxTitle) or 'Spotify',
        thumb = thumb,
        provider = 'spotify',
        spId = track.id,
        isrc = Trim(external.isrc or '', 32) or ''
    }
end

local function SpSearch(query, cb)
    query = Trim(query, 120)
    if not query then cb({}, 'empty'); return end

    SpRequest('/search', {
        q = query,
        type = 'track',
        limit = SP.SearchLimit or 18,
        market = SP.Market or 'BR'
    }, function (data, err)
        if err then cb({}, err); return end

        local songs = {}
        local items = (type(data.tracks) == 'table' and data.tracks.items) or {}
        for _, track in ipairs(items) do
            local song = SpSong(track)
            if song then songs[#songs + 1] = song end
        end
        cb(songs)
    end)
end

local function SpLink(value)
    if type(value) ~= 'string' then return nil end

    local trackId = value:match('open%.spotify%.com/track/([%w%-_]+)')
        or value:match('spotify:track:([%w%-_]+)')
    if trackId then return 'track', trackId end

    local playlistId = value:match('open%.spotify%.com/playlist/([%w%-_]+)')
        or value:match('spotify:playlist:([%w%-_]+)')
    if playlistId then return 'playlist', playlistId end

    return nil
end

-- Converte um item do catálogo em algo que o motor de áudio consegue tocar.
-- Mantém provider='spotify' para o selo continuar aparecendo na fila.
local function SpPlayable(song, playable)
    if not playable then return nil end
    return {
        url = playable.url,
        title = song.title,
        artist = song.artist,
        thumb = song.thumb,
        provider = 'spotify',
        spId = song.spId
    }
end

local function ResolvePlayable(song, cb)
    local query = (song.artist or '') .. ' ' .. (song.title or '')

    local function viaSoundCloud()
        ScSearch(query, function (songs)
            cb(songs[1] or nil)
        end)
    end

    local function viaYoutubePublic()
        YtFetch('/results?search_query=' .. UrlEncode(query), function (html)
            local songs = html and YtParseSearch(html) or {}
            local song = songs[1]
            if song then
                cb({ url = song.url })
            else
                viaSoundCloud()
            end
        end)
    end

    if SP.Resolver == 'soundcloud' then
        viaSoundCloud()
        return
    end

    local key = Config.YoutubeAPIKey
    if not key or key == '' then viaYoutubePublic(); return end

    local url = 'https://www.googleapis.com/youtube/v3/search?part=snippet&type=video'
        .. '&maxResults=3&q=' .. UrlEncode(query) .. '&key=' .. UrlEncode(key)

    PerformHttpRequest(url, function (status, body)
        if status ~= 200 or type(body) ~= 'string' then viaYoutubePublic(); return end

        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' then viaYoutubePublic(); return end

        local item = (data.items or {})[1]
        local videoId = item and item.id and item.id.videoId
        if not videoId then viaYoutubePublic(); return end

        cb({ url = 'https://www.youtube.com/watch?v=' .. videoId })
    end, 'GET', '', { ['Accept'] = 'application/json' })
end

local function SpPlaylistTracks(playlistId, offset, acc, cb)
    local cap = SP.PlaylistLimit or 250

    SpRequest('/playlists/' .. UrlEncode(playlistId) .. '/tracks', {
        limit = 50,
        offset = offset,
        fields = 'items(track(id,name,artists,album(images),external_ids)),next,total'
    }, function (data, err)
        if err then cb(acc, err); return end

        for _, item in ipairs(data.items or {}) do
            local song = SpSong(item.track)
            if song then acc[#acc + 1] = song end
            if #acc >= cap then break end
        end

        if data.next and #acc < cap then
            SpPlaylistTracks(playlistId, offset + 50, acc, cb)
        else
            cb(acc)
        end
    end)
end

-- Troca uma faixa pendente pelo resultado resolvido, sem atropelar edições do
-- usuário: só substitui o slot se ainda for o placeholder do mesmo spId.
local function SpPatchSong(playlistId, index, spId, song)
    local rows = exports.oxmysql:query_async(
        'SELECT songs FROM player_playlists WHERE id = ? LIMIT 1', { playlistId })
    if not rows or not rows[1] then return end

    local ok, songs = pcall(json.decode, rows[1].songs or '[]')
    if not ok or type(songs) ~= 'table' then return end

    local current = songs[index]
    if type(current) ~= 'table' or current.spId ~= spId then return end

    songs[index] = song
    local thumb = (songs[1] and SafeUrl(songs[1].thumb, Limits.MaxThumb)) or ''
    exports.oxmysql:update(
        'UPDATE player_playlists SET songs = ?, song_count = ?, thumb = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
        { json.encode(songs), #songs, thumb, playlistId }
    )
end

-- Cria a playlist de imediato com os metadados do Spotify (skeleton) e vai
-- substituindo cada linha pendente pela faixa resolvida em segundo plano.
-- A UI recebe `playlistTrack` por faixa e atualiza a linha ao vivo.
local function SpImportCreate(src, playlistId, reqId)
    local passport = PassportOf(src)
    if not passport then return end

    SpRequest('/playlists/' .. UrlEncode(playlistId), { fields = 'name' }, function (meta)
        local name = (meta and Trim(meta.name, Limits.MaxPlaylistName)) or 'Playlist do Spotify'

        SpPlaylistTracks(playlistId, 0, {}, function (tracks, err)
            if err or not tracks or #tracks == 0 then
                TriggerClientEvent('solis:cl:apiResult', src, reqId, { error = 'empty' })
                return
            end

            local count = exports.oxmysql:scalar_async(
                'SELECT COUNT(*) FROM player_playlists WHERE passport = ?', { passport })
            if (tonumber(count) or 0) >= Limits.MaxPlaylists then
                TriggerClientEvent('solis:cl:apiResult', src, reqId, { error = 'limit' })
                return
            end

            -- Skeleton: metadados reais ocupam as lacunas, mas url vazia + pending.
            local seed = {}
            for index, track in ipairs(tracks) do
                seed[index] = {
                    url = '',
                    title = track.title,
                    artist = track.artist,
                    thumb = track.thumb,
                    provider = 'spotify',
                    spId = track.spId,
                    pending = true
                }
            end

            local thumb = (seed[1] and seed[1].thumb) or ''
            local id = exports.oxmysql:insert_async(
                'INSERT INTO player_playlists (passport, name, songs, song_count, thumb) VALUES (?, ?, ?, ?, ?)',
                { passport, name, json.encode(seed), #seed, thumb }
            )

            if not id then
                TriggerClientEvent('solis:cl:apiResult', src, reqId, { error = 'db' })
                return
            end

            id = tonumber(id)
            BustPlaylist(passport)

            -- Resposta imediata com a playlist já existente: a UI abre o skeleton.
            TriggerClientEvent('solis:cl:playlists', src, FetchPlaylists(passport))
            TriggerClientEvent('solis:cl:apiResult', src, reqId, {
                kind = 'playlist',
                pending = true,
                playlistId = id,
                playlist = { id = id, name = name, count = #seed, thumb = thumb, isOwner = true },
                total = #seed
            })

            local function step(index)
                if index > #tracks then
                    TriggerClientEvent('solis:cl:playlists', src, FetchPlaylists(passport))
                    TriggerClientEvent('solis:cl:toast', src, 'success',
                        ('%d faixas importadas do Spotify.'):format(#tracks), 'Spotify')
                    return
                end

                local original = tracks[index]
                ResolvePlayable(original, function (playable)
                    local song = SpPlayable(original, playable)
                    if not song then
                        song = {
                            url = '', title = original.title, artist = original.artist,
                            thumb = original.thumb, provider = 'spotify',
                            spId = original.spId, pending = false, failed = true
                        }
                    end

                    SpPatchSong(id, index, original.spId, song)
                    TriggerClientEvent('solis:cl:playlistTrack', src, id, index, song)

                    local delay = SP.ResolveDelay or 0
                    if delay > 0 then
                        SetTimeout(delay, function () step(index + 1) end)
                    else
                        step(index + 1)
                    end
                end)
            end

            step(1)
        end)
    end)
end

RegisterNetEvent('solis:sv:spotifySearch', function (reqId, query)
    local src = source
    if not Allowed(src, false) then
        TriggerClientEvent('solis:cl:apiResult', src, reqId, { error = 'rate_limited' })
        return
    end

    SpSearch(query, function (songs, err)
        TriggerClientEvent('solis:cl:apiResult', src, reqId, { songs = songs, error = err })
    end)
end)

RegisterNetEvent('solis:sv:spotifyLink', function (reqId, input)
    local src = source
    if not Allowed(src, false) then
        TriggerClientEvent('solis:cl:apiResult', src, reqId, { error = 'rate_limited' })
        return
    end

    local kind, id = SpLink(input)
    if not kind then
        TriggerClientEvent('solis:cl:apiResult', src, reqId, { error = 'invalid_link' })
        return
    end

    if kind == 'playlist' then
        -- A playlist é criada na hora (skeleton) e respondida de imediato;
        -- as faixas são resolvidas e enviadas uma a uma depois.
        SpImportCreate(src, id, reqId)
        return
    end

    SpRequest('/tracks/' .. UrlEncode(id), { market = SP.Market or 'BR' }, function (track, err)
        local song = SpSong(track)
        if err or not song then
            TriggerClientEvent('solis:cl:apiResult', src, reqId, { error = err or 'not_found' })
            return
        end

        ResolvePlayable(song, function (playable)
            TriggerClientEvent('solis:cl:apiResult', src, reqId, {
                kind = 'track',
                song = SpPlayable(song, playable) or song
            })
        end)
    end)
end)

RegisterNetEvent('solis:sv:spotifyBatch', function (reqId, songs)
    local src = source
    if not Allowed(src, false) or type(songs) ~= 'table' then
        TriggerClientEvent('solis:cl:apiResult', src, reqId, { songs = {}, error = 'invalid' })
        return
    end

    local out = {}

    local function step(index)
        if index > #songs then
            TriggerClientEvent('solis:cl:apiResult', src, reqId, { songs = out })
            return
        end

        local song = songs[index]
        if type(song) ~= 'table' or song.provider ~= 'spotify' then
            out[#out + 1] = song
            step(index + 1)
            return
        end

        ResolvePlayable(song, function (playable)
            out[#out + 1] = SpPlayable(song, playable) or song
            step(index + 1)
        end)
    end

    step(1)
end)

local function Fanout(sess, event, ...)
    local sent = {}

    for src in pairs(sess.users) do
        sent[src] = true
        TriggerClientEvent(event, src, ...)
    end

    local watchers = Watchers[sess.id]
    if watchers then
        for src in pairs(watchers) do
            if not sent[src] then
                sent[src] = true
                TriggerClientEvent(event, src, ...)
            end
        end
    end
end

local function EndSession(sess)
    local sid = sess.id
    local audience = {}

    for src in pairs(sess.users) do audience[src] = true end
    for src in pairs(Watchers[sid] or {}) do audience[src] = true end

    Sessions[sid] = nil
    Watchers[sid] = nil

    for src in pairs(audience) do
        if ByUser[src] then ByUser[src][sid] = nil end
        if Interests[src] then Interests[src][sid] = nil end
        TriggerClientEvent('solis:cl:sessionEnded', src, sid)
    end

    for src in pairs(audience) do
        if ByUser[src] then PushSessions(src) end
    end
end

local function GetJamList(src)
    local list = {}
    for code, jam in pairs(Jams) do
        local member = jam.members[src]
        if member then
            local pb = GetJamPlayback(code)
            list[#list + 1] = {
                sessId = 'jam_' .. code,
                kind = 'jam',
                jamCode = code,
                netId = 0,
                plate = 'JAM',
                name = 'Jam de ' .. jam.hostName,
                title = pb.title,
                thumb = pb.thumb,
                url = pb.url,
                vol = pb.volume,
                playing = pb.playing,
                time = pb.time,
                queue = pb.queue,
                queueIndex = pb.queueIndex,
                focus = true,
                isHost = jam.host == src,
                canControl = jam.host == src or member.canControl == true or Config.Jam.AnyoneCanControl == true
            }
        end
    end
    return list
end

PushSessions = function(src)
    local list = {}

    for sessId in pairs(ByUser[src] or {}) do
        local sess = Sessions[sessId]
        if sess then list[#list + 1] = SessionInfo(sess, src) end
    end

    for _, jam in ipairs(GetJamList(src)) do
        list[#list + 1] = jam
    end

    TriggerClientEvent('solis:cl:sessions', src, list)
end

local function ApplyInterest(src, wanted)
    local current = Interests[src] or {}

    for sessId in pairs(current) do
        if not wanted[sessId] then
            local watchers = Watchers[sessId]
            if watchers then
                watchers[src] = nil
                if next(watchers) == nil then Watchers[sessId] = nil end
            end
        end
    end

    for sessId in pairs(wanted) do
        if not current[sessId] then
            Watchers[sessId] = Watchers[sessId] or {}
            Watchers[sessId][src] = true

            local sess = Sessions[sessId]
            if sess and sess.url and sess.playing then
                TriggerClientEvent('solis:cl:play', src, PlayEvent(sess))
            end
        end
    end

    Interests[src] = wanted
end

RegisterNetEvent('solis:sv:interest', function(vehicles, stages)
    local src = source
    if not Allowed(src) then return end

    local wanted = {}

    if type(vehicles) == 'table' then
        local n = 0
        for _, netId in ipairs(vehicles) do
            n = n + 1
            if n > Net.InterestMaxVehicles then break end
            local id = tonumber(netId)
            if id and id > 0 then
                local sessId = 'vehicle_' .. id
                if Sessions[sessId] then wanted[sessId] = true end
            end
        end
    end

    if type(stages) == 'table' then
        for _, stageId in ipairs(stages) do
            local sessId = 'stage_' .. tostring(stageId)
            if Sessions[sessId] then wanted[sessId] = true end
        end
    end

    ApplyInterest(src, wanted)
end)

-- ==========================================
-- CONTROLE DE SESSÃO
-- ==========================================
local function NearStage(src, stage)
    local coords = PedCoords(src)
    if not coords then return false end
    return #(coords - stage.coords) <= (stage.radius + 25.0)
end

-- Autorização de controle: quem abriu a sessão, quem está dentro dela ou, no
-- caso de palco, quem está fisicamente perto. A distância é conferida aqui,
-- não no cliente.
local function CanControl(src, sess)
    if sess.controller == src then return true end

    if sess.kind == 'stage' then
        local stage = Config.Stages[sess.stageId]
        return stage ~= nil and NearStage(src, stage)
    end

    return sess.users[src] == true
end

RegisterNetEvent('solis:sv:play', function(sessId, url, vol, time, title, thumb, queue, queueIndex)
    local src = source
    if not Allowed(src) then return end

    local sess = Sessions[sessId]
    if not sess then return end
    if not CanControl(src, sess) then return end

    url = SafeUrl(url)
    if not url then return end

    sess.url = url
    sess.title = Trim(title, Limits.MaxTitle) or 'Reproduzindo...'
    sess.thumb = SafeUrl(thumb, Limits.MaxThumb) or ''
    sess.vol = Clamp(tonumber(vol) or 0.5, 0.0, 1.0)
    sess.base = Clamp(tonumber(time) or 0.0, 0.0, 86400.0)
    sess.playing = true
    sess.controller = src

    if type(queue) == 'table' then
        sess.queue = TrimQueue(queue)
        sess.queueIndex = math.max(0, math.floor(tonumber(queueIndex) or 0))
    end

    Touch(sess)
    Fanout(sess, 'solis:cl:play', PlayEvent(sess))
end)

RegisterNetEvent('solis:sv:control', function(sessId, action, value)
    local src = source
    if not Allowed(src) then return end

    local sess = Sessions[sessId]
    if not sess or not CanControl(src, sess) then return end

    if action == 'pause' then
        sess.base = Elapsed(sess)
        sess.playing = false
        Touch(sess)
    elseif action == 'resume' then
        sess.playing = true
        Touch(sess)
    elseif action == 'seek' then
        sess.base = Clamp(tonumber(value) or 0.0, 0.0, 86400.0)
        Touch(sess)
    elseif action == 'volume' then
        sess.vol = Clamp(tonumber(value) or 0.5, 0.0, 1.0)
    elseif action == 'stop' then
        sess.playing = false
        sess.url = nil
        sess.base = 0
        Touch(sess)
    else
        return
    end

    -- Controle não pode depender de quem já foi registrado como watcher:
    -- o scan de interesse é periódico e atrasava pause/volume/seek em até 2 s.
    -- Broadcast direto (como no /som); clientes sem o som simplesmente ignoram.
    -- Cada ação leva seu próprio valor: seek precisa do tempo, não do volume.
    local broadcast = (action == 'seek') and Elapsed(sess) or sess.vol
    TriggerClientEvent('solis:cl:control', -1, sessId, action, broadcast)
end)

-- Fim de faixa: só quem controla pode avançar.
RegisterNetEvent('solis:sv:ended', function(sessId)
    local src = source
    if not Allowed(src) then return end

    local sess = Sessions[sessId]
    if not sess or sess.controller ~= src then return end

    sess.playing = false
    sess.base = Elapsed(sess)
    Touch(sess)
    Fanout(sess, 'solis:cl:control', sessId, 'pause', sess.vol)
end)

-- ==========================================
-- MONITOR DE VEÍCULOS
-- ==========================================
CreateThread(function()
    while true do
        Wait(5000)

        local dead = {}

        for sessId, sess in pairs(Sessions) do
            if sess.kind == 'vehicle' and sess.netId then
                local entity = NetworkGetEntityFromNetworkId(sess.netId)
                local exists = entity ~= 0 and DoesEntityExist(entity)

                if exists then
                    sess.misses = 0
                else
                    sess.misses = (sess.misses or 0) + 1
                    if sess.misses >= 3 then dead[#dead + 1] = sessId end
                end
            end
        end

        for _, sessId in ipairs(dead) do
            local sess = Sessions[sessId]
            if sess then EndSession(sess) end
        end
    end
end)

-- ==========================================
-- PARECAMENTO BLUETOOTH
-- ==========================================
local PairCache = {}

local function PairedOf(passport)
    local cached = PairCache[passport]
    if cached then return cached end

    local map = {}
    local rows = exports.oxmysql:query_async(
        'SELECT plate, device_name, auto_reconnect FROM player_bluetooth_paired WHERE passport = ? LIMIT 100',
        { passport }
    ) or {}

    for _, row in ipairs(rows) do
        map[row.plate] = {
            name = row.device_name,
            auto = (row.auto_reconnect == nil or tonumber(row.auto_reconnect) == 1)
        }
    end

    PairCache[passport] = map
    return map
end

local function SavePair(passport, plate, name)
    if not passport or not plate then return end

    local map = PairedOf(passport)
    if not map[plate] and #map >= Config.Bluetooth.PairLimit then return end

    map[plate] = { name = name, auto = true }

    exports.oxmysql:insert([[
        INSERT INTO player_bluetooth_paired (passport, plate, device_name, authorized, auto_reconnect)
        VALUES (?, ?, ?, 1, 1)
        ON DUPLICATE KEY UPDATE device_name = VALUES(device_name), authorized = 1
    ]], { passport, plate, name })
end

-- ==========================================
-- CONEXÃO A DISPOSITIVO
-- ==========================================
local function VehicleOwner(netId, plate)
    local passport, ownerName = nil, nil

    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity ~= 0 and DoesEntityExist(entity) then
        local state = Entity(entity).state
        if state then
            passport = state.Passport or state.passport
        end
    end

    if not passport then passport = PlateOwner(plate) end
    if passport then
        passport = Bridge.Normalize(passport)
        ownerName = NameOf(passport)
    end

    return passport, ownerName
end

function API.connect(device, handoff)
    local src = source
    if type(device) ~= 'table' then return { ok = false, message = 'Dispositivo inválido.' } end
    if not Allowed(src) then return { ok = false, message = 'Aguarde um instante.' } end

    local passport = PassportOf(src)
    if not passport then return { ok = false, message = 'Identidade inválida.' } end

    local kind = (device.kind == 'stage') and 'stage' or 'vehicle'
    local sessId, netId, stageId, plate

    if kind == 'stage' then
        stageId = type(device.stageId) == 'string' and device.stageId or nil
        local stage = stageId and Config.Stages[stageId] or nil
        if not stage then return { ok = false, message = 'Palco inexistente.' } end
        if not NearStage(src, stage) then return { ok = false, message = 'Você está longe do palco.' } end

        stageId = device.stageId
        plate = 'STAGE_' .. tostring(stageId)
        sessId = 'stage_' .. tostring(stageId)
    else
        netId = tonumber(device.netId)
        if not netId or netId <= 0 then return { ok = false, message = 'Veículo inválido.' } end

        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity == 0 or not DoesEntityExist(entity) then
            return { ok = false, message = 'Veículo fora de alcance.' }
        end

        local coords = PedCoords(src)
        if not coords or #(coords - GetEntityCoords(entity)) > 25.0 then
            return { ok = false, message = 'Veículo fora de alcance.' }
        end

        plate = Trim(device.plate, 24) or ''
        sessId = 'vehicle_' .. netId
    end

    local sess = Sessions[sessId]

    if not sess then
        local ownerPassport, ownerName = nil, nil
        local deviceName

        if kind == 'vehicle' then
            ownerPassport, ownerName = VehicleOwner(netId, plate)

            -- O nome do modelo vem do cliente (nativo de exibição é client-side).
            local label = Trim(device.name, 60) or 'Veículo'
            if ownerName then
                deviceName = string.format('%s de %s', label, ownerName)
            else
                deviceName = string.format('%s (%s)', label, plate ~= '' and plate or 'S/P')
            end
        else
            deviceName = 'Palco: ' .. Config.Stages[stageId].label
        end

        sess = {
            id = sessId,
            kind = kind,
            netId = netId,
            stageId = stageId,
            plate = plate,
            name = deviceName,
            ownerPassport = ownerPassport,
            ownerName = ownerName,
            users = {},
            url = nil,
            title = 'Nenhuma música tocando',
            thumb = '',
            vol = 0.5,
            playing = false,
            base = 0,
            queue = {},
            queueIndex = 0,
            misses = 0
        }

        Sessions[sessId] = sess
    end

    -- Handoff: a sessão passa a tocar o que estava nos fones deste jogador.
    if handoff and type(handoff) == 'table' and handoff.url then
        sess.url = SafeUrl(handoff.url) or sess.url
        sess.title = Trim(handoff.title, Limits.MaxTitle) or sess.title
        sess.thumb = SafeUrl(handoff.thumb, Limits.MaxThumb) or ''
        sess.vol = Clamp(tonumber(handoff.volume) or 0.5, 0.0, 1.0)
        sess.base = Clamp(tonumber(handoff.time) or 0.0, 0.0, 86400.0)
        sess.playing = handoff.playing ~= false
        sess.queue = TrimQueue(handoff.queue)
        sess.queueIndex = math.max(0, math.floor(tonumber(handoff.queueIndex) or 0))
        Touch(sess)
    end

    if not sess.users[src] then
        local maxUsers = (kind == 'stage') and Limits.MaxStageListeners or 2
        local count = 0
        for _ in pairs(sess.users) do count = count + 1 end

        if count >= maxUsers then
            return { ok = false, message = 'Dispositivo ocupado no momento.' }
        end

        if SessionCount(src) >= Limits.MaxSessions then
            return { ok = false, message = ('Limite de %d sessões simultâneas atingido.'):format(Limits.MaxSessions) }
        end
    end

    local isOwner = kind == 'stage' or (sess.ownerPassport and sess.ownerPassport == passport) or not sess.ownerPassport

    if not sess.users[src] and not isOwner then
        local paired = PairedOf(passport)
        local isDriver = device.driver == true

        if not isDriver and not paired[plate] then
            return API.requestAccess(src, sess, passport)
        end
    end

    sess.users[src] = true
    ByUser[src] = ByUser[src] or {}
    ByUser[src][sessId] = true

    if device.driver == true or sess.controller == nil then
        sess.controller = src
    end

    if kind == 'vehicle' then
        SavePair(passport, plate, sess.name)
    end

    if sess.url and sess.playing then
        TriggerClientEvent('solis:cl:play', src, PlayEvent(sess))
    end

    PushSessions(src)

    return { ok = true, session = SessionInfo(sess, src) }
end

function API.requestAccess(src, sess, passport)
    local ownerSource = sess.ownerPassport and Bridge.GetSource(sess.ownerPassport) or nil
    if not ownerSource then
        return { ok = false, message = 'O dono do veículo não está na cidade.' }
    end

    RequestId = RequestId + 1
    local id = RequestId

    Pending[id] = {
        kind = 'bluetooth',
        requester = src,
        requesterPassport = passport,
        requesterName = NameOf(passport),
        owner = ownerSource,
        sessId = sess.id,
        plate = sess.plate,
        device = sess.name
    }

    TriggerClientEvent('solis:cl:prompt', ownerSource, {
        id = id,
        text = ('%s deseja parear (%s)'):format(NameOf(passport), sess.name)
    })

    return { ok = 'pending', message = 'Solicitação enviada ao proprietário...' }
end

RegisterNetEvent('solis:sv:answer', function(id, accepted)
    local src = source
    if not Allowed(src) then return end

    local request = Pending[id]
    if not request or request.owner ~= src then return end
    Pending[id] = nil

    local target = request.requester

    if request.kind == 'bluetooth' then
        if not accepted then
            TriggerClientEvent('solis:cl:denied', target)
            return
        end

        local sess = Sessions[request.sessId]
        if not sess then
            TriggerClientEvent('solis:cl:denied', target)
            return
        end

        sess.users[target] = true
        ByUser[target] = ByUser[target] or {}
        ByUser[target][request.sessId] = true

        SavePair(request.requesterPassport, request.plate, request.device)

        TriggerClientEvent('solis:cl:granted', target, SessionInfo(sess, target))
        PushSessions(target)
        return
    end

    if request.kind == 'airdrop' then
        if accepted then
            exports.oxmysql:insert(
                'INSERT INTO player_playlists (passport, name, songs, song_count) VALUES (?, ?, ?, ?)',
                { request.targetPassport, request.name, request.songs, request.songCount },
                function()
                    BustPlaylist(request.targetPassport)
                    TriggerClientEvent('solis:cl:playlists', request.owner, FetchPlaylists(request.targetPassport))
                    TriggerClientEvent('solis:cl:toast', request.owner, 'success', 'Playlist recebida via AirDrop!', 'AirDrop')
                    TriggerClientEvent('solis:cl:toast', request.requester, 'success', request.targetName .. ' aceitou a playlist.', 'AirDrop')
                end
            )
        else
            TriggerClientEvent('solis:cl:toast', request.requester, 'error', request.targetName .. ' recusou a playlist.', 'AirDrop')
        end
        return
    end

    if request.kind == 'collab' then
        if accepted then
            exports.oxmysql:insert(
                'INSERT IGNORE INTO player_playlist_members (playlist_id, passport) VALUES (?, ?)',
                { request.playlistId, request.targetPassport },
                function()
                    SyncCollaborators(request.playlistId)
                    BustPlaylist(request.targetPassport)
                    BustPlaylist(request.requesterPassport)
                    TriggerClientEvent('solis:cl:playlists', request.owner, FetchPlaylists(request.targetPassport))
                    TriggerClientEvent('solis:cl:toast', request.requester, 'success', request.targetName .. ' agora colabora na playlist!', 'Playlists')
                end
            )
        else
            TriggerClientEvent('solis:cl:toast', request.requester, 'error', request.targetName .. ' recusou o convite.', 'Playlists')
        end
    end
end)

-- ==========================================
-- DESCOBERTA (BLUETOOTH)
-- ==========================================
function API.scan(nearby)
    local src = source
    local passport = PassportOf(src)
    if not passport or type(nearby) ~= 'table' then return { paired = {}, others = {} } end

    local paired = PairedOf(passport)
    local pairedList, othersList = {}, {}

    for _, veh in ipairs(nearby.vehicles or {}) do
        local netId = tonumber(veh.netId)
        if netId and netId > 0 then
            local plate = veh.plate or ''
            local sess = Sessions['vehicle_' .. netId]

            local connections, isConnected = 0, false
            if sess then
                for member in pairs(sess.users) do
                    connections = connections + 1
                    if member == src then isConnected = true end
                end
            end

            local ownerPassport, ownerName = VehicleOwner(netId, plate)
            local isOwner = ownerPassport ~= nil and ownerPassport == passport
            local deviceName = veh.name or 'Veículo'

            if ownerName then
                deviceName = string.format('%s de %s', veh.name or 'Veículo', ownerName)
            elseif plate ~= '' then
                deviceName = string.format('%s (%s)', veh.name or 'Veículo', plate)
            end

            local entry = {
                kind = 'vehicle',
                netId = netId,
                plate = plate,
                name = deviceName,
                isOwner = isOwner,
                isConnected = isConnected,
                playing = sess ~= nil and sess.playing == true,
                track = sess and sess.title or '',
                auto = paired[plate] ~= nil and paired[plate].auto or false,
                connections = connections,
                maxConnections = 2
            }

            if paired[plate] or isOwner then
                pairedList[#pairedList + 1] = entry
            else
                othersList[#othersList + 1] = entry
            end
        end
    end

    for _, stage in ipairs(nearby.stages or {}) do
        local stageId = stage.id
        local sess = Sessions['stage_' .. tostring(stageId)]
        local isConnected = sess ~= nil and sess.users[src] == true

        local connections = 0
        if sess then
            for _ in pairs(sess.users) do connections = connections + 1 end
        end

        othersList[#othersList + 1] = {
            kind = 'stage',
            stageId = stageId,
            plate = 'STAGE_' .. tostring(stageId),
            name = 'Palco: ' .. stage.name,
            isOwner = false,
            isConnected = isConnected,
            playing = sess ~= nil and sess.playing == true,
            track = sess and sess.title or '',
            auto = false,
            connections = connections,
            maxConnections = Limits.MaxStageListeners
        }
    end

    return { paired = pairedList, others = othersList }
end

-- ==========================================
-- SESSÕES DO JOGADOR
-- ==========================================
function API.sessions()
    local src = source
    local list = {}

    for sessId in pairs(ByUser[src] or {}) do
        local sess = Sessions[sessId]
        if sess then list[#list + 1] = SessionInfo(sess, src) end
    end

    for _, jam in ipairs(GetJamList(src)) do
        list[#list + 1] = jam
    end

    return list
end

function API.leave(sessId)
    local src = source
    local sess = Sessions[sessId]
    if not sess or not sess.users[src] then return false end

    sess.users[src] = nil
    if ByUser[src] then ByUser[src][sessId] = nil end

    local remaining = 0
    for member, _ in pairs(sess.users) do
        remaining = remaining + 1
        if sess.controller == src then sess.controller = member end
    end

    if remaining == 0 then
        EndSession(sess)
    else
        TriggerClientEvent('solis:cl:sessionLeft', src, sessId)
        PushSessions(src)
    end

    return true
end

function API.autoReconnect(plate, state)
    local src = source
    local passport = PassportOf(src)
    if not passport or type(plate) ~= 'string' or plate == '' then return false end
    if not Allowed(src, true) then return false end

    local value = state and 1 or 0
    local paired = PairedOf(passport)
    if paired[plate] then paired[plate].auto = state == true end

    exports.oxmysql:update(
        'UPDATE player_bluetooth_paired SET auto_reconnect = ? WHERE passport = ? AND plate = ?',
        { value, passport, plate }
    )
    return true
end

function API.forget(plate)
    local src = source
    local passport = PassportOf(src)
    if not passport or type(plate) ~= 'string' or plate == '' then return false end
    if not Allowed(src, true) then return false end

    local paired = PairedOf(passport)
    paired[plate] = nil

    exports.oxmysql:query(
        'DELETE FROM player_bluetooth_paired WHERE passport = ? AND plate = ?',
        { passport, plate }
    )
    return true
end

function API.nearbyPlayers()
    local src = source
    if not Allowed(src) then return {} end

    local coords = PedCoords(src)
    if not coords then return {} end

    local list = {}

    for _, target in ipairs(GetPlayers()) do
        target = tonumber(target)
        if target and target ~= src then
            local targetPed = GetPlayerPed(target)
            if targetPed ~= 0 and DoesEntityExist(targetPed) then
                if #(coords - GetEntityCoords(targetPed)) <= 10.0 then
                    local passport = PassportOf(target)
                    if passport then
                        list[#list + 1] = { source = target, passport = passport, name = NameOf(passport) }
                    end
                end
            end
        end
    end

    return list
end

-- ==========================================
-- JAM
-- ==========================================
local function CleanJamCode(code)
    if type(code) ~= 'string' then return '' end
    code = code:gsub('spotifive://jam/', ''):gsub('%s+', ''):upper()
    if not code:find('^JAM%-') and #code == 4 then code = 'JAM-' .. code end
    return code
end

local function NewJamCode()
    local alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    for _ = 1, 12 do
        local code = 'JAM-'
        for _ = 1, 4 do
            local i = math.random(1, #alphabet)
            code = code .. alphabet:sub(i, i)
        end
        if not Jams[code] then return code end
    end
    return 'JAM-' .. tostring(math.random(1000, 9999))
end

local function JamMembers(jam)
    local list = {}
    for member, data in pairs(jam.members) do
        list[#list + 1] = {
            source = member,
            passport = data.passport,
            name = data.name,
            isHost = member == jam.host,
            canControl = member == jam.host or data.canControl == true or Config.Jam.AnyoneCanControl == true,
            mode = data.mode
        }
    end
    return list
end

GetJamPlayback = function(code)
    local jam = Jams[code]
    if not jam then
        return { url = nil, title = 'Nenhuma música tocando', thumb = '', volume = 0.5, playing = false, time = 0, queue = {}, queueIndex = 0 }
    end

    local pb = jam.playback
    local time = pb.time or 0

    if pb.playing and pb.startedAt then
        time = time + math.max(0, os.time() - pb.startedAt)
    end

    return {
        url = pb.url,
        title = pb.title or 'Nenhuma música tocando',
        thumb = pb.thumb or '',
        volume = pb.volume or 0.5,
        playing = pb.playing == true,
        time = time,
        queue = pb.queue or {},
        queueIndex = pb.queueIndex or 0
    }
end

local function BroadcastJam(code, event, ...)
    local jam = Jams[code]
    if not jam then return end
    for member in pairs(jam.members) do
        TriggerClientEvent(event, member, ...)
    end
end

function API.jamCreate(playback)
    local src = source
    if not Allowed(src) then return { ok = false, message = 'Aguarde um instante.' } end

    local passport = PassportOf(src)
    if not passport then return { ok = false, message = 'Identidade inválida.' } end

    for _, jam in pairs(Jams) do
        if jam.host == src then return { ok = false, message = 'Você já está em uma Jam.' } end
    end

    local code = NewJamCode()
    local payload = type(playback) == 'table' and playback or {}

    Jams[code] = {
        code = code,
        host = src,
        hostPassport = passport,
        hostName = NameOf(passport),
        members = {
            [src] = { passport = passport, name = NameOf(passport), mode = 'host', canControl = true }
        },
        playback = {
            url = SafeUrl(payload.url),
            title = Trim(payload.title, Limits.MaxTitle) or 'Nenhuma música tocando',
            thumb = SafeUrl(payload.thumb, Limits.MaxThumb) or '',
            volume = Clamp(tonumber(payload.volume) or 0.5, 0.0, 1.0),
            playing = payload.playing == true,
            time = Clamp(tonumber(payload.time) or 0.0, 0.0, 86400.0),
            queue = TrimQueue(payload.queue),
            queueIndex = math.max(0, math.floor(tonumber(payload.queueIndex) or 0)),
            startedAt = payload.playing == true and os.time() or nil
        }
    }

    PushSessions(src)
    return { ok = true, jam = { code = code, hostName = Jams[code].hostName, isHost = true, members = JamMembers(Jams[code]) } }
end

function API.jamJoin(code, mode)
    local src = source
    if not Allowed(src) then return { ok = false, message = 'Aguarde um instante.' } end

    local passport = PassportOf(src)
    if not passport then return { ok = false, message = 'Identidade inválida.' } end

    code = CleanJamCode(code)
    local jam = Jams[code]
    if not jam then return { ok = false, message = 'Jam não encontrada ou já encerrada.' } end

    local count = 0
    for _ in pairs(jam.members) do count = count + 1 end
    if not jam.members[src] and count >= Config.Jam.MaxMembers then
        return { ok = false, message = 'Jam cheia.' }
    end

    jam.members[src] = {
        passport = passport,
        name = NameOf(passport),
        mode = mode or 'host',
        -- Quem entra começa como ouvinte; o anfitrião libera pelo jamAllow.
        canControl = Config.Jam.AnyoneCanControl == true
    }

    BroadcastJam(code, 'solis:cl:jamMembers', JamMembers(jam))
    BroadcastJam(code, 'solis:cl:jamEvent', ('%s entrou na Jam.'):format(NameOf(passport)))
    PushSessions(src)

    return {
        ok = true,
        jam = {
            code = code,
            hostName = jam.hostName,
            isHost = jam.host == src,
            canControl = jam.host == src
                or (jam.members[src] and jam.members[src].canControl == true)
                or Config.Jam.AnyoneCanControl == true,
            playback = GetJamPlayback(code),
            members = JamMembers(jam)
        }
    }
end

function API.jamLeave(code)
    local src = source
    code = CleanJamCode(code)

    local jam = Jams[code]
    if not jam or not jam.members[src] then return false end

    if jam.host == src then return API.jamEnd(code) end

    local name = jam.members[src].name
    jam.members[src] = nil

    BroadcastJam(code, 'solis:cl:jamMembers', JamMembers(jam))
    BroadcastJam(code, 'solis:cl:jamEvent', ('%s saiu da Jam.'):format(name))
    PushSessions(src)

    return true
end

function API.jamEnd(code)
    local src = source
    code = CleanJamCode(code)

    local jam = Jams[code]
    if not jam or jam.host ~= src then return false end

    Jams[code] = nil

    for member in pairs(jam.members) do
        TriggerClientEvent('solis:cl:jamEnded', member)
        PushSessions(member)
    end

    return true
end

function API.jamMembers(code)
    local jam = Jams[CleanJamCode(code)]
    if not jam then return {} end
    return JamMembers(jam)
end

function API.jamKick(code, passport)
    local src = source
    code = CleanJamCode(code)
    passport = Bridge.Normalize(passport)

    local jam = Jams[code]
    if not jam or jam.host ~= src or not passport then return { ok = false } end

    for member, data in pairs(jam.members) do
        if Bridge.Same(data.passport, passport) and member ~= src then
            jam.members[member] = nil
            TriggerClientEvent('solis:cl:jamEnded', member)
            PushSessions(member)
            BroadcastJam(code, 'solis:cl:jamMembers', JamMembers(jam))
            BroadcastJam(code, 'solis:cl:jamEvent', ('%s foi removido da Jam.'):format(data.name))
            return { ok = true }
        end
    end

    return { ok = false }
end

-- O anfitrião define quem, além dele, pode trocar faixa, pausar e mexer na fila.
function API.jamAllow(code, passport, allowed)
    local src = source
    code = CleanJamCode(code)
    passport = Bridge.Normalize(passport)

    local jam = Jams[code]
    if not jam or jam.host ~= src or not passport then return { ok = false } end

    for member, data in pairs(jam.members) do
        if member ~= src and Bridge.Same(data.passport, passport) then
            data.canControl = allowed == true

            BroadcastJam(code, 'solis:cl:jamMembers', JamMembers(jam))
            BroadcastJam(code, 'solis:cl:jamEvent', ('%s agora %s controlar a Jam.'):format(
                data.name, data.canControl and 'pode' or 'não pode'
            ))

            return { ok = true, canControl = data.canControl }
        end
    end

    return { ok = false }
end

function API.jamAction(code, action, data)
    local src = source
    if not Allowed(src) then return false end

    code = CleanJamCode(code)
    local jam = Jams[code]
    local member = jam and jam.members[src]
    if not member then return false end

    -- Anfitrião sempre pode; os demais só depois que ele liberar (jamAllow).
    if jam.host ~= src and not member.canControl and not Config.Jam.AnyoneCanControl then return false end

    local pb = jam.playback

    if action == 'play' and type(data) == 'table' then
        pb.url = SafeUrl(data.url)
        pb.title = Trim(data.title, Limits.MaxTitle) or pb.title
        pb.thumb = SafeUrl(data.thumb, Limits.MaxThumb) or ''
        pb.playing = true
        pb.time = Clamp(tonumber(data.time) or 0.0, 0.0, 86400.0)
        pb.startedAt = os.time()
        if type(data.queue) == 'table' then
            pb.queue = TrimQueue(data.queue)
            pb.queueIndex = math.max(0, math.floor(tonumber(data.queueIndex) or 0))
        end
    elseif action == 'pause' then
        pb.time = GetJamPlayback(code).time
        pb.playing = false
        pb.startedAt = nil
    elseif action == 'resume' then
        pb.playing = true
        pb.startedAt = os.time()
    elseif action == 'seek' then
        pb.time = Clamp(tonumber(data and data.time) or 0.0, 0.0, 86400.0)
        pb.startedAt = pb.playing and os.time() or nil
    else
        return false
    end

    local payload = GetJamPlayback(code)
    local mode = jam.members[src].mode

    for member in pairs(jam.members) do
        TriggerClientEvent('solis:cl:jamApply', member, action, payload, mode, src)
    end

    return true
end

-- Ações de Jam vindas do NUI (sem retorno síncrono).
RegisterNetEvent('solis:sv:jam', function(code, action, data)
    API.jamAction(code, action, data)
end)

RegisterNetEvent('solis:sv:jamLeave', function(code)
    API.jamLeave(code)
end)

-- ==========================================
-- PLAYLISTS
-- ==========================================
local PlaylistCache = {}   -- [passport] = { list, at }

BustPlaylist = function(passport)
    for _, key in ipairs({ passport, tostring(passport) }) do
        PlaylistCache[key] = nil
    end
end

local function PlaylistMeta(rows)
    local list = {}

    for _, row in ipairs(rows or {}) do
        list[#list + 1] = {
            id = row.id,
            name = row.name,
            count = tonumber(row.song_count) or 0,
            thumb = row.thumb or '',
            isOwner = (tonumber(row.is_owner) == 1) or row.is_owner == true
        }
    end

    return list
end

FetchPlaylists = function(passport)
    local rows = exports.oxmysql:query_async([[
        SELECT p.id, p.name, p.song_count, p.thumb, (p.passport = ?) AS is_owner
        FROM player_playlists p
        LEFT JOIN player_playlist_members m ON m.playlist_id = p.id AND m.passport = ?
        WHERE p.passport = ? OR m.passport IS NOT NULL
        ORDER BY p.updated_at DESC, p.id DESC
        LIMIT ?
    ]], { passport, passport, passport, Limits.MaxPlaylists }) or {}

    return PlaylistMeta(rows)
end

function API.playlists()
    local src = source
    local passport = PassportOf(src)
    if not passport then return {} end

    local cached = PlaylistCache[passport]
    if cached and (os.time() - cached.at) < 30 then return cached.list end

    local list = FetchPlaylists(passport)
    PlaylistCache[passport] = { list = list, at = os.time() }
    return list
end

local function PlaylistRow(passport, id, needOwner)
    id = tonumber(id)
    if not id then return nil, 'Playlist inválida.' end

    local row = exports.oxmysql:query_async(
        'SELECT id, passport, name, songs, song_count, thumb FROM player_playlists WHERE id = ? LIMIT 1',
        { id }
    )

    if not row or not row[1] then return nil, 'Playlist não encontrada.' end
    row = row[1]

    local isOwner = Bridge.Same(row.passport, passport)
    if needOwner and not isOwner then return nil, 'Apenas o criador pode fazer isso.' end
    if not isOwner then
        local member = exports.oxmysql:scalar_async(
            'SELECT passport FROM player_playlist_members WHERE playlist_id = ? AND passport = ? LIMIT 1',
            { id, passport }
        )
        if not member then return nil, 'Você não tem acesso a esta playlist.' end
    end

    return row, nil, isOwner
end

-- Coluna `collaborators` é legado; a tabela de membros é a fonte da verdade.
SyncCollaborators = function(playlistId)
    exports.oxmysql:query(
        'SELECT passport FROM player_playlist_members WHERE playlist_id = ?',
        { playlistId },
        function(rows)
            local list = {}
            for _, row in ipairs(rows or {}) do list[#list + 1] = tostring(row.passport) end
            exports.oxmysql:update('UPDATE player_playlists SET collaborators = ? WHERE id = ?', {
                json.encode(list), playlistId
            })
        end
    )
end

local function DecodeSongs(row)
    local songs = json.decode(row.songs or '[]')
    if type(songs) ~= 'table' then songs = {} end
    return songs
end

local function SaveSongs(id, songs)
    local thumb = (songs[1] and SafeUrl(songs[1].thumb, Limits.MaxThumb)) or ''
    exports.oxmysql:update(
        'UPDATE player_playlists SET songs = ?, song_count = ?, thumb = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
        { json.encode(songs), #songs, thumb, id }
    )
end

function API.playlistSongs(id, offset)
    local src = source
    local passport = PassportOf(src)
    if not passport then return { songs = {}, total = 0 } end

    local row, err = PlaylistRow(passport, id, false)
    if not row then return { songs = {}, total = 0, error = err } end

    local songs = DecodeSongs(row)
    offset = math.max(0, math.floor(tonumber(offset) or 0))

    local page = {}
    for index = offset + 1, math.min(#songs, offset + 100) do
        page[#page + 1] = songs[index]
    end

    return { songs = page, total = #songs, offset = offset, isOwner = Bridge.Same(row.passport, passport) }
end

function API.playlistQueue(id, from)
    local src = source
    local passport = PassportOf(src)
    if not passport then return {} end

    local row = PlaylistRow(passport, id, false)
    if not row then return {} end

    local songs = DecodeSongs(row)
    local out = {}

    -- a fila começa na faixa clicada: playlists grandes não podem tocar a faixa errada
    from = math.max(0, math.floor(tonumber(from) or 0))
    if from >= #songs then from = 0 end

    for index = from + 1, math.min(#songs, from + Limits.MaxQueue) do
        local song = SongPayload(songs[index])
        if song then out[#out + 1] = song end
    end

    return out
end

RegisterNetEvent('solis:sv:playlistCreate', function(name, songs)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    name = Trim(name, Limits.MaxPlaylistName)
    if not name then return end

    local seed = {}
    if type(songs) == 'table' then
        for _, song in ipairs(songs) do
            if #seed >= Limits.MaxSongsPerPlaylist then break end
            local payload = SongPayload(song)
            if payload then seed[#seed + 1] = payload end
        end
    end

    exports.oxmysql:scalar('SELECT COUNT(*) FROM player_playlists WHERE passport = ?', { passport }, function(count)
        if (tonumber(count) or 0) >= Limits.MaxPlaylists then
            TriggerClientEvent('solis:cl:toast', src, 'warning', 'Limite de playlists atingido.', 'Playlists')
            return
        end

        local thumb = (seed[1] and seed[1].thumb) or ''

        exports.oxmysql:insert(
            'INSERT INTO player_playlists (passport, name, songs, song_count, thumb) VALUES (?, ?, ?, ?, ?)',
            { passport, name, json.encode(seed), #seed, thumb },
            function()
                BustPlaylist(passport)
                TriggerClientEvent('solis:cl:playlists', src, FetchPlaylists(passport))
                TriggerClientEvent('solis:cl:toast', src, 'success',
                    #seed > 0 and (#seed .. ' faixas importadas.') or 'Playlist criada.', 'Playlists')
            end
        )
    end)
end)

RegisterNetEvent('solis:sv:playlistDelete', function(id)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    local row, err, isOwner = PlaylistRow(passport, id, false)
    if not row then
        TriggerClientEvent('solis:cl:toast', src, 'error', err, 'Playlists')
        return
    end

    if isOwner then
        exports.oxmysql:query('DELETE FROM player_playlists WHERE id = ?', { row.id })
        exports.oxmysql:query('DELETE FROM player_playlist_members WHERE playlist_id = ?', { row.id })
    else
        exports.oxmysql:query(
            'DELETE FROM player_playlist_members WHERE playlist_id = ? AND passport = ?',
            { row.id, passport },
            function() SyncCollaborators(row.id) end
        )
    end

    BustPlaylist(passport)
    TriggerClientEvent('solis:cl:playlists', src, FetchPlaylists(passport))
    TriggerClientEvent('solis:cl:toast', src, 'warning', isOwner and 'Playlist excluída.' or 'Você deixou de colaborar.', 'Playlists')
end)

RegisterNetEvent('solis:sv:playlistAdd', function(id, song)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    local payload = SongPayload(song)
    if not payload then return end

    local row, err = PlaylistRow(passport, id, false)
    if not row then
        TriggerClientEvent('solis:cl:toast', src, 'error', err, 'Playlists')
        return
    end

    local songs = DecodeSongs(row)
    if #songs >= Limits.MaxSongsPerPlaylist then
        TriggerClientEvent('solis:cl:toast', src, 'warning', 'Playlist cheia.', 'Playlists')
        return
    end

    songs[#songs + 1] = payload
    SaveSongs(row.id, songs)

    BustPlaylist(passport)
    TriggerClientEvent('solis:cl:playlists', src, FetchPlaylists(passport))
    TriggerClientEvent('solis:cl:toast', src, 'success', 'Música adicionada.', 'Playlists')
end)

RegisterNetEvent('solis:sv:playlistMove', function(id, from, to)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    from, to = tonumber(from), tonumber(to)
    if not from or not to then return end

    local row = PlaylistRow(passport, id, false)
    if not row then return end

    local songs = DecodeSongs(row)
    from, to = math.floor(from), math.floor(to)
    if from < 1 or from > #songs or to < 1 or to > #songs or from == to then return end

    local moved = table.remove(songs, from)
    table.insert(songs, to, moved)
    SaveSongs(row.id, songs)

    -- a capa da playlist é a primeira faixa: reordenar pode trocá-la
    BustPlaylist(passport)
    TriggerClientEvent('solis:cl:playlists', src, FetchPlaylists(passport))
end)

RegisterNetEvent('solis:sv:playlistRemove', function(id, index)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    index = math.floor(tonumber(index) or 0)
    if index < 1 then return end

    local row = PlaylistRow(passport, id, false)
    if not row then return end

    local songs = DecodeSongs(row)
    if not songs[index] then return end

    table.remove(songs, index)
    SaveSongs(row.id, songs)

    BustPlaylist(passport)
    TriggerClientEvent('solis:cl:playlists', src, FetchPlaylists(passport))
end)

RegisterNetEvent('solis:sv:playlistAirdrop', function(id, targetPassport)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    targetPassport = Bridge.Normalize(targetPassport)
    local row = PlaylistRow(passport, id, false)
    if not row or not targetPassport then return end

    local targetSource = Bridge.GetSource(targetPassport)
    if not targetSource then
        TriggerClientEvent('solis:cl:toast', src, 'error', 'Jogador não encontrado.', 'AirDrop')
        return
    end

    local songs = DecodeSongs(row)

    RequestId = RequestId + 1
    Pending[RequestId] = {
        kind = 'airdrop',
        owner = targetSource,
        requester = src,
        targetPassport = targetPassport,
        targetName = NameOf(targetPassport),
        name = row.name,
        songs = json.encode(songs),
        songCount = #songs
    }

    TriggerClientEvent('solis:cl:prompt', targetSource, {
        id = RequestId,
        text = ('%s quer enviar a playlist "%s"'):format(NameOf(passport), row.name)
    })

    TriggerClientEvent('solis:cl:toast', src, 'info', 'Solicitação de AirDrop enviada.', 'AirDrop')
end)

RegisterNetEvent('solis:sv:playlistInvite', function(id, targetPassport)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    targetPassport = Bridge.Normalize(targetPassport)
    local row, _, isOwner = PlaylistRow(passport, id, true)
    if not row or not targetPassport then
        TriggerClientEvent('solis:cl:toast', src, 'error', 'Apenas o criador pode convidar.', 'Playlists')
        return
    end

    local targetSource = Bridge.GetSource(targetPassport)
    if not targetSource then
        TriggerClientEvent('solis:cl:toast', src, 'error', 'Passaporte não encontrado online.', 'Playlists')
        return
    end

    RequestId = RequestId + 1
    Pending[RequestId] = {
        kind = 'collab',
        owner = targetSource,
        requester = src,
        requesterPassport = passport,
        targetPassport = targetPassport,
        targetName = NameOf(targetPassport),
        playlistId = row.id
    }

    TriggerClientEvent('solis:cl:prompt', targetSource, {
        id = RequestId,
        text = ('%s convidou você para colaborar em "%s"'):format(NameOf(passport), row.name)
    })

    TriggerClientEvent('solis:cl:toast', src, 'info', 'Convite enviado.', 'Playlists')
end)

RegisterNetEvent('solis:sv:jamInvite', function(code, targetPassport)
    local src = source
    local passport = PassportOf(src)
    if not passport or not Allowed(src, true) then return end

    code = CleanJamCode(code)
    if not Jams[code] then return end

    local targetSource = Bridge.GetSource(targetPassport)
    if not targetSource then
        TriggerClientEvent('solis:cl:toast', src, 'error', 'Jogador não encontrado.', 'Jam')
        return
    end

    TriggerClientEvent('solis:cl:jamInvite', targetSource, {
        code = code,
        hostName = NameOf(passport)
    })

    TriggerClientEvent('solis:cl:toast', src, 'success', 'Convite enviado.', 'Jam')
end)

-- ==========================================
-- RECENTES
-- ==========================================
function API.recent()
    local src = source
    local passport = PassportOf(src)
    if not passport then return {} end

    return exports.oxmysql:query_async(
        'SELECT url, title, thumb FROM player_spotify_recent WHERE passport = ? ORDER BY timestamp DESC LIMIT 12',
        { passport }
    ) or {}
end

RegisterNetEvent('solis:sv:recent', function(song)
    local src = source
    local passport = PassportOf(src)
    if not passport then return end

    song = SongPayload(song)
    if not song then return end

    exports.oxmysql:update([[
        INSERT INTO player_spotify_recent (passport, url, title, thumb, timestamp)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON DUPLICATE KEY UPDATE timestamp = CURRENT_TIMESTAMP, title = VALUES(title), thumb = VALUES(thumb)
    ]], { passport, song.url, song.title, song.thumb })
end)

-- ==========================================
-- LIMPEZA
-- ==========================================
AddEventHandler('playerDropped', function()
    local src = source

    for sessId, sess in pairs(Sessions) do
        if sess.users[src] then
            sess.users[src] = nil

            local remaining = 0
            for member in pairs(sess.users) do
                remaining = remaining + 1
                if sess.controller == src then sess.controller = member end
            end

            if remaining == 0 then
                EndSession(sess)
            else
                for member in pairs(sess.users) do PushSessions(member) end
            end
        end
    end

    for code, jam in pairs(Jams) do
        if jam.host == src then
            Jams[code] = nil
            for member in pairs(jam.members) do
                TriggerClientEvent('solis:cl:jamEnded', member)
                PushSessions(member)
            end
        elseif jam.members[src] then
            jam.members[src] = nil
            BroadcastJam(code, 'solis:cl:jamMembers', JamMembers(jam))
        end
    end

    for id, request in pairs(Pending) do
        if request.owner == src or request.requester == src then Pending[id] = nil end
    end

    for sessId in pairs(Interests[src] or {}) do
        local watchers = Watchers[sessId]
        if watchers then
            watchers[src] = nil
            if next(watchers) == nil then Watchers[sessId] = nil end
        end
    end

    Interests[src] = nil
    ByUser[src] = nil
    Players[src] = nil
    Buckets[src] = nil
end)

-- ==========================================
-- BANCO & MIGRAÇÕES
-- ==========================================
local function HasColumn(tableName, columnName, cb)
    exports.oxmysql:query([[
        SELECT COUNT(*) AS n FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?
    ]], { tableName, columnName }, function(rows)
        cb(rows and rows[1] and tonumber(rows[1].n) > 0)
    end)
end

CreateThread(function()
    Wait(1000)

    exports.oxmysql:query([[
        CREATE TABLE IF NOT EXISTS player_playlists (
            id INT NOT NULL AUTO_INCREMENT,
            passport VARCHAR(64) NOT NULL,
            name VARCHAR(100) NOT NULL,
            songs LONGTEXT NOT NULL,
            collaborators LONGTEXT NOT NULL DEFAULT '[]',
            song_count INT NOT NULL DEFAULT 0,
            thumb VARCHAR(512) NOT NULL DEFAULT '',
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            KEY idx_passport (passport)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    exports.oxmysql:query([[
        CREATE TABLE IF NOT EXISTS player_playlist_members (
            playlist_id INT NOT NULL,
            passport VARCHAR(64) NOT NULL,
            PRIMARY KEY (playlist_id, passport),
            KEY idx_passport (passport)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    exports.oxmysql:query([[
        CREATE TABLE IF NOT EXISTS player_spotify_recent (
            id INT NOT NULL AUTO_INCREMENT,
            passport VARCHAR(64) NOT NULL,
            url VARCHAR(255) NOT NULL,
            title VARCHAR(255) NOT NULL,
            thumb VARCHAR(512) NOT NULL,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            UNIQUE KEY unique_song (passport, url),
            KEY idx_recent (passport, timestamp)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    exports.oxmysql:query([[
        CREATE TABLE IF NOT EXISTS player_bluetooth_paired (
            id INT NOT NULL AUTO_INCREMENT,
            passport VARCHAR(64) NOT NULL,
            plate VARCHAR(20) NOT NULL,
            device_name VARCHAR(100) NOT NULL,
            authorized TINYINT(1) DEFAULT 1,
            auto_reconnect TINYINT(1) DEFAULT 1,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            UNIQUE KEY unique_pair (passport, plate)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    -- Colunas de versões antigas. Cada coluna é verificada e criada por conta própria
    -- (uma migração que falhou no meio não pode pular as seguintes) e a fila só avança
    -- no callback: oxmysql despacha queries em paralelo, então um UPDATE disparado
    -- junto com o ALTER chega antes da coluna existir.
    local upgrades = {
        { 'player_playlists', 'collaborators', "ALTER TABLE player_playlists ADD COLUMN collaborators LONGTEXT NOT NULL DEFAULT '[]'" },
        { 'player_playlists', 'song_count', 'ALTER TABLE player_playlists ADD COLUMN song_count INT NOT NULL DEFAULT 0' },
        { 'player_playlists', 'thumb', "ALTER TABLE player_playlists ADD COLUMN thumb VARCHAR(512) NOT NULL DEFAULT ''" },
        { 'player_playlists', 'updated_at', 'ALTER TABLE player_playlists ADD COLUMN updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP' },
        { 'player_bluetooth_paired', 'auto_reconnect', 'ALTER TABLE player_bluetooth_paired ADD COLUMN auto_reconnect TINYINT(1) DEFAULT 1' }
    }

    -- Backfill único: colaboradores antigos (JSON) viram linhas indexadas.
    local function BackfillMembers()
        if GetResourceKvpString('members_backfill') == '2' then return end

        exports.oxmysql:query(
            "SELECT id, collaborators FROM player_playlists WHERE collaborators IS NOT NULL AND collaborators <> '[]'",
            {},
            function(rows)
                for _, row in ipairs(rows or {}) do
                    local list = json.decode(row.collaborators or '[]')
                    if type(list) == 'table' then
                        for _, passport in ipairs(list) do
                            local memberId = Bridge.Normalize(passport)

                            if memberId then
                                exports.oxmysql:insert(
                                    'INSERT IGNORE INTO player_playlist_members (playlist_id, passport) VALUES (?, ?)',
                                    { row.id, memberId }
                                )
                            end
                        end
                    end
                end
                SetResourceKvp('members_backfill', '2')
            end
        )
    end

    local function RunSql(sql, cb)
        local done = false

        local function next()
            if done then return end
            done = true
            if cb then cb() end
        end

        exports.oxmysql:query(sql, {}, next)
        SetTimeout(8000, next)
    end

    -- IDs de framework: o vRP usa passaporte numérico, QBCore/ESX usam texto
    -- (citizenid/identifier). As tabelas nascem VARCHAR(64); instalações
    -- antigas (INT) são alargadas uma única vez, sem perder dados.
    local idTables = {
        'player_playlists',
        'player_playlist_members',
        'player_spotify_recent',
        'player_bluetooth_paired'
    }

    local WidenIds
    WidenIds = function(index, cb)
        local tableName = idTables[index]
        if not tableName then
            if cb then cb() end
            return
        end

        exports.oxmysql:query([[
            SELECT DATA_TYPE AS kind FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name = ? AND column_name = 'passport' LIMIT 1
        ]], { tableName }, function(rows)
            local kind = rows and rows[1] and tostring(rows[1].kind or ''):lower() or ''

            if kind == '' or kind:find('char') or kind:find('text') then
                WidenIds(index + 1, cb)
                return
            end

            RunSql(('ALTER TABLE %s MODIFY passport VARCHAR(64) NOT NULL'):format(tableName), function()
                WidenIds(index + 1, cb)
            end)
        end)
    end

    -- Os CREATE TABLE acima também correm soltos: a tabela pode ainda não existir
    -- quando a fila de colunas começa, então esperamos ela aparecer de fato.
    local function WaitForTable(tableName, attempt, cb)
        HasColumn(tableName, 'id', function(exists)
            if exists or attempt >= 40 then return cb() end
            SetTimeout(250, function() WaitForTable(tableName, attempt + 1, cb) end)
        end)
    end

    local Upgrade
    Upgrade = function(index)
        local step = upgrades[index]

        if not step then
            -- Contagem e capa desnormalizadas para a lista de playlists.
            -- WidenIds vem antes do backfill: instalações antigas têm passport
            -- INT e os ids de QBCore/ESX são texto.
            RunSql('UPDATE player_playlists SET song_count = JSON_LENGTH(songs) WHERE JSON_VALID(songs)', function()
                RunSql([[UPDATE player_playlists SET thumb = COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(songs, '$[0].thumb')), 'null'), '') WHERE JSON_VALID(songs)]], function()
                    WidenIds(1, BackfillMembers)
                end)
            end)
            return
        end

        WaitForTable(step[1], 0, function()
            HasColumn(step[1], step[2], function(exists)
                if exists then return Upgrade(index + 1) end
                RunSql(step[3], function() Upgrade(index + 1) end)
            end)
        end)
    end

    Upgrade(1)
end)

/* app.js — solis_sound */
(function () {
    'use strict';

    var RES = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'solis_sound';

    var el = function (id) { return document.getElementById(id); };
    var icon = function (name) { return '<svg class="icon"><use href="#i-' + name + '"/></svg>'; };

    var $shell = el('shell');
    var $views = el('views');
    var $playlistList = el('playlistList');
    var $playlistGrid = el('playlistGrid');
    var $recentRow = el('recentRow');
    var $sessionsList = el('sessionsList');
    var $toasts = el('toasts');
    var $layer = el('layer');
    var $sheet = el('sheet');
    var $sheetTitle = el('sheetTitle');
    var $sheetSub = el('sheetSub');
    var $sheetBody = el('sheetBody');
    var $menu = el('menu');
    var $prompt = el('prompt');

    var state = {
        apiKey: '',
        soundCloudEnabled: false,
        spotifyEnabled: false,
        view: 'home',
        playing: false,
        repeat: 0,
        shuffle: false,
        volume: 0.5,
        time: 0,
        duration: 0,
        device: { kind: 'headphones', name: 'Fones privados', title: '', thumb: '', owns: true },
        queue: [],
        index: 0,
        localVolume: 1,
        muted: false,
        sessions: [],
        playlists: [],
        jam: null,
        limits: { sessions: 3, queue: 100 },
        recent: [],
        booted: false,
        seeking: false
    };

    var pl = { id: null, meta: null, songs: [], total: 0, loading: false, hasMore: true };
    var searchState = { songs: [], importName: '', canImport: false };

    // ---------------------------------------------------------------- rede
    function post(name, body) {
        return fetch('https://' + RES + '/' + name, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(body || {})
        }).then(function (response) {
            return response.text();
        }).then(function (text) {
            if (!text) return null;
            try { return JSON.parse(text); } catch (e) { return text; }
        }).catch(function () { return null; });
    }

    function esc(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function formatTime(seconds) {
        seconds = Math.max(0, Math.floor(seconds || 0));
        var m = Math.floor(seconds / 60);
        var s = seconds % 60;
        return m + ':' + (s < 10 ? '0' + s : s);
    }

    // ---------------------------------------------------------------- toasts
    var toastCount = 0;

    function toast(kind, text, title) {
        if (toastCount >= 3) {
            var first = $toasts.firstElementChild;
            if (first) first.remove();
        }

        var map = {
            success: { icon: 'check', title: 'Feito' },
            error: { icon: 'close', title: 'Erro' },
            warning: { icon: 'warn', title: 'Atenção' },
            info: { icon: 'info', title: 'Solis' }
        };

        var meta = map[kind] || map.info;
        var node = document.createElement('div');
        node.className = 'toast';
        node.innerHTML =
            '<span class="toast-icon ' + esc(kind) + '">' + icon(meta.icon) + '</span>' +
            '<div class="toast-copy"><strong>' + esc(title || meta.title) + '</strong><span>' + esc(text || '') + '</span></div>';

        $toasts.appendChild(node);
        toastCount++;

        setTimeout(function () {
            node.classList.add('is-out');
            setTimeout(function () {
                if (node.parentNode) node.parentNode.removeChild(node);
                toastCount--;
            }, 300);
        }, 4200);
    }
    window.__toast = toast;

    // ---------------------------------------------------------------- views
    function setView(name) {
        state.view = name;

        Array.prototype.forEach.call($views.children, function (view) {
            view.classList.toggle('is-active', view.dataset.view === name);
        });

        Array.prototype.forEach.call(document.querySelectorAll('.nav-item'), function (item) {
            item.classList.toggle('is-active', item.dataset.view === name);
        });

        if (name === 'sessions') refreshSessions();
        if (name === 'bluetooth') refreshBluetooth();
        if (name === 'jam') renderJam();
    }

    Array.prototype.forEach.call(document.querySelectorAll('.nav-item[data-view]'), function (node) {
        node.addEventListener('click', function () { setView(node.dataset.view); });
    });

    Array.prototype.forEach.call(document.querySelectorAll('[data-back]'), function (node) {
        node.addEventListener('click', function () { setView('home'); });
    });

    function setOpen(open) {
        $shell.dataset.open = open ? 'true' : 'false';
        document.body.classList.toggle('ui-open', open);
    }

    function closeUI() {
        setOpen(false);
        hideLayer();
        $menu.hidden = true;
        post('close');
    }

    el('btnClose').addEventListener('click', closeUI);

    // ---------------------------------------------------------------- player
    var $seek = el('seek');
    var $volume = el('volume');
    var $localVolume = el('localVolume');

    function setRangeFill(input) {
        var min = parseFloat(input.min) || 0;
        var max = parseFloat(input.max) || 100;
        var value = parseFloat(input.value) || 0;
        var pct = max > min ? ((value - min) / (max - min)) * 100 : 0;
        input.style.setProperty('--p', pct.toFixed(2));
    }

    function paintArt(node, thumb) {
        if (thumb) {
            node.style.backgroundImage = 'url("' + thumb.replace(/"/g, '') + '")';
        } else {
            node.style.backgroundImage = '';
            node.innerHTML = icon('music');
        }
    }

    function paintPlayIcon() {
        el('btnPlay').innerHTML = icon(state.playing ? 'pause' : 'play');
    }

    // Na Jam, só o anfitrião e quem ele liberou mexem na música e na fila.
    function jamLocked() {
        return !!(state.jam && !state.jam.isHost && state.jam.canControl !== true);
    }

    function requireJamControl() {
        if (!jamLocked()) return true;
        toast('warning', 'Nesta jam você está apenas como ouvinte.', 'Jam');
        return false;
    }

    function paintControls() {
        var $shuffle = el('btnShuffle');
        var $repeat = el('btnRepeat');

        $shuffle.classList.toggle('is-on', state.shuffle);
        $repeat.classList.toggle('is-on', state.repeat > 0);
        $repeat.innerHTML = icon(state.repeat === 2 ? 'repeat1' : 'repeat');

        ['btnPlay', 'btnPrev', 'btnNext', 'btnShuffle', 'btnRepeat'].forEach(function (id) {
            el(id).classList.toggle('is-locked', jamLocked());
        });

        el('jamRole').hidden = !jamLocked();

        $volume.value = Math.round(state.volume * 100);
        setRangeFill($volume);

        $localVolume.value = Math.round((state.muted ? 0 : state.localVolume) * 100);
        el('localVolumeLabel').textContent = (state.muted ? 0 : Math.round(state.localVolume * 100)) + '%';
        setRangeFill($localVolume);

        el('btnMute').innerHTML = icon(state.muted || state.localVolume === 0 ? 'volx' : 'vol');
    }

    function paintTrack() {
        var track = state.queue[state.index] || null;
        var title = (track && track.title) || state.device.title || 'Nenhuma música tocando';
        var thumb = (track && track.thumb) || state.device.thumb || '';

        el('nowTitle').textContent = title;
        el('nowDevice').textContent = state.device.name || 'Fones privados';
        paintArt(el('nowArt'), thumb);

        el('heroTitle').textContent = title;
        el('heroDevice').textContent = state.device.name || 'Fones privados';
        paintArt(el('heroArt'), thumb);

        paintPlayIcon();
        paintControls();
        paintDeviceIcon();
    }

    function paintDeviceIcon() {
        var kind = state.device.kind || 'headphones';
        var name = kind === 'vehicle' ? 'car' : (kind === 'stage' ? 'stage' : 'phones');
        el('deviceIcon').innerHTML = icon(name);
        el('deviceName').textContent = state.device.name || 'Fones privados';
    }

    function paintProgress() {
        var max = state.duration > 0 ? state.duration : 0;
        var pct = max > 0 ? (state.time / max) * 1000 : 0;

        if (!state.seeking) {
            $seek.value = Math.max(0, Math.min(1000, pct));
            setRangeFill($seek);
            el('timeNow').textContent = formatTime(state.time);
        }

        el('timeTotal').textContent = max > 0 ? formatTime(max) : '0:00';
        $seek.disabled = max <= 0 || jamLocked();
    }

    el('btnPlay').addEventListener('click', function () {
        if (!requireJamControl()) return;
        state.playing = !state.playing;
        paintPlayIcon();
        post('control', { action: state.playing ? 'resume' : 'pause' });
    });

    el('btnPrev').addEventListener('click', function () {
        if (!requireJamControl()) return;
        post('queue', { action: 'prev' }).then(applyQueue);
    });

    el('btnNext').addEventListener('click', function () {
        if (!requireJamControl()) return;
        post('queue', { action: 'next' }).then(applyQueue);
    });

    el('btnShuffle').addEventListener('click', function () {
        if (!requireJamControl()) return;
        state.shuffle = !state.shuffle;
        post('shuffle', { on: state.shuffle }).then(applyQueue);
        paintControls();
    });

    el('btnRepeat').addEventListener('click', function () {
        if (!requireJamControl()) return;
        state.repeat = (state.repeat + 1) % 3;
        post('repeat', { mode: state.repeat }).then(applyQueue);
        paintControls();
    });

    el('btnMute').addEventListener('click', function () {
        var target = (state.muted || state.localVolume === 0) ? 1 : 0;
        state.localVolume = target;
        state.muted = target === 0;
        post('volumeLocal', { value: target }).then(paintControls);
    });

    $seek.addEventListener('input', function () {
        if (state.duration <= 0) return;
        state.seeking = true;
        setRangeFill($seek);
        var max = state.duration || 0;
        if (max > 0) {
            el('timeNow').textContent = formatTime((parseFloat($seek.value) / 1000) * max);
        }
    });

    $seek.addEventListener('change', function () {
        state.seeking = false;
        if (!requireJamControl()) { paintProgress(); return; }
        var max = state.duration || 0;
        if (max <= 0) return;
        post('control', { action: 'seek', time: (parseFloat($seek.value) / 1000) * max });
    });

    // Sem debounce: o slider manda em cada `input`, igual ao /som. Um atraso
    // aqui era sentido em todos os comandos de volume, inclusive no fone.
    $volume.addEventListener('input', function () {
        state.volume = parseFloat($volume.value) / 100;
        setRangeFill($volume);
        post('control', { action: 'volume', value: state.volume });
    });

    $localVolume.addEventListener('input', function () {
        var value = parseFloat($localVolume.value) / 100;
        state.localVolume = value;
        state.muted = value === 0;
        el('localVolumeLabel').textContent = Math.round(value * 100) + '%';
        setRangeFill($localVolume);
        post('volumeLocal', { value: value }).then(function (res) {
            if (res && typeof res.local === 'number') {
                state.localVolume = res.local;
                state.muted = res.muted;
                paintControls();
            }
        });
    });

    el('devicePill').addEventListener('click', function () { openTransferSheet(); });

    // ---------------------------------------------------------------- queue
    function applyQueue(msg) {
        if (!msg || typeof msg !== 'object') return;

        if (Array.isArray(msg.queue)) state.queue = msg.queue;
        if (typeof msg.index === 'number') state.index = msg.index;
        if (typeof msg.repeatMode === 'number') state.repeat = msg.repeatMode;
        if (typeof msg.shuffle === 'boolean') state.shuffle = msg.shuffle;
        if (typeof msg.playing === 'boolean') state.playing = msg.playing;

        paintTrack();
        highlightPlayingRow();
    }

    // ---------------------------------------------------------------- home
    function renderRecent() {
        $recentRow.innerHTML = '';

        if (!state.recent.length) {
            $recentRow.innerHTML = '<div class="empty">Nada por aqui ainda. Toque algo e ele aparece aqui.</div>';
            return;
        }

        var frag = document.createDocumentFragment();

        state.recent.forEach(function (song) {
            var node = document.createElement('div');
            node.className = 'recent-card';
            node.innerHTML =
                '<div class="art"></div>' +
                '<div class="copy"><strong>' + esc(song.title) + '</strong><span>recente</span></div>';
            node.querySelector('.art').style.backgroundImage = song.thumb ? 'url("' + song.thumb.replace(/"/g, '') + '")' : '';
            node.addEventListener('click', function () { playOne(song); });
            frag.appendChild(node);
        });

        $recentRow.appendChild(frag);
    }

    function renderPlaylists() {
        $playlistList.innerHTML = '';
        $playlistGrid.innerHTML = '';

        el('playlistTotal').textContent = state.playlists.length
            ? state.playlists.length + (state.playlists.length === 1 ? ' playlist' : ' playlists')
            : '';

        if (!state.playlists.length) {
            $playlistList.innerHTML = '<div class="cell-empty">Nenhuma playlist</div>';
            $playlistGrid.innerHTML = '<div class="empty">Crie uma playlist ou importe um link do YouTube.</div>';
            return;
        }

        var sidebarFrag = document.createDocumentFragment();
        var gridFrag = document.createDocumentFragment();

        state.playlists.forEach(function (item, index) {
            var plNode = document.createElement('div');
            plNode.className = 'pl-item';
            plNode.dataset.id = item.id;
            if (state.view === 'playlist' && pl.id == item.id) plNode.classList.add('is-active');

            plNode.innerHTML =
                '<span class="pl-name">' + esc(item.name) + '</span>' +
                (item.isOwner ? '' : '<span class="pl-badge">' + icon('users') + '</span>') +
                '<span class="pl-count">' + (item.count || 0) + '</span>' +
                '<span class="pl-del" title="' + (item.isOwner ? 'Excluir' : 'Sair da colaboração') + '">' + icon('trash') + '</span>';

            plNode.addEventListener('click', function (event) {
                if (event.target.closest('.pl-del')) return;
                openPlaylist(item.id);
            });

            plNode.querySelector('.pl-del').addEventListener('click', function (event) {
                event.stopPropagation();
                post('playlistDelete', { id: item.id }).then(function () {
                    toast('warning', item.isOwner ? 'Playlist excluída.' : 'Você saiu da playlist.', 'Playlists');
                    if (pl.id == item.id) setView('home');
                });
            });

            sidebarFrag.appendChild(plNode);

            var card = document.createElement('div');
            card.className = 'album-card' + (index === 0 && state.playlists.length >= 3 ? ' is-featured' : '');

            var art = '<div class="album-art"' +
                (item.thumb ? ' style="background-image:url(&quot;' + esc(item.thumb) + '&quot;)"' : '') + '>' +
                (item.thumb ? '' : icon('music')) +
                '<span class="play-hint">' + icon('play') + '</span>' +
                '</div>';

            card.innerHTML =
                '<div class="album-core">' + art +
                '<div class="album-body">' +
                '<div class="album-name">' + esc(item.name) + '</div>' +
                '<div class="album-meta">' + (item.count || 0) + ' faixas' + (item.isOwner ? '' : ' · coletiva') + '</div>' +
                '</div></div>';

            card.addEventListener('click', function () { openPlaylist(item.id); });
            gridFrag.appendChild(card);
        });

        $playlistList.appendChild(sidebarFrag);
        $playlistGrid.appendChild(gridFrag);
    }

    function playOne(song) {
        if (!requireJamControl()) return;

        post('play', {
            url: song.url,
            title: song.title,
            thumb: song.thumb,
            queue: [song],
            index: 0
        }).then(function (res) {
            state.time = 0;
            state.playing = true;
            applyQueue(res);
        });
    }

    // ---------------------------------------------------------------- youtube
    var YT_ID = /^[A-Za-z0-9_-]{11}$/;

    function decodeEntities(text) {
        if (!text) return '';
        var node = document.createElement('textarea');
        node.innerHTML = text;
        return node.value;
    }

    function parseYouTubeLink(value) {
        var input = (value || '').trim();
        if (!input) return null;

        if (YT_ID.test(input)) {
            return { videoId: input, playlistId: '', url: 'https://www.youtube.com/watch?v=' + input };
        }

        var normalized = /^https?:\/\//i.test(input) ? input : 'https://' + input;
        var url;
        try { url = new URL(normalized); } catch (e) { return null; }

        var host = url.hostname.toLowerCase();
        if (!/(^|\.)(youtube\.com|youtu\.be|youtube-nocookie\.com)$/.test(host)) return null;

        var videoId = '';

        if (/(^|\.)youtu\.be$/.test(host)) {
            videoId = (url.pathname.split('/').filter(Boolean)[0] || '');
        } else {
            videoId = url.searchParams.get('v') || '';
            if (!videoId) {
                var parts = url.pathname.split('/').filter(Boolean);
                if (parts.length > 1 && ['shorts', 'embed', 'live', 'v', 'e'].indexOf(parts[0]) !== -1) {
                    videoId = parts[1];
                }
            }
        }

        if (!YT_ID.test(videoId)) videoId = '';

        var playlistId = url.searchParams.get('list') || '';
        if (!/^[A-Za-z0-9_-]{12,}$/.test(playlistId)) playlistId = '';

        if (!videoId && !playlistId) return null;

        return {
            videoId: videoId,
            playlistId: playlistId,
            url: videoId
                ? 'https://www.youtube.com/watch?v=' + videoId
                : 'https://www.youtube.com/playlist?list=' + playlistId
        };
    }

    // ------------------------------------------------------------ soundcloud
    function isSoundCloudUrl(value) {
        try {
            var url = new URL(/^https?:\/\//i.test(value) ? value : 'https://' + value);
            return /(^|\.)soundcloud\.com$/i.test(url.hostname);
        } catch (e) { return false; }
    }

    function isSpotifyLink(value) {
        return /open\.spotify\.com\/(track|playlist)\/[\w-]+/i.test(value || '')
            || /^spotify:(track|playlist):[\w-]+/i.test(value || '');
    }

    // A busca vai no servidor: ele tem o client_id da API interna e não sofre
    // CORS. A NUI recebe { songs, error } pelo reqId.
    function scSearch(query) {
        return post('scSearch', { query: query }).then(function (res) {
            if (!res || res.error) throw new Error((res && res.error) || 'soundcloud');
            return Array.isArray(res.songs) ? res.songs : [];
        });
    }

    function scResolve(url) {
        return post('scResolve', { url: url }).then(function (res) {
            if (!res || res.error || !res.song) throw new Error((res && res.error) || 'soundcloud');
            return res.song;
        });
    }

    // Intercala as fontes para a lista ser realmente mista, não YouTube + apêndice.
    function interleave(left, right) {
        var out = [];
        var max = Math.max(left.length, right.length);
        for (var i = 0; i < max; i++) {
            if (left[i]) out.push(left[i]);
            if (right[i]) out.push(right[i]);
        }
        return out;
    }

    function providerOf(song) {
        if (song && song.provider === 'spotify') return 'spotify';
        if (song && song.provider === 'soundcloud') return 'soundcloud';
        return 'youtube';
    }

    // ---------------------------------------------------------- spotify
    // Faixas do Spotify chegam com url open.spotify.com (só identidade). Antes
    // de entrar na fila elas são resolvidas para YouTube/SoundCloud no server,
    // mantendo provider='spotify' só para o selo.
    var spotifyResolved = {};

    function spotifySearch(query) {
        return post('spotifySearch', { query: query }).then(function (res) {
            if (!res || res.error) throw new Error((res && res.error) || 'spotify');
            return Array.isArray(res.songs) ? res.songs : [];
        });
    }

    function spotifyReplace(song) {
        if (!song || song.provider !== 'spotify') return song;
        var ready = spotifyResolved[song.spId];
        if (!ready) return song;

        return {
            url: ready.url,
            title: song.title,
            artist: song.artist,
            thumb: song.thumb,
            provider: 'spotify',
            spId: song.spId
        };
    }

    function handleSpotifyLink(value) {
        showResultsLoading('Lendo o link do Spotify...');

        return post('spotifyLink', { url: value }).then(function (res) {
            if (!res || res.error) throw new Error((res && res.error) || 'spotify');

            // Playlist: já existe no banco com os metadados. Abrimos o skeleton
            // na hora e as faixas vão aparecendo conforme são resolvidas.
            if (res.kind === 'playlist') {
                if (res.playlist) {
                    var exists = state.playlists.some(function (p) { return p.id == res.playlist.id; });
                    if (!exists) state.playlists.unshift(res.playlist);
                }

                openPlaylist(res.playlistId);
                toast('info', 'Importando: as faixas aparecem conforme ficam prontas.', 'Spotify');
                return res.playlist || null;
            }

            var song = res.song;
            if (song && song.spId) spotifyResolved[song.spId] = song;

            renderResults([song], {
                title: song.title,
                sub: 'Clique para tocar ou use o botão direito para salvar',
                importName: song.title
            });
            return song;
        });
    }

    function ensurePlayable(songs, done) {
        var pending = [];

        songs.forEach(function (song) {
            if (song && song.provider === 'spotify'
                && /^https:\/\/open\.spotify\.com\/track\//i.test(song.url)
                && !spotifyResolved[song.spId]) {
                pending.push(song);
            }
        });

        if (!pending.length) {
            done(songs.map(spotifyReplace));
            return;
        }

        toast('info', 'Resolvendo ' + pending.length + ' faixa(s) do Spotify...', 'Spotify');

        post('spotifyBatch', { songs: pending }).then(function (res) {
            ((res && res.songs) || []).forEach(function (song) {
                if (song && song.spId) spotifyResolved[song.spId] = song;
            });
            done(songs.map(spotifyReplace));
        });
    }

    function ytApi(endpoint, params) {
        return new Promise(function (resolve, reject) {
            if (!state.apiKey) { reject(new Error('missing_api_key')); return; }

            var query = Object.keys(params).map(function (key) {
                return key + '=' + encodeURIComponent(params[key]);
            }).join('&');

            fetch('https://www.googleapis.com/youtube/v3/' + endpoint + '?' + query + '&key=' + encodeURIComponent(state.apiKey))
                .then(function (response) {
                    return response.json().then(function (data) {
                        if (!response.ok) {
                            var errors = data && data.error && data.error.errors;
                            reject(new Error((errors && errors[0] && errors[0].reason) || 'request_failed'));
                            return;
                        }
                        resolve(data);
                    });
                })
                .catch(function () { reject(new Error('network')); });
        });
    }

    function ytThumb(snippet, videoId) {
        var thumbs = (snippet && snippet.thumbnails) || {};
        return (thumbs.medium && thumbs.medium.url)
            || (thumbs.high && thumbs.high.url)
            || (thumbs.default && thumbs.default.url)
            || (videoId ? 'https://img.youtube.com/vi/' + videoId + '/mqdefault.jpg' : '');
    }

    function ytSong(snippet, fallbackId) {
        if (!snippet) return null;
        var videoId = (snippet.resourceId && snippet.resourceId.videoId) || fallbackId || '';
        if (!videoId) return null;

        var title = decodeEntities(snippet.title);
        if (!title || title === 'Private video' || title === 'Deleted video') return null;

        return {
            url: 'https://www.youtube.com/watch?v=' + videoId,
            title: title,
            artist: decodeEntities(snippet.videoOwnerChannelTitle || snippet.channelTitle || 'YouTube'),
            thumb: ytThumb(snippet, videoId),
            provider: 'youtube'
        };
    }

    function ytError(err) {
        var code = (err && err.message) || '';
        if (code === 'missing_api_key') return 'Configure Config.YoutubeAPIKey para buscar no YouTube.';
        if (code === 'quotaExceeded' || code === 'rateLimitExceeded' || code === 'resourceExhausted') {
            return 'Cota diária da API do YouTube esgotada.';
        }
        if (code === 'playlistNotFound') return 'Playlist não encontrada, privada ou removida.';
        if (code === 'fallback_failed') return 'Não foi possível consultar o YouTube agora.';
        return 'Não foi possível falar com o YouTube agora.';
    }

    function ytFallback(kind, value) {
        var body = { kind: kind };
        if (kind === 'search') body.query = value;
        else if (kind === 'video') body.videoId = value;
        else if (kind === 'playlist') body.playlistId = value;

        return post('ytFallback', body).then(function (res) {
            if (!res || res.error) throw new Error((res && res.error) || 'fallback_failed');
            return res;
        });
    }

    function ytSearch(query) {
        function fallback() {
            return ytFallback('search', query).then(function (res) { return res.songs || []; });
        }

        if (!state.apiKey) return fallback();

        return ytApi('search', { part: 'snippet', maxResults: 18, q: query, type: 'video' })
            .then(function (data) {
                var songs = (data.items || []).map(function (item) {
                    var id = (item.id && item.id.videoId) || '';
                    if (!id) return null;
                    return {
                        url: 'https://www.youtube.com/watch?v=' + id,
                        title: decodeEntities((item.snippet && item.snippet.title) || ''),
                        artist: decodeEntities((item.snippet && item.snippet.channelTitle) || 'YouTube'),
                        thumb: ytThumb(item.snippet, id),
                        provider: 'youtube'
                    };
                }).filter(Boolean);

                return songs.length ? songs : null;
            })
            .then(function (songs) {
                return songs || fallback();
            }, function () {
                return fallback();
            });
    }

    function ytVideo(videoId) {
        function fallback() {
            return ytFallback('video', videoId).then(function (res) { return (res.songs || [])[0] || null; });
        }

        if (!state.apiKey) return fallback();

        return ytApi('videos', { part: 'snippet', id: videoId })
            .then(function (data) {
                var item = (data.items || [])[0];
                return ytSong(item && item.snippet, videoId);
            })
            .then(function (song) {
                return song || fallback();
            }, function () {
                return fallback();
            });
    }

    function ytPlaylist(playlistId) {
        function fallback() {
            return ytFallback('playlist', playlistId).then(function (res) {
                return { songs: res.songs || [], title: res.title || 'Playlist do YouTube' };
            });
        }

        if (!state.apiKey) return fallback();

        return Promise.all([
            fetchPlaylistSongs(playlistId, 250),
            ytApi('playlists', { part: 'snippet', id: playlistId }).then(function (data) {
                var item = (data.items || [])[0];
                return item && item.snippet ? decodeEntities(item.snippet.title) : 'Playlist do YouTube';
            })
        ]).then(function (res) {
            return res[0].length ? { songs: res[0], title: res[1] } : fallback();
        }, function () {
            return fallback();
        });
    }

    function fetchPlaylistSongs(playlistId, limit) {
        var max = limit || 250;
        var songs = [];

        function page(token) {
            var params = { part: 'snippet', maxResults: 50, playlistId: playlistId };
            if (token) params.pageToken = token;

            return ytApi('playlistItems', params).then(function (data) {
                (data.items || []).forEach(function (item) {
                    var song = ytSong(item.snippet || {});
                    if (song) songs.push(song);
                });

                if (data.nextPageToken && songs.length < max) return page(data.nextPageToken);
                return songs.slice(0, max);
            });
        }

        return page('');
    }

    // ---------------------------------------------------------------- results
    function renderResults(songs, head) {
        searchState.songs = songs || [];
        searchState.importName = (head && head.importName) || '';
        searchState.canImport = !!(head && head.importName);

        el('resultsTitle').textContent = (head && head.title) || 'Resultados';
        el('resultsSub').textContent = (head && head.sub) || '';
        el('btnImportResults').hidden = !searchState.canImport;

        var grid = el('resultsGrid');
        grid.innerHTML = '';

        if (!searchState.songs.length) {
            grid.innerHTML = '<div class="empty">Nada encontrado.</div>';
            return;
        }

        var frag = document.createDocumentFragment();

        searchState.songs.forEach(function (song) {
            var node = document.createElement('div');
            var provider = providerOf(song);
            var badgeClass = provider === 'spotify' ? 'provider-badge--sp'
                : (provider === 'soundcloud' ? 'provider-badge--sc' : 'provider-badge--yt');

            node.className = 'card card--' + provider;

            var thumb = song.thumb || '';
            node.innerHTML =
                '<div class="card-core">' +
                '<img src="' + esc(thumb) + '" loading="lazy" decoding="async" alt="">' +
                '<span class="provider-badge ' + badgeClass + '"></span>' +
                '<div class="title">' + esc(song.title) + '</div>' +
                '<div class="artist">' + esc(song.artist || '') + '</div>' +
                '</div>';

            node.addEventListener('click', function () {
                if (!requireJamControl()) return;

                var queue = searchState.songs.map(function (item) {
                    return {
                        url: item.url, title: item.title, thumb: item.thumb,
                        provider: providerOf(item), spId: item.spId
                    };
                });
                var index = searchState.songs.indexOf(song);

                // A música atual continua tocando enquanto as faixas do Spotify
                // são resolvidas; só troca quando a fila está pronta.
                ensurePlayable(queue, function (ready) {
                    post('play', {
                        url: ready[index].url, title: ready[index].title,
                        thumb: ready[index].thumb, provider: providerOf(ready[index]),
                        spId: ready[index].spId,
                        queue: ready, index: index
                    }).then(function (res) {
                        state.playing = true;
                        state.time = 0;
                        applyQueue(res);
                    });
                });
            });

            node.addEventListener('contextmenu', function (event) {
                event.preventDefault();
                openSongMenu(event, song);
            });

            frag.appendChild(node);
        });

        grid.appendChild(frag);
    }

    function showResultsLoading(text) {
        setView('search');
        el('resultsTitle').textContent = 'Carregando';
        el('resultsSub').textContent = text || '';
        el('btnImportResults').hidden = true;
        el('resultsGrid').innerHTML =
            '<div class="empty"><span class="scan-dot"></span> ' + esc(text || 'Buscando...') + '</div>';
    }

    function doSearch() {
        var query = (el('searchInput').value || '').trim();
        if (!query) { setView('home'); return; }

        // Link do Spotify: faixa resolve na hora; playlist importa em background.
        if (state.spotifyEnabled && isSpotifyLink(query)) {
            handleSpotifyLink(query).catch(function () {
                renderResults([], { title: 'Link', sub: 'Não foi possível ler este link do Spotify.' });
            });
            return;
        }

        // Link do SoundCloud: resolve reduz o perfil/playlist à faixa.
        if (isSoundCloudUrl(query)) {
            showResultsLoading('Lendo o link do SoundCloud...');

            scResolve(query).then(function (song) {
                renderResults([song], {
                    title: song.title,
                    sub: 'Clique para tocar ou use o botão direito para salvar',
                    importName: song.title
                });
            }).catch(function () {
                renderResults([], { title: 'Link', sub: 'Não foi possível ler este link do SoundCloud.' });
            });
            return;
        }

        var link = parseYouTubeLink(query);

        if (link) {
            showResultsLoading('Lendo o link...');

            if (link.playlistId) {
                ytPlaylist(link.playlistId)
                    .then(function (res) {
                        renderResults(res.songs, {
                            title: res.title,
                            sub: res.songs.length + ' vídeos · clique para tocar, botão direito para salvar',
                            importName: res.title
                        });
                    })
                    .catch(function (err) {
                        renderResults([], { title: 'Link', sub: ytError(err) });
                    });
                return;
            }

            ytVideo(link.videoId)
                .then(function (found) {
                    var song = found || {
                        url: link.url, title: 'Vídeo do YouTube', artist: 'YouTube', thumb: '', provider: 'youtube'
                    };

                    renderResults([song], {
                        title: 'Vídeo',
                        sub: 'Clique para tocar ou use o botão direito para salvar',
                        importName: song.title
                    });
                })
                .catch(function (err) {
                    renderResults([], { title: 'Vídeo', sub: ytError(err) });
                });
            return;
        }

        showResultsLoading('Buscando no YouTube, SoundCloud e Spotify...');

        var failures = [];

        var youtube = ytSearch(query)
            .catch(function (err) {
                failures.push(ytError(err));
                return [];
            });

        var soundcloud = state.soundCloudEnabled
            ? scSearch(query).catch(function () {
                failures.push('Busca no SoundCloud indisponível.');
                return [];
            })
            : Promise.resolve([]);

        var spotify = state.spotifyEnabled
            ? spotifySearch(query).catch(function () {
                failures.push('Busca no Spotify indisponível.');
                return [];
            })
            : Promise.resolve([]);

        Promise.all([youtube, soundcloud, spotify]).then(function (result) {
            var ytSongs = result[0];
            var scSongs = result[1];
            var spSongs = result[2];
            var songs = interleave(interleave(ytSongs, spSongs), scSongs);

            if (!songs.length) {
                renderResults([], { title: 'Busca', sub: failures.join(' ') || 'Nada encontrado.' });
                return;
            }

            var parts = [];
            if (ytSongs.length) parts.push(ytSongs.length + ' YouTube');
            if (scSongs.length) parts.push(scSongs.length + ' SoundCloud');
            if (spSongs.length) parts.push(spSongs.length + ' Spotify');

            renderResults(songs, {
                title: 'Busca',
                sub: parts.join(' + ') + (failures.length ? ' · ' + failures.join(' ') : '')
            });
        });
    }

    el('searchInput').addEventListener('keydown', function (event) {
        if (event.key === 'Enter') { event.preventDefault(); doSearch(); }
    });

    el('btnImportResults').addEventListener('click', function () {
        if (!searchState.songs.length) return;
        var name = searchState.importName || 'Playlist importada';
        ensurePlayable(searchState.songs.slice(), function (ready) {
            createPlaylistWith(name, ready);
        });
    });

    // ---------------------------------------------------------------- playlists
    function openPlaylist(id) {
        var meta = state.playlists.filter(function (item) { return item.id == id; })[0];
        if (!meta) return;

        pl = { id: id, meta: meta, songs: [], total: meta.count || 0, loading: false, hasMore: true };

        el('plName').textContent = meta.name;
        el('plMeta').textContent = (meta.count || 0) + ' faixas' + (meta.isOwner ? '' : ' · coletiva');
        el('btnPlInvite').hidden = !meta.isOwner;
        el('plRows').innerHTML = '';
        el('plScroll').scrollTop = 0;

        setView('playlist');
        renderPlaylists();
        loadSongs();
    }

    function rowElement(song, index) {
        var node = document.createElement('div');
        var pending = song.pending === true;
        var failed = song.failed === true;

        node.className = 'row' + (pending ? ' row--pending' : '') + (failed ? ' row--failed' : '');
        node.dataset.index = index;
        node.tabIndex = (pending || failed) ? -1 : 0;

        var art = song.thumb
            ? '<img src="' + esc(song.thumb) + '" loading="lazy" decoding="async" draggable="false" alt="">'
            : '<span class="row-art">' + icon('music') + '</span>';

        var status = pending
            ? '<span class="row-loading" title="Resolvendo fonte..."><span class="scan-dot"></span></span>'
            : (failed ? '<span class="row-loading" title="Sem fonte disponível">' + icon('warn') + '</span>' : '');

        node.innerHTML =
            '<span class="grip">' + (pending ? '' : icon('grip')) + '</span>' +
            art +
            '<div class="title">' + esc(song.title) + '</div>' +
            '<span class="tools">' + status +
            (pending ? '' : '<button class="icon-btn pl-remove" title="Remover">' + icon('close') + '</button>') +
            '</span>';

        // Skeleton: metadados já ocupam a linha, mas não há o que tocar ainda.
        if (pending) return node;

        node.addEventListener('click', function (event) {
            if (event.target.closest('.pl-remove')) return;
            if (failed || !song.url) return; // sem fonte resolvida
            if (Date.now() < dragClickGuard) return; // terminou um arrasto: não toca
            playFromPlaylist(index);
        });

        node.querySelector('.pl-remove').addEventListener('click', function (event) {
            event.stopPropagation();
            var target = parseInt(node.dataset.index, 10);
            pl.songs.splice(target, 1);
            pl.total = Math.max(0, pl.total - 1);
            post('playlistRemove', { id: pl.id, index: target + 1 });
            renderRows();
            updatePlMeta();
        });

        // Arrato manual: o drag nativo do HTML5 não é usado porque no CEF do
        // FiveM ele trava o cursor e nunca entrega `drop`.
        node.addEventListener('mousedown', function (event) {
            if (event.button !== 0) return;
            if (failed || event.target.closest('.pl-remove')) return;

            // impede seleção de texto e o arrasto nativo de imagem/linha
            event.preventDefault();
            try { node.focus({ preventScroll: true }); } catch (e) { }
            beginDrag(node, event);
        });

        node.addEventListener('keydown', function (event) {
            if (!event.altKey) return;
            var target = parseInt(node.dataset.index, 10);
            var next = event.key === 'ArrowUp' ? target - 1 : (event.key === 'ArrowDown' ? target + 1 : null);
            if (next === null || next < 0 || next >= pl.songs.length) return;

            event.preventDefault();
            moveRow(target, next);
        });

        return node;
    }

    // ---------------------------------------------------------------- arrasto
    // CEF/NUI: o drag nativo trava o cursor, então o arrasto é refeito à mão
    // com os eventos de mouse do documento.
    var drag = null;
    var dragClickGuard = 0;
    var dragScroll = 0;
    var dragFrame = 0;

    function moveRow(from, to) {
        if (!pl.id || from === to) return;

        var moved = pl.songs.splice(from, 1)[0];
        if (!moved) return;
        pl.songs.splice(to, 0, moved);

        post('playlistMove', { id: pl.id, from: from + 1, to: to + 1 });
        renderRows();

        var focusRow = el('plRows').querySelector('[data-index="' + to + '"]');
        if (focusRow) { try { focusRow.focus({ preventScroll: true }); } catch (e) { focusRow.focus(); } }
    }

    function rowIndexAt(clientY) {
        var rows = el('plRows').children;
        var best = -1;
        var bestDist = Infinity;

        for (var i = 0; i < rows.length; i++) {
            var index = parseInt(rows[i].dataset.index, 10);
            if (isNaN(index)) continue;

            var rect = rows[i].getBoundingClientRect();
            if (clientY >= rect.top && clientY <= rect.bottom) return index;

            var dist = clientY < rect.top ? rect.top - clientY : clientY - rect.bottom;
            if (dist < bestDist) { bestDist = dist; best = index; }
        }

        return best;
    }

    function paintDragOver() {
        Array.prototype.forEach.call(el('plRows').children, function (row) {
            var index = parseInt(row.dataset.index, 10);
            row.classList.toggle('is-over', !!drag && drag.active && index === drag.over && index !== drag.from);
        });
    }

    function beginDrag(node, event) {
        var index = parseInt(node.dataset.index, 10);
        if (isNaN(index)) return;

        drag = {
            from: index,
            over: index,
            row: node,
            startX: event.clientX,
            startY: event.clientY,
            lastY: event.clientY,
            active: false
        };
    }

    function endDrag() {
        if (!drag) return null;

        var result = { active: drag.active, from: drag.from, over: drag.over };

        drag.row.classList.remove('is-dragging');
        Array.prototype.forEach.call(el('plRows').children, function (row) {
            row.classList.remove('is-over');
        });
        document.body.classList.remove('is-dragging');

        drag = null;
        setDragScroll(0);

        return result;
    }

    function dragTick() {
        dragFrame = 0;
        if (!drag || !drag.active || !dragScroll) return;

        el('plScroll').scrollTop += dragScroll * 14;
        if (drag) drag.over = rowIndexAt(drag.lastY);
        paintDragOver();

        dragFrame = requestAnimationFrame(dragTick);
    }

    function setDragScroll(direction) {
        if (dragScroll === direction) return;
        dragScroll = direction;

        if (direction && drag && drag.active && !dragFrame) dragFrame = requestAnimationFrame(dragTick);
    }

    document.addEventListener('mousemove', function (event) {
        if (!drag) return;

        if (!drag.active) {
            if (Math.abs(event.clientY - drag.startY) < 4 && Math.abs(event.clientX - drag.startX) < 4) return;

            drag.active = true;
            drag.row.classList.add('is-dragging');
            document.body.classList.add('is-dragging');
        }

        event.preventDefault();
        drag.lastY = event.clientY;

        var box = el('plScroll').getBoundingClientRect();

        if (event.clientY < box.top) { setDragScroll(-1); return; }
        if (event.clientY > box.bottom) { setDragScroll(1); return; }

        drag.over = rowIndexAt(event.clientY);
        paintDragOver();

        // auto-scroll perto das bordas: listas longas continuam arrastáveis
        var edge = Math.min(72, box.height / 3);
        if (event.clientY - box.top < edge) setDragScroll(-1);
        else if (box.bottom - event.clientY < edge) setDragScroll(1);
        else setDragScroll(0);
    }, { passive: false });

    document.addEventListener('mouseup', function (event) {
        if (!drag) return;

        var result = endDrag();
        if (!result || !result.active || event.button !== 0) return;

        dragClickGuard = Date.now() + 250; // o click que vem depois não toca a faixa
        if (result.over >= 0) moveRow(result.from, result.over);
    });

    document.addEventListener('keydown', function (event) {
        if (!drag || event.key !== 'Escape') return;

        event.preventDefault();
        event.stopPropagation();
        dragClickGuard = Date.now() + 250;
        endDrag();
    }, true);

    window.addEventListener('blur', function () { endDrag(); });

    function renderRows() {
        var frag = document.createDocumentFragment();
        pl.songs.forEach(function (song, index) { frag.appendChild(rowElement(song, index)); });
        el('plRows').innerHTML = '';
        el('plRows').appendChild(frag);
        highlightPlayingRow();
    }

    // Uma faixa do skeleton foi resolvida: troca só a linha correspondente,
    // preservando scroll e eventos das outras linhas.
    function patchPlaylistTrack(id, oneBased, song) {
        if (!pl.id || pl.id != id) return;

        var pos = oneBased - 1;
        if (pos < 0 || pos >= pl.songs.length) return;

        pl.songs[pos] = song;

        var old = el('plRows').querySelector('.row[data-index="' + pos + '"]');
        if (!old) return;

        var next = rowElement(song, pos);
        old.parentNode.replaceChild(next, old);
        highlightPlayingRow();
    }

    function updatePlMeta() {
        el('plMeta').textContent = pl.total + ' faixas' + (pl.meta && !pl.meta.isOwner ? ' · coletiva' : '');
    }

    function loadSongs() {
        if (pl.loading || !pl.hasMore || !pl.id) return;
        pl.loading = true;

        post('playlistSongs', { id: pl.id, offset: pl.songs.length }).then(function (res) {
            pl.loading = false;

            if (!res || !Array.isArray(res.songs) || !res.songs.length) {
                pl.hasMore = false;
                if (!pl.songs.length) {
                    el('plRows').innerHTML = '<div class="empty">Playlist vazia.</div>';
                }
                return;
            }

            var frag = document.createDocumentFragment();
            var start = pl.songs.length;

            res.songs.forEach(function (song, offset) {
                frag.appendChild(rowElement(song, start + offset));
                pl.songs.push(song);
            });

            var placeholder = el('plRows').querySelector('.empty');
            if (placeholder) placeholder.remove();

            el('plRows').appendChild(frag);

            pl.total = typeof res.total === 'number' ? res.total : pl.total;
            pl.hasMore = pl.songs.length < pl.total;

            updatePlMeta();
            highlightPlayingRow();
        });
    }

    function highlightPlayingRow() {
        var current = state.queue[state.index];
        if (!current) return;

        Array.prototype.forEach.call(el('plRows').children, function (row) {
            var index = parseInt(row.dataset.index, 10);
            var song = pl.songs[index];
            row.classList.toggle('is-playing', !!song && song.url === current.url);
        });
    }

    function playFromPlaylist(index) {
        if (!requireJamControl()) return;

        // from = faixa clicada: a fila começa nela, sem depender de carregar tudo antes
        post('playlistQueue', { id: pl.id, from: index }).then(function (songs) {
            if (!Array.isArray(songs) || !songs.length) {
                toast('warning', 'Esta playlist está vazia.', 'Playlists');
                return;
            }

            post('play', { queue: songs, index: 0 }).then(function (res) {
                state.playing = true;
                state.time = 0;
                applyQueue(res);
            });
        });
    }

    el('btnPlPlay').addEventListener('click', function () { playFromPlaylist(0); });
    el('btnPlBack').addEventListener('click', function () { setView('home'); });

    var sentinelObserver = new IntersectionObserver(function (entries) {
        if (entries.some(function (entry) { return entry.isIntersecting; })) loadSongs();
    }, { root: el('plScroll'), rootMargin: '220px' });

    sentinelObserver.observe(el('plSentinel'));

    el('btnPlAirdrop').addEventListener('click', function () {
        if (!pl.id) return;
        post('nearbyPlayers').then(function (players) {
            if (!Array.isArray(players) || !players.length) {
                toast('warning', 'Ninguém por perto (10 m).', 'AirDrop');
                return;
            }

            chooseSheet('AirDrop', 'Enviar "' + (pl.meta ? pl.meta.name : '') + '" para alguém por perto', players.map(function (player) {
                return { id: player.passport, label: player.name, sub: '#' + player.passport, icon: 'users' };
            })).then(function (passport) {
                if (passport == null) return;
                post('airdropSend', { id: pl.id, passport: passport });
                toast('info', 'Pedido de AirDrop enviado.', 'AirDrop');
            });
        });
    });

    el('btnPlInvite').addEventListener('click', function () {
        if (!pl.id) return;
        askSheet('Convidar colaborador', 'O passaporte recebe um convite para editar a playlist.', {
            label: 'Passaporte', confirm: 'Convidar'
        }).then(function (passport) {
            if (!passport) return;
            post('collabInvite', { id: pl.id, passport: passport });
            toast('info', 'Convite enviado.', 'Playlists');
        });
    });

    el('btnCreatePlaylist').addEventListener('click', function () {
        askSheet('Nova playlist', 'Um nome curto e direto.', { label: 'Nome', confirm: 'Criar' }).then(function (name) {
            if (!name) return;
            post('playlistCreate', { name: name });
        });
    });

    el('btnImport').addEventListener('click', function () {
        askSheet('Importar link', 'Cole um link do YouTube ou do Spotify (faixa/playlist).', { label: 'Link', confirm: 'Importar' })
            .then(function (link) {
                if (!link) return;
                runImport(link);
            });
    });

    function runImport(value) {
        if (state.spotifyEnabled && isSpotifyLink(value)) {
            handleSpotifyLink(value).catch(function () {
                toast('error', 'Não foi possível ler este link do Spotify.', 'Importar');
            });
            return;
        }

        var link = parseYouTubeLink(value);
        if (!link) { toast('error', 'Link inválido.', 'Importar'); return; }

        if (link.playlistId) {
            toast('info', 'Lendo a playlist...', 'Importar');
            ytPlaylist(link.playlistId)
                .then(function (res) {
                    createPlaylistWith(res.title, res.songs);
                })
                .catch(function (err) { toast('error', ytError(err), 'Importar'); });
            return;
        }

        ytVideo(link.videoId)
            .then(function (found) {
                var song = found || { url: link.url, title: 'Vídeo do YouTube', thumb: '' };
                createPlaylistWith(song.title, [song]);
            })
            .catch(function () {
                createPlaylistWith('Vídeo do YouTube', [{ url: link.url, title: 'Vídeo do YouTube', thumb: '' }]);
            });
    }

    function createPlaylistWith(name, songs) {
        if (!songs || !songs.length) {
            toast('warning', 'Nada para importar.', 'Importar');
            return;
        }

        var trimmed = songs.slice(0, 250).map(function (song) {
            return {
                url: song.url, title: song.title, thumb: song.thumb || '',
                provider: providerOf(song), spId: song.spId
            };
        });

        post('playlistCreate', { name: (name || 'Playlist').substring(0, 80), songs: trimmed }).then(function () {
            toast('success', trimmed.length + ' faixas importadas.', 'Playlists');
        });
    }

    // ---------------------------------------------------------------- context menu
    function openSongMenu(event, song) {
        $menu.innerHTML = '<div class="menu-head">Salvar em</div>';

        var newItem = document.createElement('button');
        newItem.className = 'menu-item';
        newItem.innerHTML = icon('plus') + '<span class="grow">Nova playlist</span>';
        newItem.addEventListener('click', function () {
            $menu.hidden = true;
            askSheet('Nova playlist', esc(song.title), { label: 'Nome', value: song.title, confirm: 'Criar' })
                .then(function (name) {
                    if (!name) return;
                    ensurePlayable([song], function (ready) {
                        post('playlistCreate', { name: name, songs: ready });
                        toast('success', 'Playlist criada com a faixa.', 'Playlists');
                    });
                });
        });
        $menu.appendChild(newItem);

        state.playlists.forEach(function (item) {
            var node = document.createElement('button');
            node.className = 'menu-item';
            node.innerHTML = icon('music') + '<span class="grow">' + esc(item.name) + '</span>';
            node.addEventListener('click', function () {
                $menu.hidden = true;
                ensurePlayable([song], function (ready) {
                    post('playlistAdd', { id: item.id, song: ready[0] });
                    toast('success', 'Adicionada em ' + item.name + '.', 'Playlists');
                });
            });
            $menu.appendChild(node);
        });

        $menu.hidden = false;

        var rect = $menu.getBoundingClientRect();
        var x = Math.min(event.clientX, window.innerWidth - rect.width - 12);
        var y = Math.min(event.clientY, window.innerHeight - rect.height - 12);
        $menu.style.left = Math.max(12, x) + 'px';
        $menu.style.top = Math.max(12, y) + 'px';
    }

    document.addEventListener('click', function (event) {
        if (!$menu.hidden && !event.target.closest('#menu')) $menu.hidden = true;
    });

    // ---------------------------------------------------------------- sheets
    var sheetResolve = null;

    function openLayer(title, sub) {
        $sheetTitle.textContent = title || '';
        $sheetSub.textContent = sub || '';
        $sheetSub.hidden = !sub;
        $sheetBody.innerHTML = '';
        $layer.hidden = false;
        sheetResolve = null;
    }

    function hideLayer() {
        $layer.hidden = true;
        $sheetBody.innerHTML = '';
        sheetResolve = null;
    }

    function askSheet(title, sub, options) {
        options = options || {};

        return new Promise(function (resolve) {
            openLayer(title, sub);
            sheetResolve = resolve;

            var input = document.createElement('input');
            input.className = 'sheet-input';
            input.type = 'text';
            input.placeholder = options.label || '';
            input.value = options.value || '';

            var actions = document.createElement('div');
            actions.className = 'sheet-actions';

            var confirm = document.createElement('button');
            confirm.className = 'btn btn--accent';
            confirm.innerHTML = '<span>' + (options.confirm || 'Confirmar') + '</span>';

            var cancel = document.createElement('button');
            cancel.className = 'btn btn--ghost';
            cancel.innerHTML = '<span>Cancelar</span>';

            actions.appendChild(cancel);
            actions.appendChild(confirm);

            $sheetBody.appendChild(input);
            $sheetBody.appendChild(actions);

            function done(value) {
                var cb = sheetResolve;
                hideLayer();
                if (cb) cb(value);
            }

            confirm.addEventListener('click', function () { done(input.value.trim()); });
            cancel.addEventListener('click', function () { done(null); });
            input.addEventListener('keydown', function (event) {
                if (event.key === 'Enter') { event.preventDefault(); done(input.value.trim()); }
            });

            setTimeout(function () { input.focus(); }, 40);
        });
    }

    function chooseSheet(title, sub, rows) {
        return new Promise(function (resolve) {
            openLayer(title, sub);
            sheetResolve = resolve;

            if (!rows.length) {
                $sheetBody.innerHTML = '<div class="sheet-empty">Nada disponível.</div>';
            }

            rows.forEach(function (row) {
                var node = document.createElement('button');
                node.className = 'sheet-row' + (row.selected ? ' is-selected' : '');
                node.innerHTML =
                    (row.icon ? icon(row.icon) : '') +
                    '<span class="grow">' + esc(row.label) + (row.sub ? '<span class="sub">' + esc(row.sub) + '</span>' : '') + '</span>' +
                    (row.selected ? icon('check') : '');

                node.addEventListener('click', function () {
                    var cb = sheetResolve;
                    hideLayer();
                    if (cb) cb(row.id);
                });

                $sheetBody.appendChild(node);
            });

            var cancel = document.createElement('div');
            cancel.className = 'sheet-actions';
            cancel.innerHTML = '<button class="btn btn--ghost" id="sheetCancel"><span>Cancelar</span></button>';
            $sheetBody.appendChild(cancel);
            cancel.querySelector('#sheetCancel').addEventListener('click', function () {
                var cb = sheetResolve;
                hideLayer();
                if (cb) cb(null);
            });
        });
    }

    $layer.addEventListener('click', function (event) {
        if (event.target === $layer) {
            var cb = sheetResolve;
            hideLayer();
            if (cb) cb(null);
        }
    });

    // ---------------------------------------------------------------- transfer
    function openTransferSheet() {
        post('bluetooth').then(function (data) {
            var rows = [{ id: 'headphones', label: 'Fones privados', sub: 'Só você ouve', icon: 'phones' }];

            var devices = [].concat((data && data.paired) || [], (data && data.others) || []);

            devices.forEach(function (device, index) {
                rows.push({
                    id: 'dev:' + index,
                    label: device.name,
                    sub: device.kind === 'stage'
                        ? 'Palco · ' + (device.connections || 0) + '/' + (device.maxConnections || 0)
                        : 'Placa ' + device.plate,
                    icon: device.kind === 'stage' ? 'stage' : 'car',
                    selected: device.isConnected
                });
            });

            chooseSheet('Transferir reprodução', 'A faixa e a fila continuam de onde estão', rows).then(function (choice) {
                if (!choice) return;

                if (choice === 'headphones') {
                    post('headphones');
                    toast('success', 'Áudio nos fones privados.', 'Transferir');
                    return;
                }

                var device = devices[parseInt(String(choice).split(':')[1], 10)];
                if (!device) return;

                post('bluetoothConnect', {
                    device: { kind: device.kind, netId: device.netId, stageId: device.stageId, plate: device.plate, name: device.name },
                    handoff: true
                }).then(handleConnectResult);
            });
        });
    }

    function handleConnectResult(res) {
        if (!res) { toast('error', 'Sem resposta do dispositivo.', 'Bluetooth'); return; }

        if (res.status === 'connected') {
            toast('success', 'Reprodução transferida.', 'Bluetooth');
        } else if (res.status === 'pending') {
            toast('warning', res.message || 'Aguardando o dono autorizar.', 'Bluetooth');
        } else {
            toast('error', res.message || 'Não foi possível conectar.', 'Bluetooth');
        }
    }

    // ---------------------------------------------------------------- bluetooth view
    var btTimer = null;

    function refreshBluetooth() {
        post('bluetooth').then(function (data) {
            if (!data) return;
            renderDevices(data);
            el('btScan').innerHTML = '<span class="scan-dot"></span>procurando';
        });
    }

    function renderDevices(data) {
        var paired = (data && data.paired) || [];
        var others = (data && data.others) || [];

        var pairedGroup = el('btPaired');
        var othersGroup = el('btOthers');

        pairedGroup.innerHTML = '';
        othersGroup.innerHTML = '';

        if (!paired.length) {
            pairedGroup.innerHTML = '<div class="cell-empty">Nenhum dispositivo salvo.</div>';
        }

        if (!others.length) {
            othersGroup.innerHTML = '<div class="cell-empty">Nada num raio de 12 m.</div>';
        }

        paired.forEach(function (device) {
            pairedGroup.appendChild(deviceCell(device, true));
        });

        others.forEach(function (device) {
            othersGroup.appendChild(deviceCell(device, false));
        });
    }

    function deviceCell(device, paired) {
        var node = document.createElement('div');
        node.className = 'cell' + (device.isConnected ? ' is-connected' : '');

        var isStage = device.kind === 'stage';
        var detail = device.isConnected
            ? (device.playing ? 'Tocando: ' + device.track : 'Conectado')
            : (isStage ? (device.connections || 0) + ' ouvindo' : 'Placa ' + device.plate);

        node.innerHTML =
            '<span class="cell-icon' + (isStage ? ' is-stage' : '') + '">' + icon(isStage ? 'stage' : 'car') + '</span>' +
            '<div class="cell-copy"><strong>' + esc(device.name) + '</strong><span>' + esc(detail) + '</span></div>' +
            '<span class="cell-action">' + (device.isConnected ? '<span class="ok">' + icon('check') + '</span>' : icon('plus')) + '</span>';

        node.addEventListener('click', function () {
            if (device.isConnected) {
                openDeviceSheet(device);
                return;
            }

            chooseSheet(device.name, isStage ? 'Palco da cidade' : 'Placa ' + device.plate, [
                { id: 'handoff', label: 'Transferir o que está tocando', sub: 'A faixa continua no ponto atual', icon: 'share' },
                { id: 'new', label: 'Nova sessão independente', sub: 'Começa do zero neste dispositivo', icon: 'plus' }
            ]).then(function (choice) {
                if (!choice) return;

                post('bluetoothConnect', {
                    device: {
                        kind: device.kind, netId: device.netId, stageId: device.stageId,
                        plate: device.plate, name: device.name
                    },
                    handoff: choice === 'handoff'
                }).then(handleConnectResult);
            });
        });

        return node;
    }

    function openDeviceSheet(device) {
        openLayer(device.name, device.kind === 'stage' ? 'Palco' : 'Placa ' + device.plate);

        if (device.kind !== 'stage') {
            var row = document.createElement('div');
            row.className = 'sheet-row';
            row.innerHTML =
                '<span class="grow">Reconectar automaticamente<span class="sub">Mesmo sem pedir de novo</span></span>' +
                '<label class="switch"><input type="checkbox" id="autoReconnect"' + (device.auto ? ' checked' : '') + '><span></span></label>';

            row.querySelector('#autoReconnect').addEventListener('change', function (event) {
                post('bluetoothAuto', { plate: device.plate, on: event.target.checked });
            });

            $sheetBody.appendChild(row);
        }

        var leave = document.createElement('button');
        leave.className = 'sheet-row';
        leave.innerHTML = icon('left') + '<span class="grow">Voltar para os fones</span>';
        leave.addEventListener('click', function () {
            hideLayer();
            post('headphones');
            toast('success', 'Áudio nos fones privados.', 'Transferir');
        });
        $sheetBody.appendChild(leave);

        if (device.kind !== 'stage') {
            var forget = document.createElement('button');
            forget.className = 'sheet-row';
            forget.innerHTML = icon('trash') + '<span class="grow">Esquecer dispositivo</span>';
            forget.addEventListener('click', function () {
                hideLayer();
                post('bluetoothForget', { plate: device.plate }).then(function () {
                    toast('warning', 'Dispositivo esquecido.', 'Bluetooth');
                    refreshBluetooth();
                });
            });
            $sheetBody.appendChild(forget);
        }

        var actions = document.createElement('div');
        actions.className = 'sheet-actions';
        actions.innerHTML = '<button class="btn btn--ghost" id="sheetClose"><span>Fechar</span></button>';
        $sheetBody.appendChild(actions);
        actions.querySelector('#sheetClose').addEventListener('click', hideLayer);
    }

    // ---------------------------------------------------------------- sessions
    function refreshSessions() {
        post('sessions').then(function (list) {
            state.sessions = Array.isArray(list) ? list : [];
            renderSessions();
        });
    }

    function renderSessions() {
        el('sessionCount').textContent = state.sessions.length;
        el('sessionsLimit').textContent = state.sessions.length + ' / ' + (state.limits.sessions || 3);

        $sessionsList.innerHTML = '';

        if (!state.sessions.length) {
            $sessionsList.innerHTML = '<div class="empty">Nenhuma sessão. Conecte-se a um carro ou palco pelo Bluetooth.</div>';
            return;
        }

        var frag = document.createDocumentFragment();

        state.sessions.forEach(function (session) {
            var node = document.createElement('div');
            node.className = 'session' + (session.focus ? ' is-focused' : '');
            node.dataset.sessId = session.sessId;

            var thumb = session.thumb || '';
            var artwork = thumb
                ? '<img src="' + esc(thumb) + '" loading="lazy" decoding="async" alt="">'
                : '<span class="session-art">' + icon('music') + '</span>';

            node.innerHTML =
                artwork +
                '<div class="session-copy">' +
                '<strong>' + esc(session.name) + '</strong>' +
                '<div class="track">' + esc(session.title || 'Sem música') + '</div>' +
                '<div class="state">' + (session.playing ? 'Tocando agora' : 'Pausado') + '</div>' +
                '</div>' +
                '<div class="session-tools">' +
                (session.focus ? '' : '<button class="btn btn--ghost" data-act="focus">Focar</button>') +
                '<button class="btn btn--danger" data-act="leave">Sair</button>' +
                '</div>';

            var focusButton = node.querySelector('[data-act="focus"]');

            if (focusButton) {
                focusButton.addEventListener('click', function () {
                    post('sessionsFocus', { sessId: session.sessId }).then(function (res) {
                        if (res === 'ok') {
                            toast('info', 'Agora controlando ' + session.name, 'Sessões');
                            refreshSessions();
                        }
                    });
                });
            }

            node.querySelector('[data-act="leave"]').addEventListener('click', function () {
                var isJam = session.kind === 'jam';

                post(isJam ? 'jamLeave' : 'sessionsLeave', isJam ? {} : { sessId: session.sessId }).then(function () {
                    toast('warning', isJam ? 'Você saiu da Jam.' : 'Você saiu da sessão.', 'Sessões');
                    if (isJam) { state.jam = null; renderJam(); }
                    refreshSessions();
                });
            });

            frag.appendChild(node);
        });

        $sessionsList.appendChild(frag);
    }

    // ---------------------------------------------------------------- jam
    function renderJam() {
        var jam = state.jam;

        el('jamIdle').hidden = !!jam;
        el('jamActive').hidden = !jam;
        el('jamState').textContent = jam ? 'ativa' : 'offline';
        el('jamDot').hidden = !jam;

        if (!jam) {
            el('jamMembers').innerHTML = '';
            return;
        }

        el('jamCode').textContent = jam.code;
        el('jamHost').textContent = jam.isHost
            ? 'você é o anfitrião'
            : 'anfitrião: ' + jam.hostName + (jam.canControl ? ' · você pode controlar' : ' · você é ouvinte');
        el('btnJamLeave').innerHTML = '<span>' + (jam.isHost ? 'Encerrar' : 'Sair') + '</span>';

        var members = el('jamMembers');
        members.innerHTML = '';

        (jam.members || []).forEach(function (member) {
            var row = document.createElement('div');
            row.className = 'cell';
            var role = member.isHost
                ? 'anfitrião'
                : ((member.canControl ? 'controla a Jam' : 'apenas ouvindo') +
                   (member.mode === 'own' ? ' · no próprio dispositivo' : ' · no dispositivo do anfitrião'));

            row.innerHTML =
                '<span class="cell-icon">' + icon('users') + '</span>' +
                '<div class="cell-copy"><strong>' + esc(member.name) + '</strong><span>' + role + '</span></div>' +
                (jam.isHost && !member.isHost
                    ? '<button class="btn btn--ghost jam-perm" data-allow="' + esc(member.passport) + '">' +
                      (member.canControl ? 'Remover controle' : 'Dar controle') + '</button>' +
                      '<button class="icon-btn" data-kick="' + esc(member.passport) + '">' + icon('close') + '</button>'
                    : '');

            row.addEventListener('click', function (event) {
                if (event.target.closest('[data-allow]')) {
                    post('jamAllow', { passport: member.passport, allowed: !member.canControl }).then(function (res) {
                        if (!res || !res.ok) toast('error', 'Não foi possível alterar a permissão.', 'Jam');
                    });
                    return;
                }

                if (!event.target.closest('[data-kick]')) return;
                post('jamKick', { passport: member.passport }).then(function (res) {
                    if (!res || !res.ok) toast('error', 'Não foi possível remover.', 'Jam');
                });
            });

            members.appendChild(row);
        });
    }

    el('btnJamCreate').addEventListener('click', function () {
        post('jamCreate').then(function (res) {
            if (!res || !res.ok) {
                toast('error', (res && res.message) || 'Não foi possível criar a Jam.', 'Jam');
                return;
            }
            state.jam = res.jam;
            renderJam();
            toast('success', 'Jam criada: ' + res.jam.code, 'Jam');
        });
    });

    el('btnJamJoin').addEventListener('click', function () {
        askSheet('Entrar numa Jam', 'Digite o código de 4 letras.', { label: 'JAM-XXXX', confirm: 'Continuar' })
            .then(function (code) {
                if (!code) return;

                chooseSheet('Onde você vai ouvir?', 'Código ' + code, [
                    { id: 'host', label: 'No dispositivo do anfitrião', sub: 'Ouça o som do carro ou palco dele', icon: 'share' },
                    { id: 'own', label: 'No meu dispositivo', sub: 'Seus fones ou o carro que você controla', icon: 'phones' }
                ]).then(function (mode) {
                    if (!mode) return;

                    post('jamJoin', { code: code, mode: mode }).then(function (res) {
                        if (!res || !res.ok) {
                            toast('error', (res && res.message) || 'Código inválido.', 'Jam');
                            return;
                        }
                        state.jam = res.jam;
                        state.jam.mode = mode;
                        renderJam();
                        toast('success', 'Você entrou na Jam de ' + res.jam.hostName, 'Jam');
                    });
                });
            });
    });

    el('btnJamCopy').addEventListener('click', function () {
        if (!state.jam) return;
        var text = state.jam.code;

        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(function () {
                toast('success', 'Código copiado.', 'Jam');
            }).catch(fallbackCopy);
        } else {
            fallbackCopy();
        }

        function fallbackCopy() {
            var area = document.createElement('textarea');
            area.value = text;
            document.body.appendChild(area);
            area.select();
            try { document.execCommand('copy'); } catch (e) { }
            area.remove();
            toast('success', 'Código copiado.', 'Jam');
        }
    });

    el('btnJamInvite').addEventListener('click', function () {
        if (!state.jam) return;

        post('nearbyPlayers').then(function (players) {
            if (!Array.isArray(players) || !players.length) {
                toast('warning', 'Ninguém por perto (10 m).', 'Jam');
                return;
            }

            chooseSheet('Convidar para a Jam', 'Só quem está por perto', players.map(function (player) {
                return { id: player.passport, label: player.name, sub: '#' + player.passport, icon: 'users' };
            })).then(function (passport) {
                if (passport == null) return;
                post('jamInvite', { passport: passport });
                toast('info', 'Convite enviado.', 'Jam');
            });
        });
    });

    el('btnJamLeave').addEventListener('click', function () {
        if (!state.jam) return;

        var action = state.jam.isHost ? 'jamEnd' : 'jamLeave';
        post(action).then(function () {
            state.jam = null;
            renderJam();
            toast('info', 'Jam encerrada.', 'Jam');
        });
    });

    // ---------------------------------------------------------------- mensagens do Lua
    function applyFocus(payload) {
        if (!payload) return;

        if (payload.state) {
            state.device = payload.state;
            state.playing = payload.state.playing === true;
            if (typeof payload.state.volume === 'number') state.volume = payload.state.volume;
        }

        paintTrack();
    }

    function applyBoot(boot) {
        if (!boot) return;

        state.booted = true;
        state.apiKey = boot.apiKey || '';
        state.soundCloudEnabled = !!(boot.soundCloud && boot.soundCloud.enabled);
        state.spotifyEnabled = !!(boot.spotify && boot.spotify.enabled);
        state.device = boot.state || state.device;
        state.playing = !!boot.state.playing;
        state.time = boot.state.time || 0;
        state.duration = boot.state.duration || 0;
        state.queue = boot.queue || [];
        state.index = boot.index || 0;
        state.repeat = boot.repeatMode || 0;
        state.shuffle = !!boot.shuffle;
        state.sessions = boot.sessions || [];
        state.jam = boot.jam || null;
        state.limits = boot.limits || state.limits;

        if (boot.volume) {
            state.localVolume = boot.volume.local;
            state.muted = boot.volume.muted;
        }

        if (typeof state.device.volume === 'number') state.volume = state.device.volume;

        paintTrack();
        paintProgress();

        post('playlists').then(function (list) {
            state.playlists = Array.isArray(list) ? list : [];
            renderPlaylists();
        });

        post('recent').then(function (list) {
            state.recent = Array.isArray(list) ? list : [];
            renderRecent();
        });

        renderSessions();
        renderJam();
    }

    window.addEventListener('message', function (event) {
        var msg = event.data;
        if (typeof msg === 'string') {
            try { msg = JSON.parse(msg); } catch (e) { return; }
        }
        if (!msg || !msg.type) return;

        switch (msg.type) {
            case 'visibility':
                if (msg.open) {
                    setOpen(true);
                    post('boot').then(applyBoot);
                } else {
                    setOpen(false);
                    hideLayer();
                    $menu.hidden = true;
                }
                break;

            case 'toast':
                toast(msg.kind || msg.toastType || 'info', msg.text, msg.title);
                break;

            case 'queue':
                applyQueue(msg);
                break;

            case 'progress':
                state.time = msg.time || 0;
                state.duration = msg.duration || 0;
                paintProgress();
                break;

            case 'focus':
                applyFocus(msg);
                break;

            case 'sessions':
                state.sessions = msg.list || [];
                renderSessions();
                break;

            case 'playlists':
                state.playlists = msg.list || [];
                renderPlaylists();
                break;

            case 'playlistTrack':
                patchPlaylistTrack(msg.id, msg.index, msg.song);
                break;

            case 'localVolume':
                state.localVolume = msg.local;
                state.muted = msg.muted;
                paintControls();
                break;

            case 'prompt':
                if (msg.text) {
                    el('promptText').textContent = msg.text;
                    $prompt.hidden = false;
                } else {
                    $prompt.hidden = true;
                }
                break;

            case 'jam':
                state.jam = msg.jam || null;
                renderJam();
                paintControls();
                break;

            case 'jamEvent':
                toast('info', msg.text, 'Jam');
                break;

            case 'jamPlayback':
                if (msg.playback) {
                    state.device.title = msg.playback.title || state.device.title;
                    state.device.thumb = msg.playback.thumb || state.device.thumb;
                    if (msg.action === 'play') state.playing = true;
                    if (msg.action === 'pause') state.playing = false;
                    if (msg.action === 'resume') state.playing = true;
                    paintTrack();
                }
                break;

            case 'range':
                el('rangeDot').hidden = !msg.out;
                el('rangeLabel').hidden = !msg.out;
                if (msg.out && msg.name) toast('warning', 'Sinal fraco com ' + msg.name, 'Bluetooth');
                break;
        }
    });

    // ---------------------------------------------------------------- teclado
    document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
            if (!$layer.hidden) { hideLayer(); return; }
            if (!$menu.hidden) { $menu.hidden = true; return; }
            closeUI();
            return;
        }

        var tag = (event.target.tagName || '').toLowerCase();
        if (tag === 'input' || tag === 'textarea') return;

        if (event.code === 'Space') {
            event.preventDefault();
            el('btnPlay').click();
        } else if (event.key === 'ArrowRight' && state.duration > 0) {
            post('control', { action: 'seek', time: Math.min(state.duration, state.time + 5) });
        } else if (event.key === 'ArrowLeft' && state.duration > 0) {
            post('control', { action: 'seek', time: Math.max(0, state.time - 5) });
        }
    });

    // ---------------------------------------------------------------- polling suave
    setInterval(function () {
        if ($shell.dataset.open !== 'true') return;
        if (state.view === 'bluetooth') refreshBluetooth();
    }, 5000);

    // handshake: pede o estado caso a abertura tenha acontecido antes do CEF subir
    post('ready');
})();

/* audio.js — motor de áudio do solis_sound (página DUI) */
(function () {
    'use strict';

    var HOST = (location.hostname || 'cfx-nui-solis_sound');
    var BASE = 'https://' + HOST + '/';

    var sounds = new Map();
    var muffledStates = new Map();
    var filterDisabled = new Set();
    var wiredElements = new WeakSet(); // mídias que já passaram pelo Web Audio
    var lastUrl = new Map();

    var listener = { x: -900000, y: -900000, z: -900000 };
    var allMuted = false;
    var audioCtx = null;

    // ---------- infra ----------
    function post(path, body) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.open('POST', BASE + path, true);
            xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.send(JSON.stringify(body || {}));
        } catch (e) { /* callback indisponível durante o shutdown */ }
    }

    function ctx() {
        if (!audioCtx) {
            var Ctor = window.AudioContext || window.webkitAudioContext;
            if (!Ctor) return null;
            audioCtx = new Ctor();
        }
        if (audioCtx.state === 'suspended') audioCtx.resume();
        return audioCtx;
    }

    function youtubeId(url) {
        if (!url) return '';
        var m = url.match(/(?:youtu\.be\/|[?&]v=|\/embed\/|\/shorts\/|\/live\/)([A-Za-z0-9_-]{11})/);
        return m ? m[1] : '';
    }

    function soundCloudUrl(url) {
        return !!url && /soundcloud\.com\//i.test(url);
    }

    // O player do YouTube mora dentro de um iframe (às vezes aninhado). Sem
    // descer nos iframes o createMediaElementSource nunca encontra o <video>
    // e o muffle vira só atenuação de volume — é o que o xsound faz no /som.
    function searchMediaInContent(win, depth) {
        if (!win || depth > 4) return null;

        try {
            var doc = win.document;
            if (!doc) return null;

            var direct = doc.querySelector('video, audio');
            if (direct) return direct;

            var frames = doc.querySelectorAll('iframe');
            for (var i = 0; i < frames.length; i++) {
                try {
                    var found = searchMediaInContent(frames[i].contentWindow, depth + 1);
                    if (found) return found;
                } catch (e) {
                    // iframe inacessível: ignora e continua
                }
            }
        } catch (e) {
            return null;
        }

        return null;
    }

    // ---------- YouTube ----------
    // 1) Config.Audio.YoutubePlayer preenchido = página em https (mata o 153).
    // 2) vazio = YT.Player local, que funciona só em ambientes com Referer.
    var ytApi = null;
    var ytPlayerUrl = '';
    var ytOrigin = '';

    function setYoutubePlayer(url) {
        if (typeof url !== 'string' || !/^https:\/\//i.test(url)) {
            ytPlayerUrl = '';
            ytOrigin = '';
            return;
        }

        ytPlayerUrl = url;
        try { ytOrigin = new URL(url).origin; } catch (e) { ytOrigin = ''; }
    }

    // ---------- SoundCloud ----------
    var scWidgetUrl = 'https://w.soundcloud.com/player/';
    var scApiPromise = null;

    function setSoundCloudWidget(url) {
        if (typeof url === 'string' && /^https:\/\//i.test(url)) scWidgetUrl = url;
    }

    function loadSoundCloudApi() {
        if (window.SC && window.SC.Widget) return Promise.resolve(window.SC.Widget);
        if (scApiPromise) return scApiPromise;

        scApiPromise = new Promise(function (resolve, reject) {
            var tag = document.createElement('script');
            tag.src = 'https://w.soundcloud.com/player/api.js';
            tag.async = true;
            tag.onload = function () {
                if (window.SC && window.SC.Widget) resolve(window.SC.Widget);
                else { scApiPromise = null; reject(new Error('sc api')); }
            };
            tag.onerror = function () { scApiPromise = null; reject(new Error('sc api')); };
            document.head.appendChild(tag);
        });

        return scApiPromise;
    }

    // hls.js toca os streams HLS do SoundCloud num <audio> da própria página.
    // Assim o elemento é CORS-clean e o grafo WebAudio (lowpass) funciona.
    var hlsPromise = null;
    function loadHls() {
        if (window.Hls) return Promise.resolve(window.Hls);
        if (hlsPromise) return hlsPromise;

        hlsPromise = new Promise(function (resolve, reject) {
            var tag = document.createElement('script');
            tag.src = 'hls.min.js';
            tag.async = true;
            tag.onload = function () {
                if (window.Hls) resolve(window.Hls);
                else { hlsPromise = null; reject(new Error('hls')); }
            };
            tag.onerror = function () { hlsPromise = null; reject(new Error('hls')); };
            document.head.appendChild(tag);
        });

        return hlsPromise;
    }


    function loadYoutubeApi() {
        if (window.YT && window.YT.Player) return Promise.resolve();
        if (ytApi) return ytApi;

        ytApi = new Promise(function (resolve) {
            var previous = window.onYouTubeIframeAPIReady;

            window.onYouTubeIframeAPIReady = function () {
                if (typeof previous === 'function') previous();
                resolve();
            };

            var tag = document.createElement('script');
            tag.src = 'https://www.youtube.com/iframe_api';
            tag.async = true;
            document.head.appendChild(tag);
        });

        return ytApi;
    }

    function distance(a, b) {
        var dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
        return Math.sqrt(dx * dx + dy * dy + dz * dz);
    }

    // ---------- Sound ----------
    function Sound(def) {
        this.id = def.id;
        this.url = def.url;
        this.volume = typeof def.vol === 'number' ? def.vol : 0.5;
        this.dynamic = def.dynamic === true;
        this.distance = typeof def.dist === 'number' ? def.dist : 1000;
        this.pos = { x: def.x || 0, y: def.y || 0, z: def.z || 0 };
        this.loop = def.loop === true;
        this.paused = def.paused === true;
        this.pendingSeek = typeof def.time === 'number' ? def.time : 0;

        this.el = null;
        this.iframe = null;
        this.yt = null;
        this.ytFrame = null;
        this.scWidget = null;
        this.scFrame = null;
        this.scPlaying = false;
        this.scPos = 0;
        this.scMode = null;      // 'pending' | 'direct' | 'widget'
        this.scFallback = null;  // timer que cai para o widget
        this.hls = null;         // instância hls.js do stream direto
        this.isYoutube = youtubeId(def.url) !== '';
        this.isSoundCloud = soundCloudUrl(def.url);
        this.noCors = def.noCors === true;

        this.graph = null;
        this.muffled = false;
        this.params = { cutoff: 260, resonance: 2.4, bassFreq: 95, bassGain: 10, bassQ: 1.7, smooth: 0.12 };
        this.filterRetry = null;
        this.ytState = 0;
        this.ytTime = 0;

        this.watch = null;
        this.silenceTicks = 0;
        this.lastCurrent = 0;
        this.timer = null;
        this.readySent = false;
        this.duration = 0;
    }

    Sound.prototype.spatialVolume = function () {
        if (!this.dynamic) return this.volume;

        var d = distance(listener, this.pos);
        if (d >= this.distance) return 0;

        var t = 1 - (d / this.distance);
        return this.volume * Math.pow(t, 1.2);
    };

    Sound.prototype.applyVolume = function () {
        var vol = this.spatialVolume();
        if (allMuted) vol = 0;
        vol = Math.max(0, Math.min(1, vol));

        if (this.el) {
            this.el.volume = vol;
        } else if (this.scWidget) {
            // A API do widget usa 0..100 (diferente do <audio>).
            try { this.scWidget.setVolume(Math.round(vol * 100)); } catch (e) { }
        } else if (this.yt && this.yt.setVolume) {
            this.yt.setVolume(Math.round(vol * 100));
        } else if (this.ytFrame) {
            this.ytCmd('vol', { value: vol * 100 });
        }
    };

    // ---------- DSP ----------
    // Localiza o elemento de mídia deste som. Para YouTube o <video> está dentro
    // do iframe do player (e pode estar aninhado); é a mesma busca usada pelo
    // xsound no /som, que é o que faz o lowpass funcionar lá.
    Sound.prototype.findMediaElement = function () {
        if (this.el) return this.el;
        if (!this.isYoutube && !this.isSoundCloud) return null;

        var windows = [];

        if (this.scFrame && this.scFrame.contentWindow) {
            windows.push(this.scFrame.contentWindow);
        }

        if (this.ytFrame && this.ytFrame.contentWindow) {
            windows.push(this.ytFrame.contentWindow);
        }

        if (this.iframe && this.iframe.querySelectorAll) {
            var frames = this.iframe.querySelectorAll('iframe');
            for (var i = 0; i < frames.length; i++) {
                if (frames[i].contentWindow) windows.push(frames[i].contentWindow);
            }
        }

        if (this.yt && typeof this.yt.getIframe === 'function') {
            try {
                var frame = this.yt.getIframe();
                if (frame && frame.contentWindow) windows.push(frame.contentWindow);
            } catch (e) {
                // player ainda não pronto
            }
        }

        for (var j = 0; j < windows.length; j++) {
            var found = searchMediaInContent(windows[j], 0);
            if (found) return found;
        }

        return null;
    };

    Sound.prototype.attachGraph = function (element) {
        element = element || this.findMediaElement();
        if (!element || this.graph || filterDisabled.has(this.id)) return false;

        // createMediaElementSource só pode ser chamado uma vez por elemento.
        // Se a cadeia foi liberada (fim de faixa, por exemplo), espera um
        // elemento novo em vez de tentar reconectar o antigo e desativar o filtro.
        if (wiredElements.has(element)) return false;

        var context = ctx();
        if (!context) return false;

        try {
            var src = context.createMediaElementSource(element);
            wiredElements.add(element);

            var peak = context.createBiquadFilter();
            peak.type = 'peaking';
            peak.frequency.value = this.params.bassFreq;
            peak.Q.value = this.params.bassQ;
            peak.gain.value = 0;

            var lp1 = context.createBiquadFilter();
            lp1.type = 'lowpass';
            lp1.frequency.value = 20000;
            lp1.Q.value = this.params.resonance;

            var lp2 = context.createBiquadFilter();
            lp2.type = 'lowpass';
            lp2.frequency.value = 20000;
            lp2.Q.value = 0.7;

            var analyser = context.createAnalyser();
            analyser.fftSize = 1024;

            src.connect(peak);
            peak.connect(lp1);
            lp1.connect(lp2);
            lp2.connect(analyser);
            analyser.connect(context.destination);

            this.graph = { src: src, peak: peak, lp1: lp1, lp2: lp2, analyser: analyser, element: element };

            this.updateFilter();
            this.startWatch();
            return true;
        } catch (e) {
            // Elemento já conectado ou Web Audio indisponível: segue sem filtro.
            console.log('[solis_sound] Web Audio LPF:', e);
            filterDisabled.add(this.id);
            return false;
        }
    };

    Sound.prototype.releaseGraph = function () {
        this.cancelFilterRetry();
        this.stopWatch();

        if (this.graph) {
            ['src', 'peak', 'lp1', 'lp2', 'analyser'].forEach(function (key) {
                var node = this.graph[key];
                if (node && node.disconnect) { try { node.disconnect(); } catch (e) { } }
            }, this);
        }

        this.graph = null;
    };

    // O elemento (principalmente o <video> do YouTube) pode demorar a existir.
    // Pedir o filtro uma única vez antes dele aparecer era o que deixava o
    // muffle sem efeito. A retry cobre a criação do iframe/player.
    Sound.prototype.scheduleFilterRetry = function () {
        if (this.filterRetry) return;

        var self = this;
        var attempts = 0;

        this.filterRetry = setInterval(function () {
            attempts++;

            var element = self.findMediaElement();
            if (element || attempts >= 40) {
                self.cancelFilterRetry();
                if (element) self.applyAudioFilter();
            }
        }, 250);
    };

    Sound.prototype.cancelFilterRetry = function () {
        if (this.filterRetry) {
            clearInterval(this.filterRetry);
            this.filterRetry = null;
        }
    };

    Sound.prototype.applyAudioFilter = function () {
        if (filterDisabled.has(this.id)) {
            this.cancelFilterRetry();
            return;
        }

        var element = this.findMediaElement();

        if (!element) {
            this.scheduleFilterRetry();
            return;
        }

        this.cancelFilterRetry();

        // Elemento novo (troca de faixa / recriação do player): a cadeia antiga
        // não serve mais e precisa ser desligada antes de criar a nova.
        if (!this.graph || this.graph.element !== element) {
            this.releaseGraph();
            if (!this.attachGraph(element)) return;
        }

        var context = ctx();
        if (context && context.state === 'suspended') context.resume();

        this.updateFilter();
    };

    Sound.prototype.updateFilter = function () {
        if (!this.graph) return;

        var context = ctx();
        if (!context) return;

        var now = context.currentTime;
        var smooth = this.params.smooth || 0.12;
        var g = this.graph;

        g.peak.frequency.setTargetAtTime(this.params.bassFreq, now, smooth);
        g.peak.Q.setTargetAtTime(this.params.bassQ, now, smooth);
        g.lp1.Q.setTargetAtTime(this.params.resonance, now, smooth);

        if (this.muffled) {
            g.peak.gain.setTargetAtTime(this.params.bassGain, now, smooth);
            g.lp1.frequency.setTargetAtTime(this.params.cutoff, now, smooth);
            g.lp2.frequency.setTargetAtTime(this.params.cutoff, now, smooth);
        } else {
            g.peak.gain.setTargetAtTime(0, now, smooth);
            g.lp1.frequency.setTargetAtTime(20000, now, smooth);
            g.lp2.frequency.setTargetAtTime(20000, now, smooth);
        }
    };

    // Estado de reprodução sem depender de <audio>: no YouTube a leitura vem
    // do YT.Player local ou dos eventos repassados pela página remota.
    Sound.prototype.playback = function () {
        if (this.el) {
            return { playing: !this.el.paused, time: this.el.currentTime || 0 };
        }

        // O widget não tem leitura síncrona; os eventos PLAY/PAUSE/PLAY_PROGRESS
        // mantêm esse cache atualizado para o watchdog do filtro.
        if (this.isSoundCloud) {
            return { playing: this.scPlaying, time: this.scPos };
        }

        if (this.yt && typeof this.yt.getPlayerState === 'function') {
            var state = 0;
            var time = 0;

            try { state = this.yt.getPlayerState(); } catch (e) { return null; }

            if (typeof this.yt.getCurrentTime === 'function') {
                try { time = this.yt.getCurrentTime() || 0; } catch (e) { }
            }

            return { playing: state === 1 || state === 3, time: time };
        }

        return { playing: this.ytState === 1 || this.ytState === 3, time: this.ytTime || 0 };
    };

    // Watchdog: se o filtro entrega silêncio digital com a mídia avançando,
    // o roteamento por Web Audio é descartado e a faixa volta limpa.
    Sound.prototype.startWatch = function () {
        if (this.watch || !this.graph) return;

        var self = this;

        this.watch = setInterval(function () {
            if (!self.graph || !self.graph.analyser) return;

            var playback = self.playback();
            if (!playback || !playback.playing) { self.silenceTicks = 0; return; }

            // Tem que ser o volume REALMENTE aplicado: um som dinâmico longe do
            // ouvinte roda com volume ~0, e olhar self.volume aqui fazia o
            // watchdog achar que o filtro havia silenciado e derrubar o LPF do
            // carro para sempre (o id do som não muda).
            var audible = self.el ? self.el.volume : self.spatialVolume();
            if (allMuted) audible = 0;
            if (!audible || audible < 0.08) { self.silenceTicks = 0; return; }

            var data = new Uint8Array(self.graph.analyser.fftSize);
            self.graph.analyser.getByteTimeDomainData(data);

            var sum = 0;
            for (var i = 0; i < data.length; i++) {
                var v = (data[i] - 128) / 128;
                sum += v * v;
            }
            var rms = Math.sqrt(sum / data.length);

            // Buffering/pausa também dá RMS ~0: só conta silêncio com o tempo
            // da mídia avançando, como no xsound.
            var progressed = Math.abs(playback.time - self.lastCurrent) > 0.001;
            self.lastCurrent = playback.time;

            if (rms < 0.0005 && progressed) self.silenceTicks++;
            else self.silenceTicks = 0;

            if (self.silenceTicks >= 8) self.dropFilter();
        }, 500);
    };

    Sound.prototype.stopWatch = function () {
        if (this.watch) {
            clearInterval(this.watch);
            this.watch = null;
        }
        this.silenceTicks = 0;
    };

    Sound.prototype.dropFilter = function () {
        this.stopWatch();
        filterDisabled.add(this.id);
        this.releaseGraph();
        this.rebuild(true);
    };

    // ---------- ciclo de vida ----------
    Sound.prototype.create = function () {
        if (this.isYoutube) { this.createYoutube(); return; }
        if (this.isSoundCloud) { this.createSoundCloud(); return; }
        this.createHtml5(this.url);
    };

    // Caminho comum de mídia hospedada: <audio> com CORS, grafo DSP e retries.
    // O SoundCloud direto reusa esta função após resolver o stream no servidor.
    Sound.prototype.createHtml5 = function (url, deferPlay, attach) {
        var self = this;

        var el = new Audio();
        el.preload = 'auto';
        el.loop = this.loop;
        el.volume = 0;

        // Sem crossOrigin a mídia de outra origem fica "tainted": o grafo do
        // Web Audio entrega silêncio digital (RMS 0) e o LPF nunca soa. Com
        // crossOrigin + CORS do servidor o filtro funciona de verdade.
        if (!this.noCors) el.crossOrigin = 'anonymous';

        if (typeof attach !== 'function') el.src = url || this.url;

        el.addEventListener('loadedmetadata', function () {
            self.duration = isFinite(el.duration) ? el.duration : 0;
            if (self.duration > 0) post('audio/duration', { id: self.id, time: self.duration });
            if (self.pendingSeek > 0.5) {
                try { el.currentTime = self.pendingSeek; } catch (e) { }
            }
        });

        el.addEventListener('canplay', function () {
            if (!self.readySent) {
                self.readySent = true;
                post('audio/ready', { id: self.id });
            }
            self.applyAudioFilter();
        });

        el.addEventListener('ended', function () {
            self.releaseGraph();
            post('audio/ended', { id: self.id });
        });

        el.addEventListener('error', function () {
            // SoundCloud direto: erro de mídia cai para o widget em vez de
            // tentar o mesmo stream de novo (evita loop de rebuild).
            if (self.isSoundCloud && self.scMode === 'direct') {
                self.scUseWidget();
                return;
            }

            // servidor sem CORS: reabre sem crossOrigin para o som tocar
            // (sem filtro, porque sem CORS o grafo só produziria silêncio)
            if (!self.noCors) {
                self.noCors = true;
                filterDisabled.add(self.id);
                self.rebuild(true);
                return;
            }

            post('audio/failed', { id: self.id, message: 'media error' });
        });

        this.el = el;
        this.applyVolume();

        if (typeof attach === 'function') {
            // HLS: o <audio> só toca depois que o manifesto é analisado.
            attach(el, function () {
                if (!self.paused && !deferPlay) self.play();
            });
        } else if (!this.paused && !deferPlay) {
            this.play();
        }
        return el;
    };

    // SoundCloud: tenta primeiro o stream direto num <audio> nosso, com CORS —
    // é o único jeito de o grafo WebAudio (lowpass do carro) funcionar. O widget
    // oficial é cross-origin e só permite atenuação de volume; fica como fallback.
    Sound.prototype.createSoundCloud = function () {
        var self = this;
        this.scMode = 'pending';

        this.scFallback = setTimeout(function () {
            self.scFallback = null;
            self.scUseWidget();
        }, 6000);

        post('audio/scStream', { id: this.id, url: this.url });
    };

    // Resposta do servidor com a URL do stream (HLS ou MP3).
    Sound.prototype.onScStream = function (result) {
        if (this.scMode !== 'pending' || !result || !result.url) return;
        if (this.scFallback) { clearTimeout(this.scFallback); this.scFallback = null; }
        this.scMode = 'direct';

        // Uma tentativa anterior com widget pode ter desligado o filtro.
        filterDisabled.delete(this.id);

        var self = this;
        var streamUrl = result.url;

        if (result.kind === 'hls') {
            loadHls().then(function (Hls) {
                if (self.scMode !== 'direct' || self.el) return;

                self.createHtml5(streamUrl, false, function (el, onReady) {
                    var hls = new Hls({ enableWorker: false });
                    self.hls = hls;

                    hls.on(Hls.Events.MANIFEST_PARSED, function () { onReady(); });
                    hls.on(Hls.Events.ERROR, function (evt, data) {
                        if (!data || !data.fatal) return;
                        try { hls.destroy(); } catch (e) { }
                        if (self.hls === hls) self.hls = null;
                        self.scUseWidget();
                    });

                    hls.loadSource(streamUrl);
                    hls.attachMedia(el);
                });
            }).catch(function () {
                self.scUseWidget();
            });
        } else {
            this.createHtml5(streamUrl);
        }
    };

    // Último recurso: widget oficial. Toca, mas sem DSP (o lowpass não alcança
    // o áudio dentro do iframe cross-origin).
    Sound.prototype.scUseWidget = function () {
        if (this.scWidget || this.iframe) return;
        if (this.scFallback) { clearTimeout(this.scFallback); this.scFallback = null; }

        if (this.scMode === 'direct') {
            if (this.hls) { try { this.hls.destroy(); } catch (e) { } this.hls = null; }
            if (this.el) {
                try { this.el.pause(); } catch (e) { }
                this.el.removeAttribute('src');
                try { this.el.load(); } catch (e) { }
                this.el = null;
            }
            this.releaseGraph();
        }
        this.scMode = 'widget';
        this.createSoundCloudWidget();
    };

    Sound.prototype.createSoundCloudWidget = function () {
        var self = this;

        var host = document.createElement('div');
        host.style.cssText = 'position:fixed;left:0;top:0;width:350px;height:240px;overflow:hidden;opacity:0.01;pointer-events:none;';
        document.body.appendChild(host);
        this.iframe = host;

        var frame = document.createElement('iframe');
        frame.setAttribute('allow', 'autoplay');
        frame.style.cssText = 'width:100%;height:100%;border:0;';
        frame.src = scWidgetUrl
            + '?url=' + encodeURIComponent(this.url)
            + '&auto_play=' + (this.paused ? 'false' : 'true')
            + '&show_comments=false'
            + '&hide_related=true';

        frame.addEventListener('load', function () {
            self.applyAudioFilter();
        });

        host.appendChild(frame);
        this.scFrame = frame;

        loadSoundCloudApi().then(function (Widget) {
            if (!frame.parentNode) return;

            var widget = Widget(frame);
            self.scWidget = widget;

            // As constantes de evento vivem no CONSTRUTOR (SC.Widget.Events),
            // não na instância. Com `widget.Events` todos os binds recebiam
            // `undefined`: READY/duração/volume/progresso nunca disparavam.
            var Events = Widget.Events || (window.SC && window.SC.Widget && window.SC.Widget.Events) || {
                READY: 'ready', PLAY: 'play', PAUSE: 'pause', PLAY_PROGRESS: 'playProgress',
                SEEK: 'seek', FINISH: 'finish', ERROR: 'error'
            };

            // O widget nasce em 100%, independente do nosso volume. Aplica já,
            // sem esperar o READY (que pode demorar ou não chegar).
            self.applyVolume();

            // Fallback de duração/posição para faixas em que o READY não vem.
            var probes = 0;
            self.scProbe = setInterval(function () {
                if (!frame.parentNode || self.scWidget !== widget) {
                    clearInterval(self.scProbe);
                    self.scProbe = null;
                    return;
                }

                try {
                    widget.getDuration(function (ms) {
                        var duration = (ms || 0) / 1000;
                        if (duration > 0 && Math.abs(duration - self.duration) > 1) {
                            self.duration = duration;
                            post('audio/duration', { id: self.id, time: duration });
                        }
                    });
                } catch (e) { }

                try {
                    widget.getPosition(function (ms) {
                        if (typeof ms === 'number') self.scPos = ms / 1000;
                    });
                } catch (e) { }

                if (++probes >= 20) { clearInterval(self.scProbe); self.scProbe = null; }
            }, 500);

            widget.bind(Events.READY, function () {
                self.scPlaying = !self.paused;
                self.applyVolume();

                if (self.pendingSeek > 0.5) {
                    try { widget.seekTo(self.pendingSeek * 1000); } catch (e) { }
                }
                if (self.paused) { try { widget.pause(); } catch (e) { } }
                else { try { widget.play(); } catch (e) { } }

                try {
                    widget.getDuration(function (ms) {
                        var duration = (ms || 0) / 1000;
                        if (duration > 0 && Math.abs(duration - self.duration) > 1) {
                            self.duration = duration;
                            post('audio/duration', { id: self.id, time: duration });
                        }
                    });
                } catch (e) { }

                if (!self.readySent) {
                    self.readySent = true;
                    post('audio/ready', { id: self.id });
                }

                self.applyAudioFilter();
            });

            widget.bind(Events.PLAY, function () {
                self.scPlaying = true;
                self.endSent = false;
                if (!self.readySent) {
                    self.readySent = true;
                    post('audio/ready', { id: self.id });
                }
            });

            widget.bind(Events.PAUSE, function () { self.scPlaying = false; });

            widget.bind(Events.PLAY_PROGRESS, function (data) {
                if (data && typeof data.currentPosition === 'number') {
                    self.scPos = data.currentPosition / 1000;
                }
            });

            widget.bind(Events.SEEK, function (data) {
                if (data && typeof data.currentPosition === 'number') {
                    self.scPos = data.currentPosition / 1000;
                }
            });

            widget.bind(Events.FINISH, function () {
                self.scPlaying = false;
                self.releaseGraph();

                if (self.endSent) return;
                self.endSent = true;

                if (self.loop) {
                    self.scPos = 0;
                    try { widget.seekTo(0); widget.play(); } catch (e) { }
                } else {
                    post('audio/ended', { id: self.id });
                }
            });

            widget.bind(Events.ERROR, function (data) {
                post('audio/failed', {
                    id: self.id,
                    message: 'soundcloud ' + ((data && data.message) || 'error')
                });
            });
        }).catch(function () {
            post('audio/failed', { id: self.id, message: 'soundcloud widget indisponível' });
        });
    };

    Sound.prototype.createYoutube = function () {
        if (ytPlayerUrl) { this.createYoutubeRemote(); return; }
        this.createYoutubeLocal();
    };

    Sound.prototype.createYoutubeLocal = function () {
        var self = this;

        var host = document.createElement('div');
        host.style.cssText = 'position:fixed;left:0;top:0;width:320px;height:180px;overflow:hidden;opacity:0.01;pointer-events:none;';
        host.innerHTML = '<div></div>';
        document.body.appendChild(host);
        this.iframe = host;

        loadYoutubeApi().then(function () {
            if (!host.parentNode || !window.YT || !window.YT.Player) return;

            var player = new window.YT.Player(host.firstChild, {
                videoId: youtubeId(self.url),
                host: 'https://www.youtube.com',
                width: '100%',
                height: '100%',
                playerVars: {
                    autoplay: 1,
                    controls: 0,
                    disablekb: 1,
                    fs: 0,
                    rel: 0,
                    showinfo: 0,
                    iv_load_policy: 3,
                    // `origin` é a identificação que o YouTube aceita quando a página
                    // não tem Referer (erro 153 no CEF do FiveM). É o parâmetro que o
                    // xsound sempre usou e por isso ele toca sem erro.
                    origin: 'https://www.youtube.com/'
                },
                events: {
                    onReady: function () {
                        // this.yt só existe pronto: applyVolume antes disso seria perdido
                        self.yt = player;

                        player.unMute();
                        if (self.pendingSeek > 0.5) player.seekTo(self.pendingSeek, true);
                        self.applyVolume();
                        if (self.paused) player.pauseVideo(); else player.playVideo();

                        // O <video> do embed só existe aqui: é quando a cadeia
                        // DSP pode ser montada (o /som faz o mesmo no isReady).
                        self.applyAudioFilter();

                        // com origin=youtube.com o embed pode não emitir onStateChange;
                        // ler o estado direto do player cobre duração e fim de faixa.
                        self.stopTimer();
                        self.timer = setInterval(function () { self.pollYoutube(); }, 1000);
                    },

                    onStateChange: function (event) {
                        if (event.data === 1) self.pollYoutube(1);
                        else if (event.data === 0) self.pollYoutube(0);
                    },

                    onError: function (event) {
                        // 150 = dono desativou o embed, 101/100 = vídeo inválido
                        post('audio/failed', { id: self.id, message: 'youtube ' + event.data });
                    }
                }
            });
        }).catch(function () {
            post('audio/failed', { id: self.id, message: 'youtube api indisponível' });
        });
    };

    Sound.prototype.stopTimer = function () {
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = null;
        }
    };

    // Leitura periódica do player do YouTube: estado, duração e fim de faixa.
    Sound.prototype.pollYoutube = function (knownState) {
        var player = this.yt;
        if (!player) return;

        var state = knownState;
        var duration = 0;

        try {
            if (state === undefined && player.getPlayerState) state = player.getPlayerState();
            if (player.getDuration) duration = player.getDuration() || 0;
        } catch (e) {
            return;
        }

        if (state === 1 || state === 3) {
            this.endSent = false;

            if (!this.readySent) {
                this.readySent = true;
                post('audio/ready', { id: this.id });
            }
        }

        if (duration > 0 && Math.abs(duration - this.duration) > 1) {
            this.duration = duration;
            post('audio/duration', { id: this.id, time: duration });
        }

        if (state !== 0 || this.endSent) return;

        this.endSent = true;

        if (this.loop) {
            try { player.seekTo(0, true); player.playVideo(); } catch (e) { }
        } else {
            this.stopTimer();
            post('audio/ended', { id: this.id });
        }
    };

    // Página do player hospedada em https: a embed chega ao YouTube com um
    // Referer válido, coisa que o cfx-nui não consegue enviar (erro 153).
    Sound.prototype.createYoutubeRemote = function () {
        var self = this;

        var host = document.createElement('div');
        host.style.cssText = 'position:fixed;left:0;top:0;width:320px;height:180px;overflow:hidden;opacity:0.01;pointer-events:none;';
        document.body.appendChild(host);

        var frame = document.createElement('iframe');
        frame.setAttribute('allow', 'autoplay; encrypted-media');
        frame.setAttribute('referrerpolicy', 'strict-origin-when-cross-origin');
        frame.style.cssText = 'width:100%;height:100%;border:0;';

        // mesmos parâmetros da página do worker (mew_tv): v, t, vol, autoplay
        var separator = ytPlayerUrl.indexOf('?') === -1 ? '?' : '&';
        var start = this.pendingSeek > 0.5 ? '&t=' + Math.floor(this.pendingSeek) : '';
        var vol = Math.round(this.spatialVolume() * (allMuted ? 0 : 1) * 100);

        frame.src = ytPlayerUrl + separator
            + 'v=' + encodeURIComponent(youtubeId(this.url))
            + '&s=' + encodeURIComponent(this.id)
            + '&autoplay=1'
            + '&vol=' + vol
            + start;

        // a página guarda os comandos até o player dela ficar pronto
        frame.addEventListener('load', function () {
            self.applyVolume();
            if (self.pendingSeek > 0.5) self.ytCmd('seek', { time: self.pendingSeek });
            self.ytCmd(self.paused ? 'pause' : 'play');
            self.applyAudioFilter();
        });

        // a página https não respondeu: volta para o player local em vez de
        // deixar a faixa muda
        this.ytWatchdog = setTimeout(function () {
            if (self.ytReady || !self.ytFrame) return;
            self.destroy();
            self.createYoutubeLocal();
        }, 9000);

        host.appendChild(frame);
        this.iframe = host;
        this.ytFrame = frame;
    };

    // `action` é o formato que a página do worker já entende; `t`/`id`/`op`
    // seguem para a player.html que também pode ser hospedada.
    var YT_ACTION = { play: 'resume', pause: 'pause', seek: 'seek', vol: 'volume' };

    Sound.prototype.ytCmd = function (op, extra) {
        if (!this.ytFrame) return;

        var msg = { t: 'yt', id: this.id, op: op, action: YT_ACTION[op] || op };
        if (extra) { for (var key in extra) msg[key] = extra[key]; }

        if (op === 'play') this.endSent = false;

        // targetOrigin não serve aqui: o CEF entrega a página do recurso como
        // nui://... e o postMessage com https://cfx-nui-... lançaria DOMException.
        // A validação fica do lado de quem recebe (id + event.source).
        try { this.ytFrame.contentWindow.postMessage(msg, '*'); } catch (e) { }
    };

    Sound.prototype.play = function (fromTime) {
        var at = typeof fromTime === 'number' ? fromTime : this.pendingSeek;

        if (this.el) {
            if (at > 0.5) {
                try { this.el.currentTime = at; } catch (e) { }
            }

            var promise = this.el.play();
            if (promise && promise.catch) {
                var self = this;
                promise.catch(function () { self.pendingSeek = at; });
            }
        } else if (this.scWidget) {
            if (at > 0.5) { try { this.scWidget.seekTo(at * 1000); } catch (e) { } }
            try { this.scWidget.play(); } catch (e) { }
        } else if (this.yt) {
            if (at > 0.5) this.yt.seekTo(at, true);
            this.yt.playVideo();
        } else if (this.ytFrame) {
            if (at > 0.5) this.ytCmd('seek', { time: at });
            this.ytCmd('play');
        }
    };

    Sound.prototype.pause = function () {
        this.paused = true;
        if (this.el) this.el.pause();
        else if (this.scWidget) { try { this.scWidget.pause(); } catch (e) { } }
        else if (this.yt && this.yt.pauseVideo) this.yt.pauseVideo();
        else if (this.ytFrame) this.ytCmd('pause');
    };

    Sound.prototype.resume = function () {
        this.paused = false;
        if (this.el) this.el.play();
        else if (this.scWidget) { try { this.scWidget.play(); } catch (e) { } }
        else if (this.yt && this.yt.playVideo) this.yt.playVideo();
        else if (this.ytFrame) this.ytCmd('play');
    };

    Sound.prototype.seek = function (time) {
        this.pendingSeek = time;
        if (this.el && this.el.readyState >= 1) {
            try { this.el.currentTime = time; } catch (e) { this.pendingSeek = time; }
        } else if (this.scWidget) {
            try { this.scWidget.seekTo(time * 1000); } catch (e) { }
        } else if (this.yt && this.yt.seekTo) {
            this.yt.seekTo(time, true);
        } else if (this.ytFrame) {
            this.ytCmd('seek', { time: time });
        }
    };

    Sound.prototype.setMuffle = function (muffled, params) {
        this.muffled = muffled === true;

        if (params && typeof params === 'object') {
            if (typeof params.cutoff === 'number') this.params.cutoff = params.cutoff;
            if (typeof params.resonance === 'number') this.params.resonance = params.resonance;
            if (typeof params.bassFreq === 'number') this.params.bassFreq = params.bassFreq;
            if (typeof params.bassGain === 'number') this.params.bassGain = params.bassGain;
            if (typeof params.bassQ === 'number') this.params.bassQ = params.bassQ;
            if (typeof params.smooth === 'number') this.params.smooth = params.smooth;
        }

        // Só trocar os parâmetros não cria a cadeia: em YouTube ela ainda pode
        // não existir. applyAudioFilter monta (ou reatribui) o grafo e reaplica.
        this.applyAudioFilter();
    };

    // Recria a mídia preservando posição e volume (usado após falha do filtro).
    Sound.prototype.rebuild = function (keepPosition) {
        var time = 0;
        try {
            var playback = this.playback();
            if (keepPosition && playback) time = playback.time || 0;
        } catch (e) { time = 0; }

        var volume = this.volume;
        var paused = this.paused;
        var id = this.id;
        var url = this.url;
        var dynamic = this.dynamic;
        var dist = this.distance;
        var pos = this.pos;
        var loop = this.loop;
        var noCors = this.noCors;

        this.destroy();

        var fresh = new Sound({ id: id, url: url, vol: volume, dynamic: dynamic, dist: dist, x: pos.x, y: pos.y, z: pos.z, loop: loop, noCors: noCors, time: keepPosition ? time : 0 });
        fresh.paused = paused;
        fresh.muffled = this.muffled;
        fresh.params = this.params;
        sounds.set(id, fresh);
        fresh.create();

        var stored = muffledStates.get(id);
        if (stored) fresh.setMuffle(stored.muffled, stored.params);
    };

    Sound.prototype.destroy = function () {
        this.stopWatch();
        this.releaseGraph();

        this.stopTimer();

        if (this.scFallback) {
            clearTimeout(this.scFallback);
            this.scFallback = null;
        }

        if (this.hls) {
            try { this.hls.destroy(); } catch (e) { }
            this.hls = null;
        }

        if (this.ytWatchdog) {
            clearTimeout(this.ytWatchdog);
            this.ytWatchdog = null;
        }

        if (this.el) {
            try { this.el.pause(); } catch (e) { }
            this.el.removeAttribute('src');
            try { this.el.load(); } catch (e) { }
            this.el = null;
        }

        if (this.scProbe) {
            clearInterval(this.scProbe);
            this.scProbe = null;
        }

        if (this.scWidget) {
            try { this.scWidget.pause(); } catch (e) { }
            try { if (this.scWidget.unbindAll) this.scWidget.unbindAll(); } catch (e) { }
            this.scWidget = null;
        }
        this.scFrame = null;

        if (this.yt) {
            try { if (this.yt.stopVideo) this.yt.stopVideo(); } catch (e) { }
            try { if (this.yt.destroy) this.yt.destroy(); } catch (e) { }
            this.yt = null;
        }

        this.ytFrame = null;

        if (this.iframe) {
            var frame = this.iframe;
            this.iframe = null;
            try { frame.innerHTML = ''; } catch (e) { }
            setTimeout(function () { frame.remove(); }, 120);
        }
    };

    // ---------- mensagens do Lua ----------
    function onPlay(message) {
        var existing = sounds.get(message.id);

        // Sempre recria: manter o Sound antigo quando a URL é igual deixa o
        // player preso na faixa anterior (o xSound faz o mesmo). O `time` da
        // mensagem repõe a posição correta no novo objeto.
        if (existing) existing.destroy();

        // Um URL novo pode ser filtrável: libera a tentativa anterior.
        if (lastUrl.get(message.id) !== message.url) {
            lastUrl.set(message.id, message.url);
            filterDisabled.delete(message.id);
        }

        var sound = new Sound(message);
        sounds.set(message.id, sound);
        sound.create();

        var stored = muffledStates.get(message.id);
        if (stored) sound.setMuffle(stored.muffled, stored.params);
    }

    function onMessage(event) {
        var data = event.data;
        if (typeof data === 'string') {
            try { data = JSON.parse(data); } catch (e) { return; }
        }
        if (!data || !data.t) return;

        var sound = data.id ? sounds.get(data.id) : null;

        switch (data.t) {
            case 'play':
                onPlay(data);
                break;

            case 'scStream':
                if (sound) sound.onScStream(data.result);
                break;

            case 'scStreamFailed':
                if (sound && sound.isSoundCloud) sound.scUseWidget();
                break;

            case 'stop':
                if (sound) {
                    sound.destroy();
                    sounds.delete(data.id);
                }
                muffledStates.delete(data.id);
                break;

            case 'pause':
                if (sound) sound.pause();
                break;

            case 'resume':
                if (sound) sound.resume();
                break;

            case 'seek':
                if (sound) sound.seek(data.time);
                break;

            case 'volume':
                if (sound) { sound.volume = data.vol; sound.applyVolume(); }
                break;

            case 'dist':
                if (sound) { sound.distance = data.dist; sound.applyVolume(); }
                break;

            case 'pos':
                if (sound) { sound.pos = { x: data.x, y: data.y, z: data.z }; sound.applyVolume(); }
                break;

            case 'muffle':
                muffledStates.set(data.id, { muffled: data.muffled, params: data.params });
                if (sound) sound.setMuffle(data.muffled, data.params);
                break;

            case 'listener':
                listener = { x: data.x, y: data.y, z: data.z };
                sounds.forEach(function (item) {
                    if (item.dynamic) item.applyVolume();
                });
                break;

            case 'config':
                setYoutubePlayer(data.youtubePlayer);
                setSoundCloudWidget(data.soundCloudWidget);
                break;

            case 'muteAll':
                allMuted = true;
                sounds.forEach(function (item) { item.applyVolume(); });
                break;

            case 'unmuteAll':
                allMuted = false;
                sounds.forEach(function (item) { item.applyVolume(); });
                break;
        }
    }

    // Estado do player remoto. Duas fontes: a player.html emite { ev:'state' },
    // e a página do worker repassa os eventos crus do embed ({ event:'onStateChange' }).
    function applyYoutubeState(sound, state, duration, time) {
        // Usado pelo watchdog do filtro: sem o tempo da mídia não dá para
        // distinguir silêncio digital de buffering no player remoto.
        if (typeof state === 'number') sound.ytState = state;
        if (typeof time === 'number') sound.ytTime = time;

        if (state === 1 || state === 3) {
            if (!sound.readySent) {
                sound.readySent = true;
                post('audio/ready', { id: sound.id });
            }
            sound.endSent = false;
        }

        if (duration > 0 && Math.abs(duration - sound.duration) > 1) {
            sound.duration = duration;
            post('audio/duration', { id: sound.id, time: duration });
        }

        // 0 = fim; o worker pode mandar isso em onStateChange e em infoDelivery
        if (state === 0) {
            if (sound.endSent) return;
            sound.endSent = true;

            if (sound.loop) {
                sound.ytCmd('seek', { time: 0 });
                sound.ytCmd('play');
            } else {
                post('audio/ended', { id: sound.id });
            }
        }
    }

    window.addEventListener('message', function (event) {
        var data = event.data;
        if (typeof data === 'string') {
            try { data = JSON.parse(data); } catch (e) { return; }
        }
        if (!data) return;

        var sound = null;
        if (data.t === 'yt' && data.id) sound = sounds.get(data.id);
        else if (data.solis) sound = sounds.get(data.solis);

        if (!sound || !sound.ytFrame) return;

        // origem não é confiável aqui (o CEF pode servir a página como nui://);
        // a janela remetente tem que ser exatamente o iframe deste som.
        if (event.source !== sound.ytFrame.contentWindow) return;

        sound.ytReady = true;

        if (data.t === 'yt') {
            if (data.ev === 'error') {
                post('audio/failed', { id: sound.id, message: 'youtube ' + data.code });
                return;
            }

            if (data.ev === 'state') applyYoutubeState(sound, data.state, data.duration || 0, data.currentTime);
            return;
        }

        if (data.event === 'onStateChange') {
            applyYoutubeState(sound, data.info, sound.duration, data.currentTime);
        } else if ((data.event === 'infoDelivery' || data.event === 'initialDelivery') && data.info) {
            if (typeof data.info.currentTime === 'number') sound.ytTime = data.info.currentTime;

            if (typeof data.info.playerState === 'number') {
                applyYoutubeState(sound, data.info.playerState, data.info.duration || 0, data.info.currentTime);
            } else if (data.info.duration > 0 && Math.abs(data.info.duration - sound.duration) > 1) {
                sound.duration = data.info.duration;
                post('audio/duration', { id: sound.id, time: data.info.duration });
            }
        }
    });

    window.addEventListener('message', onMessage);

    // CEF pode bloquear o primeiro play antes de uma interação; a primeira
    // mensagem de posição vinda do jogo já libera o contexto.
    document.addEventListener('click', function () {
        if (audioCtx && audioCtx.state === 'suspended') audioCtx.resume();
    });

    post('audio/ping', { boot: true, origin: location.href });
    setInterval(function () { post('audio/ping', {}); }, 3000);
})();

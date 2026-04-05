import { getPageMode } from '../lib/page-mode.js';

if (getPageMode() !== 'demo') {
    console.warn('[demo-runtime] loaded outside demo mode');
}

const DEMO_SCENARIOS = {
    what_ahead: {
        user: '前面有什么？',
        assistant: '前方两步是开阔通道，十一点方向有一张椅子，继续直行。',
    },
    find_elevator: {
        user: '带我找电梯。',
        assistant: '两点钟方向约四米是电梯厅，先向右半步，再直行。',
    },
    read_sign: {
        user: '读一下门牌。',
        assistant: '门牌写着 A 会议室，门把手在你右手边。',
    },
    cross_now: {
        user: '现在能过吗？',
        assistant: '先停一下，左侧有电动车靠近，等它过去再走。',
    },
};

const demoState = {
    running: false,
    paused: false,
    listening: false,
    hd: false,
    typeTimer: null,
    phaseTimer: null,
    utterance: null,
};

function byId(id) {
    return document.getElementById(id);
}

function clearTimer(name) {
    if (demoState[name]) {
        window.clearTimeout(demoState[name]);
        demoState[name] = null;
    }
}

function setDemoStateLabel(text) {
    const el = byId('ceDemoState');
    if (el) el.textContent = text;
}

function stopSpeech() {
    clearTimer('typeTimer');
    if (window.speechSynthesis) {
        window.speechSynthesis.cancel();
    }
    demoState.utterance = null;
}

function speakText(text) {
    if (!window.speechSynthesis || !text) return;
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = 'zh-CN';
    utterance.rate = 1.02;
    utterance.pitch = 1;
    demoState.utterance = utterance;
    window.speechSynthesis.speak(utterance);
}

function setStatusLamp(state) {
    const lamp = byId('statusLamp');
    const overlay = byId('videoBorderOverlay');
    if (!lamp) return;
    lamp.className = 'status-lamp';
    if (state === 'hidden') {
        lamp.classList.remove('visible');
        overlay?.classList.remove('active');
        return;
    }
    lamp.classList.add('visible', state);
    const label = lamp.querySelector('.label');
    if (label) {
        label.textContent = state === 'preparing' ? 'Demo' : state === 'live' ? 'LIVE' : 'Idle';
    }
    if (state === 'live') {
        overlay?.classList.add('active');
    } else {
        overlay?.classList.remove('active');
    }
}

function ensureConversationRoot() {
    const log = byId('conversationLog');
    const empty = byId('convEmpty');
    if (!log || !empty) return null;
    empty.style.display = 'none';
    return log;
}

function addConversationEntry(kind, text) {
    const log = ensureConversationRoot();
    if (!log) return null;
    const entry = document.createElement('div');
    entry.className = `conv-entry ${kind}`;
    const icon = kind === 'system' ? '&#x2699;' : kind === 'user' ? '&#x1F464;' : '&#x1F916;';
    entry.innerHTML = `<div class="conv-icon">${icon}</div><div class="conv-text"></div>`;
    const textEl = entry.querySelector('.conv-text');
    textEl.textContent = text;
    log.appendChild(entry);
    log.scrollTop = log.scrollHeight;
    return textEl;
}

function clearConversation() {
    const log = byId('conversationLog');
    const empty = byId('convEmpty');
    if (!log || !empty) return;
    log.innerHTML = '';
    empty.style.display = 'flex';
    empty.textContent = '开始后，这里会显示演示对话。';
    log.appendChild(empty);
}

function syncButtons() {
    const start = byId('btnStart');
    const stop = byId('btnStop');
    const pause = byId('btnPause');
    const force = byId('btnForceListen');
    const hold = byId('btnHoldToTalk');
    const hd = byId('btnHD');
    const service = byId('serviceStatus');

    if (service) {
        service.textContent = '演示模式';
        service.className = 'status-badge online';
    }

    if (start) {
        start.disabled = demoState.running;
        start.textContent = demoState.running ? '进行中' : '开始';
    }
    if (stop) stop.disabled = !demoState.running;
    if (pause) {
        if (!demoState.running) {
            pause.disabled = true;
            pause.textContent = '暂停';
        } else if (!demoState.paused && pause.textContent !== '暂停中...' && pause.textContent !== '恢复中...') {
            pause.disabled = false;
            pause.textContent = '暂停';
        }
    }
    if (force) {
        force.disabled = !demoState.running || demoState.paused;
        force.classList.toggle('force-listen-active', demoState.listening);
        force.textContent = demoState.listening ? '恢复导盲' : '我在说话';
    }
    if (hold) hold.disabled = !demoState.running || demoState.paused;
    if (hd) {
        hd.disabled = !demoState.running;
        hd.classList.toggle('force-listen-active', demoState.hd);
    }
    const triggers = document.querySelectorAll('[data-demo-intent]');
    triggers.forEach((button) => {
        button.disabled = demoState.paused;
    });
}

function setListening(active) {
    demoState.listening = Boolean(active);
    syncButtons();
}

function setHd(active) {
    demoState.hd = Boolean(active);
    const checkbox = byId('visionHD');
    if (checkbox) {
        checkbox.checked = demoState.hd;
        checkbox.dispatchEvent(new Event('change', { bubbles: true }));
    }
    syncButtons();
}

function queueAssistantText(text) {
    stopSpeech();
    const line = addConversationEntry('speak', '');
    if (!line) return;
    let index = 0;
    const step = () => {
        line.textContent = text.slice(0, index);
        if (index < text.length) {
            index += 1;
            demoState.typeTimer = window.setTimeout(step, 24);
            return;
        }
        demoState.typeTimer = null;
        speakText(text);
    };
    step();
}

function handleTrigger(intent) {
    const scenario = DEMO_SCENARIOS[intent];
    if (!scenario) return;
    if (!demoState.running) {
        startDemo();
    }
    if (demoState.paused) return;

    stopSpeech();
    setListening(true);
    setDemoStateLabel('正在响应');
    addConversationEntry('user', scenario.user);
    setStatusLamp('preparing');
    clearTimer('phaseTimer');
    demoState.phaseTimer = window.setTimeout(() => {
        setListening(false);
        setStatusLamp('live');
        setDemoStateLabel('演示中');
        queueAssistantText(scenario.assistant);
    }, 260);
}

function startDemo() {
    if (demoState.running) return;
    clearConversation();
    stopSpeech();
    demoState.running = true;
    demoState.paused = false;
    demoState.listening = false;
    setStatusLamp('live');
    setDemoStateLabel('演示中');
    const placeholder = byId('videoPlaceholder');
    if (placeholder) {
        placeholder.style.display = 'flex';
        const placeholderText = placeholder.querySelector('span');
        if (placeholderText) placeholderText.textContent = '演示模式不连接摄像头和后端。';
    }
    const overlay = byId('videoOverlay');
    if (overlay) overlay.style.display = 'none';
    const badge = byId('modeBadge');
    if (badge) badge.textContent = 'Cyber Eyes Demo';
    addConversationEntry('system', '已进入离线演示。点下面的话术按钮即可模拟常见插话。');
    queueAssistantText('已开始演示。你可以试试“前面有什么”或“带我找电梯”。');
    syncButtons();
}

function stopDemo() {
    stopSpeech();
    clearTimer('phaseTimer');
    demoState.running = false;
    demoState.paused = false;
    demoState.listening = false;
    setStatusLamp('hidden');
    setDemoStateLabel('无需后端');
    syncButtons();
}

function togglePause() {
    const pause = byId('btnPause');
    if (!demoState.running || !pause) return;

    clearTimer('phaseTimer');
    if (!demoState.paused) {
        pause.disabled = true;
        pause.textContent = '暂停中...';
        setStatusLamp('preparing');
        demoState.phaseTimer = window.setTimeout(() => {
            demoState.paused = true;
            setListening(false);
            pause.disabled = false;
            pause.textContent = '继续';
            setStatusLamp('hidden');
            setDemoStateLabel('已暂停');
            addConversationEntry('system', '演示已暂停。');
            syncButtons();
        }, 220);
        return;
    }

    pause.disabled = true;
    pause.textContent = '恢复中...';
    demoState.phaseTimer = window.setTimeout(() => {
        demoState.paused = false;
        pause.disabled = false;
        pause.textContent = '暂停';
        setStatusLamp('live');
        setDemoStateLabel('演示中');
        addConversationEntry('system', '演示已恢复。');
        syncButtons();
    }, 220);
}

function toggleForceListen() {
    if (!demoState.running || demoState.paused) return;
    setListening(!demoState.listening);
}

function initDemoRuntime() {
    const quickPill = byId('ceBackendQuickPill');
    if (quickPill) {
        quickPill.textContent = '离线演示';
        quickPill.title = '不连接后端';
    }
    const demoStateEl = byId('ceDemoState');
    if (demoStateEl) demoStateEl.textContent = '无需后端';
    byId('btnStart')?.addEventListener('click', startDemo);
    byId('btnStop')?.addEventListener('click', stopDemo);
    byId('btnPause')?.addEventListener('click', togglePause);
    byId('btnForceListen')?.addEventListener('click', toggleForceListen);
    byId('btnHD')?.addEventListener('click', () => setHd(!demoState.hd));
    document.querySelectorAll('[data-demo-intent]').forEach((button) => {
        button.addEventListener('click', () => handleTrigger(button.dataset.demoIntent));
    });
    byId('btnDownloadRec')?.style.setProperty('display', 'none');
    setStatusLamp('hidden');
    clearConversation();
    syncButtons();
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initDemoRuntime, { once: true });
} else {
    initDemoRuntime();
}

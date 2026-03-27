const STORAGE_KEY = 'cyber_eyes_backend_target_id';
export const BACKEND_TARGET_CHANGE_EVENT = 'cybereyes:backend-target-change';

const DEFAULT_CONFIG = {
    defaultTargetId: 'local_minicpm',
    targets: [
        {
            id: 'local_minicpm',
            label: '本地 MiniCPM 后端',
            mode: 'proxy',
            httpBaseUrl: '',
            wsBaseUrl: '',
            enabled: true,
            description: '默认通过当前前端入口访问本地或同机房的 MiniCPM 后端。',
        },
    ],
};

function readStorage(key) {
    try {
        return window.localStorage.getItem(key);
    } catch {
        return null;
    }
}

function writeStorage(key, value) {
    try {
        window.localStorage.setItem(key, value);
    } catch {
        // Ignore storage failures in private or restricted contexts.
    }
}

function ensureTrailingSlash(value) {
    return value.endsWith('/') ? value : `${value}/`;
}

function sanitizeTarget(rawTarget, index = 0) {
    const id = String(rawTarget?.id || `target_${index + 1}`).trim() || `target_${index + 1}`;
    return {
        id,
        label: String(rawTarget?.label || id).trim() || id,
        mode: rawTarget?.mode === 'direct' ? 'direct' : 'proxy',
        httpBaseUrl: String(rawTarget?.httpBaseUrl || '').trim(),
        wsBaseUrl: String(rawTarget?.wsBaseUrl || '').trim(),
        enabled: rawTarget?.enabled !== false,
        description: String(rawTarget?.description || '').trim(),
    };
}

function getResolvedConfig() {
    const rawConfig = window.__CYBER_EYES_FRONTEND_CONFIG__ || DEFAULT_CONFIG;
    const targets = Array.isArray(rawConfig.targets)
        ? rawConfig.targets.map(sanitizeTarget).filter((target) => target.enabled)
        : DEFAULT_CONFIG.targets.map(sanitizeTarget);

    const resolvedTargets = targets.length ? targets : DEFAULT_CONFIG.targets.map(sanitizeTarget);
    const requestedDefaultId = String(rawConfig.defaultTargetId || DEFAULT_CONFIG.defaultTargetId).trim();
    const defaultTarget = resolvedTargets.find((target) => target.id === requestedDefaultId) || resolvedTargets[0];

    return {
        defaultTargetId: defaultTarget.id,
        targets: resolvedTargets,
    };
}

function resolveTarget(targetId = '') {
    const config = getResolvedConfig();
    const requestedId = String(targetId || '').trim();
    return config.targets.find((target) => target.id === requestedId)
        || config.targets.find((target) => target.id === config.defaultTargetId)
        || config.targets[0];
}

function joinBaseAndPath(baseUrl, requestPath) {
    const base = new URL(ensureTrailingSlash(baseUrl));
    return new URL(String(requestPath || '').replace(/^\/+/, ''), base);
}

function deriveWsBaseUrl(target) {
    if (target.wsBaseUrl) return target.wsBaseUrl;
    if (!target.httpBaseUrl) return '';
    return target.httpBaseUrl.replace(/^http:/i, 'ws:').replace(/^https:/i, 'wss:');
}

export function listBackendTargets() {
    return [...getResolvedConfig().targets];
}

export function getActiveBackendTarget() {
    const storedId = readStorage(STORAGE_KEY);
    return resolveTarget(storedId || getResolvedConfig().defaultTargetId);
}

export function setActiveBackendTarget(targetId) {
    const previousTarget = getActiveBackendTarget();
    const nextTarget = resolveTarget(targetId);
    writeStorage(STORAGE_KEY, nextTarget.id);

    window.dispatchEvent(new CustomEvent(BACKEND_TARGET_CHANGE_EVENT, {
        detail: {
            previousTarget,
            nextTarget,
        },
    }));

    return nextTarget;
}

export function subscribeBackendTargetChange(listener) {
    const wrapped = (event) => listener(event.detail);
    window.addEventListener(BACKEND_TARGET_CHANGE_EVENT, wrapped);
    return () => window.removeEventListener(BACKEND_TARGET_CHANGE_EVENT, wrapped);
}

export function buildBackendHttpUrl(requestPath, { targetId = '' } = {}) {
    const target = resolveTarget(targetId || getActiveBackendTarget().id);

    if (target.mode === 'direct' && target.httpBaseUrl) {
        return joinBaseAndPath(target.httpBaseUrl, requestPath).toString();
    }

    const url = new URL(String(requestPath || '/').startsWith('/') ? requestPath : `/${requestPath}`, window.location.origin);
    url.searchParams.set('cy_target', target.id);
    return url.toString();
}

export function buildBackendWsUrl(requestPath, { targetId = '' } = {}) {
    const target = resolveTarget(targetId || getActiveBackendTarget().id);

    if (target.mode === 'direct') {
        const wsBaseUrl = deriveWsBaseUrl(target);
        if (!wsBaseUrl) {
            throw new Error(`Backend target "${target.id}" is missing wsBaseUrl/httpBaseUrl`);
        }
        return joinBaseAndPath(wsBaseUrl, requestPath).toString();
    }

    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const base = `${proto}//${window.location.host}`;
    const url = new URL(String(requestPath || '/').startsWith('/') ? requestPath : `/${requestPath}`, base);
    url.searchParams.set('cy_target', target.id);
    return url.toString();
}

export function describeBackendTarget(target = getActiveBackendTarget()) {
    const modeLabel = target.mode === 'direct' ? '浏览器直连后端' : '前端代理到后端';
    const browserEndpoint = target.mode === 'direct'
        ? (target.httpBaseUrl || '(未配置)')
        : window.location.origin;
    const upstreamEndpoint = target.mode === 'direct'
        ? (target.httpBaseUrl || '(未配置)')
        : (target.httpBaseUrl || '同源网关');

    return {
        ...target,
        modeLabel,
        browserEndpoint,
        upstreamEndpoint,
        description: target.description || (target.mode === 'direct'
            ? '浏览器会直接访问允许的远端后端，请确保后端已放行当前前端域名。'
            : '浏览器只访问当前前端入口，由前端服务代办转发到配置中的后端。'),
    };
}

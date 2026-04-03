const VALID_PAGE_MODES = new Set(['user', 'dev', 'demo']);

export function getPageMode() {
    const bodyMode = document.body?.dataset?.cePageMode || '';
    const globalMode = window.__CYBER_EYES_PAGE_MODE__ || '';
    const mode = String(bodyMode || globalMode || 'user').trim().toLowerCase();
    return VALID_PAGE_MODES.has(mode) ? mode : 'user';
}

export function isDeveloperMode() {
    return getPageMode() === 'dev';
}

export function isDemoMode() {
    return getPageMode() === 'demo';
}

export function isUserMode() {
    return getPageMode() === 'user';
}

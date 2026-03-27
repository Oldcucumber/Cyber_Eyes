/**
 * ui/ref-audio-init.js — Shared RefAudioPlayer initialization for duplex pages
 *
 * Handles: create RefAudioPlayer instance, fetch default ref audio, wire upload/remove.
 * Returns accessor object for the current ref audio state.
 */

/**
 * Initialize a RefAudioPlayer with default ref audio fetching.
 *
 * @param {string} containerId - DOM element ID for the RefAudioPlayer container
 * @param {object} [callbacks]
 * @param {function} [callbacks.onTtsHintUpdate] - Called after default ref audio loads (for TTS hint refresh)
 * @returns {{ getBase64: () => string|null, getName: () => string, isDefault: () => boolean, rap: RefAudioPlayer }}
 */
import { buildBackendHttpUrl } from '../../lib/backend-targets.js';

export function initRefAudio(containerId, callbacks = {}) {
    const RefAudioPlayer = window.RefAudioPlayer;
    let base64 = null;
    let name = '';
    let isDefault = false;

    const rap = new RefAudioPlayer(document.getElementById(containerId), {
        theme: 'light',
        onUpload(b64, n, duration) {
            base64 = b64;
            name = n;
            isDefault = false;
        },
        onRemove() {
            base64 = null;
            name = '';
            isDefault = false;
            loadDefaultRefAudio().catch(() => {});
        },
    });

    async function loadDefaultRefAudio({ updateHint = false } = {}) {
        const resp = await fetch(buildBackendHttpUrl('/api/default_ref_audio'));
        if (!resp.ok) {
            throw new Error(`default ref audio request failed (${resp.status})`);
        }

        const data = await resp.json();
        if (!data || !data.base64 || !data.name) {
            throw new Error('default ref audio payload is incomplete');
        }

        base64 = data.base64;
        name = data.name;
        isDefault = true;
        rap.setAudio(data.base64, data.name, data.duration);
        if (updateHint) callbacks.onTtsHintUpdate?.();
        return data;
    }

    // Load default ref audio
    loadDefaultRefAudio({ updateHint: true }).then(data => {
        console.log(`Default ref audio loaded: ${data.name} (${data.duration}s)`);
    }).catch(e => {
        console.warn('Failed to load default ref audio:', e);
    });

    return {
        getBase64: () => base64,
        getName: () => name,
        isDefault: () => isDefault,
        rap,
        setAudio(b64, n, dur) {
            base64 = b64;
            name = n || '';
            isDefault = false;
            rap.setAudio(b64, n, dur);
        },
    };
}

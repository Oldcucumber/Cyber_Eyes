from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import json
import logging
import os
import re
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, Optional

import uvicorn
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles

from backend.config import get_config
from backend.gateway_modules.models import EtaConfig, GatewayWorkerStatus, ServiceStatus, WorkersResponse
from backend.gateway_modules.worker_pool import WorkerConnection, WorkerPool

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
)
logger = logging.getLogger('gateway')

PROJECT_ROOT = os.path.dirname(os.path.dirname(__file__))
STATIC_DIR = os.path.join(PROJECT_ROOT, 'frontend', 'static')
CYBER_EYES_PAGE = os.path.join(STATIC_DIR, 'cyber-eyes', 'cyber-eyes.html')
SESSION_ID_RE = re.compile(r'^[a-zA-Z0-9_-]+$')

worker_pool: Optional[WorkerPool] = None
gateway_config: dict[str, Any] = {}
_default_ref_audio_cache: Optional[dict[str, Any]] = None


def _resolve_project_path(path: str) -> str:
    return path if os.path.isabs(path) else os.path.join(PROJECT_ROOT, path)


def _sanitize_session_id(session_id: str) -> str:
    if SESSION_ID_RE.fullmatch(session_id):
        return session_id
    return re.sub(r'[^a-zA-Z0-9_-]', '_', session_id)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global worker_pool

    cfg = get_config()
    workers = gateway_config.get('workers') or cfg.worker_addresses(1)
    timeout = gateway_config.get('timeout', cfg.request_timeout)
    max_queue_size = gateway_config.get('max_queue_size', cfg.max_queue_size)
    eta_config = EtaConfig(
        eta_chat_s=cfg.eta_chat_s,
        eta_half_duplex_s=cfg.eta_half_duplex_s,
        eta_audio_duplex_s=cfg.eta_audio_duplex_s,
        eta_omni_duplex_s=cfg.eta_omni_duplex_s,
    )

    worker_pool = WorkerPool(
        worker_addresses=workers,
        max_queue_size=max_queue_size,
        request_timeout=timeout,
        eta_config=eta_config,
        ema_alpha=cfg.eta_ema_alpha,
        ema_min_samples=cfg.eta_ema_min_samples,
    )
    await worker_pool.start()
    logger.info('Gateway started with %s worker(s): %s', len(workers), ', '.join(workers))

    try:
        yield
    finally:
        if worker_pool is not None:
            await worker_pool.stop()
        worker_pool = None
        logger.info('Gateway stopped')


app = FastAPI(
    title='Cyber Eyes Gateway',
    version='1.0.0',
    lifespan=lifespan,
)

try:
    cors_allowed_origins = [origin.strip() for origin in get_config().frontend_cors_allowed_origins if origin.strip()]
except Exception as exc:
    cors_allowed_origins = []
    logger.warning('Frontend CORS origins are unavailable until config.json is ready: %s', exc)

if cors_allowed_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=cors_allowed_origins,
        allow_credentials=False,
        allow_methods=['*'],
        allow_headers=['*'],
    )

if os.path.isdir(STATIC_DIR):
    app.mount('/static', StaticFiles(directory=STATIC_DIR), name='static')


@app.get('/health')
async def health() -> dict[str, str]:
    return {
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat() + 'Z',
    }


@app.get('/status', response_model=ServiceStatus)
async def status() -> ServiceStatus:
    if worker_pool is None:
        raise HTTPException(status_code=503, detail='Service not ready')

    queue_status = worker_pool.get_queue_status()
    return ServiceStatus(
        gateway_healthy=True,
        total_workers=len(worker_pool.workers),
        idle_workers=worker_pool.idle_count,
        busy_workers=worker_pool.busy_count,
        duplex_workers=worker_pool.duplex_count,
        loading_workers=worker_pool.loading_count,
        error_workers=worker_pool.error_count,
        offline_workers=worker_pool.offline_count,
        queue_length=queue_status.queue_length,
        max_queue_size=queue_status.max_queue_size,
        running_tasks=queue_status.running_tasks,
    )


@app.get('/workers', response_model=WorkersResponse)
async def workers() -> WorkersResponse:
    if worker_pool is None:
        raise HTTPException(status_code=503, detail='Service not ready')
    return WorkersResponse(total=len(worker_pool.workers), workers=worker_pool.get_all_workers())


@app.get('/api/frontend_defaults')
async def frontend_defaults() -> dict[str, Any]:
    return get_config().frontend_defaults()


@app.get('/frontend-config.js')
async def frontend_config_js() -> Response:
    config_script = f'window.__CYBER_EYES_FRONTEND_CONFIG__ = {json.dumps(get_config().frontend_runtime_config(), ensure_ascii=False, indent=2)};\n'
    return Response(content=config_script, media_type='application/javascript')


@app.get('/api/default_ref_audio')
async def default_ref_audio() -> dict[str, Any]:
    global _default_ref_audio_cache

    cfg = get_config()
    if not cfg.ref_audio_path:
        raise HTTPException(status_code=404, detail='No default ref audio configured')

    ref_path = _resolve_project_path(cfg.ref_audio_path)
    if not os.path.isfile(ref_path):
        raise HTTPException(status_code=404, detail=f'Default ref audio not found: {cfg.ref_audio_path}')

    if _default_ref_audio_cache and _default_ref_audio_cache.get('path') == ref_path:
        return _default_ref_audio_cache['payload']

    try:
        import torch
        import torchaudio

        waveform, sample_rate = torchaudio.load(ref_path)
        if waveform.numel() == 0:
            raise ValueError('reference audio is empty')
        if waveform.dim() > 1 and waveform.shape[0] > 1:
            waveform = waveform.mean(dim=0, keepdim=True)
        if sample_rate != 16000:
            waveform = torchaudio.functional.resample(waveform, sample_rate, 16000)
        waveform = waveform.to(dtype=torch.float32).contiguous()
        samples = waveform.squeeze(0).cpu().numpy().astype('float32', copy=False)
        payload = {
            'name': os.path.basename(ref_path),
            'duration': round(samples.shape[0] / 16000, 1),
            'sample_rate': 16000,
            'samples': int(samples.shape[0]),
            'base64': base64.b64encode(samples.tobytes()).decode('ascii'),
        }
    except Exception as exc:
        logger.error('Failed to load default ref audio from %s: %s', ref_path, exc, exc_info=True)
        raise HTTPException(status_code=500, detail=f'Failed to load default ref audio: {exc}') from exc

    _default_ref_audio_cache = {
        'path': ref_path,
        'payload': payload,
    }
    return payload


@app.get('/', response_class=HTMLResponse)
async def index() -> RedirectResponse:
    return RedirectResponse(url='/cyber-eyes', status_code=302)


@app.get('/cyber-eyes', response_class=HTMLResponse)
async def cyber_eyes() -> HTMLResponse | FileResponse:
    if os.path.isfile(CYBER_EYES_PAGE):
        return FileResponse(CYBER_EYES_PAGE)
    return HTMLResponse('<h1>Cyber Eyes</h1><p>Frontend page not found.</p>', status_code=500)


@app.get('/cyber-eyes/', response_class=HTMLResponse)
async def cyber_eyes_slash() -> RedirectResponse:
    return RedirectResponse(url='/cyber-eyes', status_code=302)


@app.get('/dev', response_class=HTMLResponse)
async def dev_page() -> HTMLResponse | FileResponse:
    if os.path.isfile(CYBER_EYES_PAGE):
        return FileResponse(CYBER_EYES_PAGE)
    return HTMLResponse('<h1>Cyber Eyes Dev</h1><p>Frontend page not found.</p>', status_code=500)


@app.get('/dev/', response_class=HTMLResponse)
async def dev_page_slash() -> RedirectResponse:
    return RedirectResponse(url='/dev', status_code=302)


async def _safe_close_client(ws: WebSocket, code: int = 1000, reason: str = '') -> None:
    try:
        await ws.close(code=code, reason=reason)
    except RuntimeError:
        pass
    except Exception:
        logger.debug('Ignoring client close error', exc_info=True)


def _maybe_update_worker_status(worker: WorkerConnection, raw_message: str) -> None:
    try:
        message = json.loads(raw_message)
    except json.JSONDecodeError:
        return

    msg_type = message.get('type')
    if msg_type == 'paused':
        worker.update_duplex_status(GatewayWorkerStatus.DUPLEX_PAUSED)
    elif msg_type == 'resumed':
        worker.update_duplex_status(GatewayWorkerStatus.DUPLEX_ACTIVE)


@app.websocket('/ws/duplex/{session_id}')
async def duplex_ws(client_ws: WebSocket, session_id: str):
    if worker_pool is None:
        await _safe_close_client(client_ws, code=1013, reason='Service not ready')
        return

    session_id = _sanitize_session_id(session_id)
    await client_ws.accept()

    try:
        ticket, future = worker_pool.enqueue('omni_duplex', session_id=session_id)
    except WorkerPool.QueueFullError:
        await client_ws.send_json({
            'type': 'error',
            'error': f'Queue full ({worker_pool.max_queue_size} requests)',
        })
        await _safe_close_client(client_ws, code=1013, reason='Queue full')
        return

    assigned_worker: Optional[WorkerConnection] = None
    if future.done():
        assigned_worker = future.result()
    else:
        try:
            await client_ws.send_json({
                'type': 'queued',
                'position': ticket.position,
                'estimated_wait_s': ticket.estimated_wait_s,
                'ticket_id': ticket.ticket_id,
                'queue_length': worker_pool.queue_length,
            })
            while not future.done():
                try:
                    assigned_worker = await asyncio.wait_for(asyncio.shield(future), timeout=3.0)
                    break
                except asyncio.TimeoutError:
                    updated = worker_pool.get_ticket(ticket.ticket_id)
                    if updated:
                        await client_ws.send_json({
                            'type': 'queue_update',
                            'position': updated.position,
                            'estimated_wait_s': updated.estimated_wait_s,
                            'queue_length': worker_pool.queue_length,
                        })
                except asyncio.CancelledError:
                    worker_pool.cancel(ticket.ticket_id)
                    return
        except (WebSocketDisconnect, Exception) as exc:
            logger.info('Client disconnected while waiting in queue for %s: %s', session_id, exc)
            worker_pool.cancel(ticket.ticket_id)
            return
        if assigned_worker is None and future.done():
            assigned_worker = future.result()

    if assigned_worker is None:
        await client_ws.send_json({'type': 'error', 'error': 'No worker available'})
        await _safe_close_client(client_ws, code=1013, reason='No worker available')
        return

    await client_ws.send_json({'type': 'queue_done'})
    logger.info('Duplex session %s assigned to %s', session_id, assigned_worker.worker_id)

    worker_ws = None
    started_at = datetime.now()
    try:
        import websockets

        worker_url = f'ws://{assigned_worker.host}:{assigned_worker.port}/ws/duplex?session_id={session_id}'
        worker_ws = await websockets.connect(worker_url, open_timeout=10)

        async def client_to_worker() -> None:
            assert worker_ws is not None
            try:
                async for raw in client_ws.iter_text():
                    await worker_ws.send(raw)
            except WebSocketDisconnect:
                logger.info('Client websocket disconnected for %s', session_id)

        async def worker_to_client() -> None:
            assert worker_ws is not None
            async for raw in worker_ws:
                _maybe_update_worker_status(assigned_worker, raw)
                await client_ws.send_text(raw)

        done, pending = await asyncio.wait(
            [
                asyncio.create_task(client_to_worker()),
                asyncio.create_task(worker_to_client()),
            ],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
        for task in done:
            with contextlib.suppress(Exception):
                await task
    except Exception as exc:
        logger.error('Duplex websocket proxy failed for %s: %s', session_id, exc, exc_info=True)
        try:
            await client_ws.send_json({'type': 'error', 'error': str(exc)})
        except Exception:
            pass
    finally:
        if worker_ws is not None:
            with contextlib.suppress(Exception):
                await worker_ws.close()
        duration_s = (datetime.now() - started_at).total_seconds()
        worker_pool.release_worker(assigned_worker, request_type='omni_duplex', duration_s=duration_s)
        await _safe_close_client(client_ws)
        logger.info('Duplex session %s closed after %.1fs', session_id, duration_s)


def main() -> None:
    cfg = get_config()

    parser = argparse.ArgumentParser(description='Cyber Eyes gateway')
    parser.add_argument('--host', default='0.0.0.0', help='Gateway listen host')
    parser.add_argument('--port', type=int, default=cfg.gateway_port, help='Gateway listen port')
    parser.add_argument('--workers', default=None, help='Comma-separated worker host:port list')
    parser.add_argument('--max-queue-size', type=int, default=cfg.max_queue_size, help='Max queued duplex sessions')
    parser.add_argument('--timeout', type=float, default=cfg.request_timeout, help='Gateway timeout in seconds')
    parser.add_argument('--http', action='store_true', help='Serve plain HTTP for debugging only')
    parser.add_argument('--ssl-certfile', default='certs/cert.pem', help='TLS certificate path')
    parser.add_argument('--ssl-keyfile', default='certs/key.pem', help='TLS private key path')
    args = parser.parse_args()

    workers = [item.strip() for item in (args.workers or '').split(',') if item.strip()]
    if not workers:
        workers = cfg.worker_addresses(1)

    gateway_config.update({
        'workers': workers,
        'max_queue_size': args.max_queue_size,
        'timeout': args.timeout,
    })

    ssl_kwargs: dict[str, Any] = {}
    if not args.http:
        cert_path = _resolve_project_path(args.ssl_certfile)
        key_path = _resolve_project_path(args.ssl_keyfile)
        if not os.path.isfile(cert_path) or not os.path.isfile(key_path):
            raise SystemExit(
                'TLS certificate or key not found. Run `bash ops/bootstrap.sh` first, '
                'or pass --http for debugging only.'
            )
        ssl_kwargs = {
            'ssl_certfile': cert_path,
            'ssl_keyfile': key_path,
        }
    else:
        logger.warning('Running gateway without TLS. Browser camera and microphone access may fail.')

    logger.info('Starting gateway on %s:%s with workers: %s', args.host, args.port, ', '.join(workers))
    uvicorn.run(app, host=args.host, port=args.port, **ssl_kwargs)


if __name__ == '__main__':
    main()


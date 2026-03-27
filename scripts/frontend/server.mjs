import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import httpProxy from 'http-proxy';

import { loadFrontendConfig, readCyberEyesHtml, toFrontendConfigScript } from './config-utils.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..', '..');

let port = Number(process.env.FRONTEND_PORT || 3000);
let host = process.env.FRONTEND_HOST || '0.0.0.0';
let useDist = false;
let explicitConfigPath = '';

for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === '--dist') {
    useDist = true;
  } else if (arg === '--port') {
    port = Number(process.argv[i + 1] || port);
    i += 1;
  } else if (arg === '--host') {
    host = process.argv[i + 1] || host;
    i += 1;
  } else if (arg === '--config') {
    explicitConfigPath = process.argv[i + 1] || '';
    i += 1;
  }
}

const { config, configPath } = await loadFrontendConfig(projectRoot, explicitConfigPath);
const proxy = httpProxy.createProxyServer({
  changeOrigin: true,
  secure: false,
  ws: true,
});

proxy.on('error', (error, req, res) => {
  const message = `[frontend proxy] ${error.message}`;
  if (res && !res.headersSent) {
    res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: message }));
    return;
  }
  console.error(message);
});

function contentType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  switch (ext) {
    case '.css': return 'text/css; charset=utf-8';
    case '.html': return 'text/html; charset=utf-8';
    case '.js':
    case '.mjs': return 'application/javascript; charset=utf-8';
    case '.json': return 'application/json; charset=utf-8';
    case '.png': return 'image/png';
    case '.jpg':
    case '.jpeg': return 'image/jpeg';
    case '.svg': return 'image/svg+xml';
    case '.wav': return 'audio/wav';
    case '.mp4': return 'video/mp4';
    default: return 'application/octet-stream';
  }
}

function isProxyPath(urlPath) {
  return (
    urlPath === '/health'
    || urlPath === '/status'
    || urlPath === '/workers'
    || urlPath.startsWith('/api/')
    || urlPath.startsWith('/ws/')
  );
}

function findTarget(targetId) {
  const activeId = targetId || config.defaultTargetId;
  return config.targets.find((target) => target.id === activeId) || config.targets[0];
}

function stripTargetQuery(rawUrl) {
  const url = new URL(rawUrl, 'http://frontend.local');
  url.searchParams.delete('cy_target');
  const nextQuery = url.searchParams.toString();
  return `${url.pathname}${nextQuery ? `?${nextQuery}` : ''}`;
}

function resolveProxyTarget(rawUrl) {
  const url = new URL(rawUrl, 'http://frontend.local');
  const requestedId = url.searchParams.get('cy_target') || '';
  const target = findTarget(requestedId);
  if (!target || target.mode !== 'proxy') return null;
  return target;
}

async function serveFile(res, filePath) {
  try {
    const data = await fs.readFile(filePath);
    res.writeHead(200, {
      'Content-Type': contentType(filePath),
      'Cache-Control': 'no-cache',
    });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not found');
  }
}

async function resolveRootHtml() {
  if (useDist) {
    return fs.readFile(path.join(projectRoot, 'dist', 'index.html'), 'utf8');
  }
  return readCyberEyesHtml(projectRoot);
}

async function resolveCyberEyesHtml() {
  if (useDist) {
    return fs.readFile(path.join(projectRoot, 'dist', 'cyber-eyes', 'index.html'), 'utf8');
  }
  return readCyberEyesHtml(projectRoot);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://frontend.local');

  if (url.pathname === '/frontend-config.js') {
    res.writeHead(200, {
      'Content-Type': 'application/javascript; charset=utf-8',
      'Cache-Control': 'no-cache',
    });
    res.end(toFrontendConfigScript(config));
    return;
  }

  if (isProxyPath(url.pathname)) {
    const target = resolveProxyTarget(req.url || '/');
    if (!target) {
      res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ error: 'Current backend target is not configured for proxy mode.' }));
      return;
    }
    req.url = stripTargetQuery(req.url || '/');
    proxy.web(req, res, { target: target.httpBaseUrl });
    return;
  }

  if (!useDist && url.pathname === '/cyber-eyes/') {
    res.writeHead(302, { Location: '/cyber-eyes' });
    res.end();
    return;
  }

  if (url.pathname === '/') {
    const html = await resolveRootHtml();
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-cache',
    });
    res.end(html);
    return;
  }

  if (url.pathname === '/cyber-eyes' || url.pathname === '/cyber-eyes/') {
    const html = await resolveCyberEyesHtml();
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-cache',
    });
    res.end(html);
    return;
  }

  const rootDir = useDist
    ? path.join(projectRoot, 'dist')
    : path.join(projectRoot, 'frontend');
  const rootResolved = path.resolve(rootDir);
  const filePath = path.resolve(rootResolved, url.pathname.replace(/^\/+/, ''));
  if (filePath !== rootResolved && !filePath.startsWith(`${rootResolved}${path.sep}`)) {
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Forbidden');
    return;
  }
  await serveFile(res, filePath);
});

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url || '/', 'http://frontend.local');
  if (!url.pathname.startsWith('/ws/')) {
    socket.destroy();
    return;
  }

  const target = resolveProxyTarget(req.url || '/');
  if (!target) {
    socket.destroy();
    return;
  }

  req.url = stripTargetQuery(req.url || '/');
  proxy.ws(req, socket, head, { target: target.wsBaseUrl || target.httpBaseUrl });
});

server.listen(port, host, () => {
  console.log(`[frontend server] host=${host} port=${port} dist=${useDist ? 'yes' : 'no'}`);
  console.log(`[frontend server] config=${configPath}`);
  console.log(`[frontend server] defaultTarget=${config.defaultTargetId}`);
});

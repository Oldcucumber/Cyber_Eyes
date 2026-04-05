import fs from 'node:fs/promises';
import path from 'node:path';

const DEFAULT_CONFIG = {
  defaultTargetId: 'local_minicpm',
  targets: [
    {
      id: 'local_minicpm',
      label: '本地 MiniCPM 后端',
      mode: 'proxy',
      httpBaseUrl: 'https://127.0.0.1:8006',
      wsBaseUrl: 'wss://127.0.0.1:8006',
      enabled: true,
      description: '默认由前端服务器代理到本机或同机房的 MiniCPM 网关。',
    },
  ],
};

const PAGE_VARIANTS = {
  user: {
    title: 'Cyber Eyes 导盲模式',
    heading: '实时导盲',
    subtitle: '短句播报，可随时打断。',
    modeClass: 'ce-page-user',
    runtimeModule: 'static/runtime/duplex-runtime.js',
    serviceBadgeText: '连接中...',
  },
  dev: {
    title: 'Cyber Eyes 开发者模式',
    heading: '开发者模式',
    subtitle: '完整控制台，用于设备、后端和提示词调试。',
    modeClass: 'ce-page-dev ce-dev-mode',
    runtimeModule: 'static/runtime/duplex-runtime.js',
    serviceBadgeText: '连接中...',
  },
  demo: {
    title: 'Cyber Eyes 演示模式',
    heading: '离线演示',
    subtitle: '不连后端，直接体验常见语音触发。',
    modeClass: 'ce-page-demo',
    runtimeModule: 'static/runtime/demo-runtime.js',
    serviceBadgeText: '演示模式',
  },
};

function normalizeTarget(raw, index = 0) {
  const id = String(raw?.id || `target_${index + 1}`).trim() || `target_${index + 1}`;
  return {
    id,
    label: String(raw?.label || id).trim() || id,
    mode: raw?.mode === 'direct' ? 'direct' : 'proxy',
    httpBaseUrl: String(raw?.httpBaseUrl || '').trim(),
    wsBaseUrl: String(raw?.wsBaseUrl || '').trim(),
    enabled: raw?.enabled !== false,
    description: String(raw?.description || '').trim(),
  };
}

function applyEnvOverrides(config) {
  const httpBaseUrl = String(process.env.CYBER_EYES_REMOTE_HTTP_BASE_URL || '').trim();
  if (!httpBaseUrl) return config;

  const id = String(process.env.CYBER_EYES_REMOTE_TARGET_ID || 'remote_production').trim();
  const label = String(process.env.CYBER_EYES_REMOTE_TARGET_LABEL || '远端生产后端').trim();
  const wsBaseUrl = String(process.env.CYBER_EYES_REMOTE_WS_BASE_URL || '').trim();
  const description = String(
    process.env.CYBER_EYES_REMOTE_TARGET_DESCRIPTION
    || '由 CI 或部署环境注入的远端后端目标。',
  ).trim();
  const mode = String(process.env.CYBER_EYES_REMOTE_TARGET_MODE || 'direct').trim() === 'proxy'
    ? 'proxy'
    : 'direct';

  const nextTargets = (config.targets || []).filter((target) => target.id !== id);
  nextTargets.push(normalizeTarget({
    id,
    label,
    mode,
    httpBaseUrl,
    wsBaseUrl,
    enabled: true,
    description,
  }, nextTargets.length));

  return {
    ...config,
    defaultTargetId: String(process.env.CYBER_EYES_ACTIVE_TARGET_ID || id).trim() || id,
    targets: nextTargets,
  };
}

function getPageVariant(mode = 'user') {
  return PAGE_VARIANTS[mode] || PAGE_VARIANTS.user;
}

export async function resolveFrontendConfigPath(projectRoot, explicitPath = '') {
  if (explicitPath) return path.resolve(projectRoot, explicitPath);

  const envPath = String(process.env.CYBER_EYES_FRONTEND_CONFIG || '').trim();
  if (envPath) return path.resolve(projectRoot, envPath);

  const localPath = path.join(projectRoot, 'frontend', 'config', 'backend-targets.local.json');
  try {
    await fs.access(localPath);
    return localPath;
  } catch {}

  return path.join(projectRoot, 'frontend', 'config', 'backend-targets.json');
}

export async function loadFrontendConfig(projectRoot, explicitPath = '') {
  const configPath = await resolveFrontendConfigPath(projectRoot, explicitPath);
  let parsed = DEFAULT_CONFIG;

  try {
    const raw = await fs.readFile(configPath, 'utf8');
    parsed = JSON.parse(raw);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const targets = Array.isArray(parsed.targets)
    ? parsed.targets.map(normalizeTarget)
    : DEFAULT_CONFIG.targets.map(normalizeTarget);

  const normalized = {
    defaultTargetId: String(parsed.defaultTargetId || DEFAULT_CONFIG.defaultTargetId).trim() || DEFAULT_CONFIG.defaultTargetId,
    targets: targets.filter((target) => target.enabled),
  };

  const withEnv = applyEnvOverrides(normalized);
  if (!withEnv.targets.length) {
    withEnv.targets = DEFAULT_CONFIG.targets.map(normalizeTarget);
  }
  if (!withEnv.targets.some((target) => target.id === withEnv.defaultTargetId)) {
    withEnv.defaultTargetId = withEnv.targets[0].id;
  }

  return {
    configPath,
    config: withEnv,
  };
}

export function toFrontendConfigScript(config) {
  return `window.__CYBER_EYES_FRONTEND_CONFIG__ = ${JSON.stringify(config, null, 2)};\n`;
}

export async function ensureCleanDir(dirPath) {
  await fs.rm(dirPath, { recursive: true, force: true });
  await fs.mkdir(dirPath, { recursive: true });
}

export async function copyDir(srcDir, dstDir) {
  await fs.mkdir(dstDir, { recursive: true });
  const entries = await fs.readdir(srcDir, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(srcDir, entry.name);
    const dstPath = path.join(dstDir, entry.name);
    if (entry.isDirectory()) {
      await copyDir(srcPath, dstPath);
    } else {
      await fs.copyFile(srcPath, dstPath);
    }
  }
}

export async function readCyberEyesHtml(projectRoot) {
  const htmlPath = path.join(projectRoot, 'frontend', 'static', 'cyber-eyes', 'cyber-eyes.html');
  return fs.readFile(htmlPath, 'utf8');
}

export async function resolvePagesCname(projectRoot) {
  const envValue = String(process.env.CYBER_EYES_PAGES_CNAME || '').trim();
  if (envValue) return envValue;

  const filePath = path.join(projectRoot, 'frontend', 'CNAME');
  try {
    const fileValue = (await fs.readFile(filePath, 'utf8')).trim();
    return fileValue || '';
  } catch (error) {
    if (error.code === 'ENOENT') return '';
    throw error;
  }
}

export async function renderCyberEyesHtml(projectRoot, { mode = 'user', assetPrefix = '.' } = {}) {
  const template = await readCyberEyesHtml(projectRoot);
  const variant = getPageVariant(mode);
  const prefix = assetPrefix || '.';

  return template
    .replaceAll('__CYBER_EYES_PAGE_TITLE__', variant.title)
    .replaceAll('__CYBER_EYES_PAGE_HEADING__', variant.heading)
    .replaceAll('__CYBER_EYES_PAGE_SUBTITLE__', variant.subtitle)
    .replaceAll('__CYBER_EYES_SERVICE_BADGE_TEXT__', variant.serviceBadgeText)
    .replaceAll('__CYBER_EYES_MODE_CLASS__', variant.modeClass)
    .replaceAll('__CYBER_EYES_PAGE_MODE_VALUE__', mode)
    .replaceAll('__CYBER_EYES_ASSET_PREFIX__', prefix)
    .replaceAll('__CYBER_EYES_RUNTIME_MODULE__', `${prefix}/${variant.runtimeModule}`);
}

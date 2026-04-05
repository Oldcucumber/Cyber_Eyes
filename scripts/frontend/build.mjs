import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  copyDir,
  ensureCleanDir,
  loadFrontendConfig,
  renderCyberEyesHtml,
  resolvePagesCname,
  toFrontendConfigScript,
} from './config-utils.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..', '..');
const distDir = path.join(projectRoot, 'dist');
const staticSrcDir = path.join(projectRoot, 'frontend', 'static');
const staticDstDir = path.join(distDir, 'static');

const configArgIndex = process.argv.indexOf('--config');
const explicitConfigPath = configArgIndex >= 0 ? process.argv[configArgIndex + 1] : '';

const { config, configPath } = await loadFrontendConfig(projectRoot, explicitConfigPath);
const pagesCname = await resolvePagesCname(projectRoot);
const hasDirectTarget = config.targets.some((target) => target.enabled !== false && target.mode === 'direct');

await ensureCleanDir(distDir);
await copyDir(staticSrcDir, staticDstDir);

const userHtml = await renderCyberEyesHtml(projectRoot, { mode: 'user', assetPrefix: '.' });
const nestedUserHtml = await renderCyberEyesHtml(projectRoot, { mode: 'user', assetPrefix: '..' });
const devHtml = await renderCyberEyesHtml(projectRoot, { mode: 'dev', assetPrefix: '..' });
const demoHtml = await renderCyberEyesHtml(projectRoot, { mode: 'demo', assetPrefix: '..' });

await fs.writeFile(path.join(distDir, 'index.html'), userHtml, 'utf8');
await fs.mkdir(path.join(distDir, 'cyber-eyes'), { recursive: true });
await fs.writeFile(
  path.join(distDir, 'cyber-eyes', 'index.html'),
  nestedUserHtml,
  'utf8',
);
await fs.mkdir(path.join(distDir, 'dev'), { recursive: true });
await fs.writeFile(
  path.join(distDir, 'dev', 'index.html'),
  devHtml,
  'utf8',
);
await fs.mkdir(path.join(distDir, 'demo'), { recursive: true });
await fs.writeFile(
  path.join(distDir, 'demo', 'index.html'),
  demoHtml,
  'utf8',
);
await fs.writeFile(path.join(distDir, 'frontend-config.js'), toFrontendConfigScript(config), 'utf8');
await fs.writeFile(path.join(distDir, '404.html'), userHtml, 'utf8');
await fs.writeFile(path.join(distDir, '.nojekyll'), '', 'utf8');
if (pagesCname) {
  await fs.writeFile(path.join(distDir, 'CNAME'), `${pagesCname}\n`, 'utf8');
  if (!hasDirectTarget) {
    console.warn('[frontend build] warning: custom-domain static deploy has no direct backend target configured. This build will require a same-origin reverse proxy for /status, /api/*, and /ws/*.');
  }
}

console.log(`[frontend build] config: ${configPath}`);
console.log(`[frontend build] output: ${distDir}`);

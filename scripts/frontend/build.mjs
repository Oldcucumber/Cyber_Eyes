import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  copyDir,
  ensureCleanDir,
  loadFrontendConfig,
  readCyberEyesHtml,
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

await ensureCleanDir(distDir);
await copyDir(staticSrcDir, staticDstDir);

const html = await readCyberEyesHtml(projectRoot);
await fs.writeFile(path.join(distDir, 'index.html'), html, 'utf8');
await fs.mkdir(path.join(distDir, 'cyber-eyes'), { recursive: true });
await fs.writeFile(
  path.join(distDir, 'cyber-eyes', 'index.html'),
  html
    .replaceAll('./frontend-config.js', '../frontend-config.js')
    .replaceAll('./static/', '../static/'),
  'utf8',
);
await fs.writeFile(path.join(distDir, 'frontend-config.js'), toFrontendConfigScript(config), 'utf8');
await fs.writeFile(path.join(distDir, '404.html'), html, 'utf8');
await fs.writeFile(path.join(distDir, '.nojekyll'), '', 'utf8');

console.log(`[frontend build] config: ${configPath}`);
console.log(`[frontend build] output: ${distDir}`);

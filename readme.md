# Cyber Eyes Frontend

`main` 现在只保留 Cyber Eyes 前端主线：导盲页、开发者页、离线演示页、Node 本地代理/预览服务，以及与后端通信所需的配置和协议说明。

后端运行时和模型部署已经迁移到独立后端仓或独立后端服务。这条主线只承载前端页面、构建链路和协议配置。

## Deployment Modes

- `proxy`: 用户访问前端，前端服务器再代理到本地或同机房后端
- `direct`: 用户分别访问前端和允许的远端后端，浏览器直接连接后端
- `demo`: 访问 `/demo`，不连接任何后端，直接演示常见语音触发

## Repository Layout

- `frontend/`: 页面模板、样式、运行时和默认配置
- `scripts/frontend/`: Node 构建、预览和本地代理入口
- `docs/`: 前端部署说明和前后端协议说明
- `tests/js/`: 前端侧 Vitest 测试

## Quick Start

1. 安装依赖：

```bash
npm install
```

2. 如需本地代理模式，复制一份本地目标配置：

```bash
cp frontend/config/backend-targets.example.json frontend/config/backend-targets.local.json
```

3. 启动开发服务器：

```bash
npm run dev
```

4. 常用入口：

- `/`
- `/cyber-eyes`
- `/dev`
- `/demo`

## Build And Preview

```bash
npm run build
npm run preview
```

构建产物输出到 `dist/`。

## Configuration

- 默认目标配置：[`frontend/config/backend-targets.json`](frontend/config/backend-targets.json)
- 本地覆盖配置：`frontend/config/backend-targets.local.json`
- GitHub Pages / CI 可通过环境变量注入远端目标
- 自定义域名可通过 [`frontend/CNAME`](frontend/CNAME) 或 `CYBER_EYES_PAGES_CNAME` 注入

## Docs

- 前端部署：[`docs/deployment.md`](docs/deployment.md)
- 前后端协议：[`docs/protocol.md`](docs/protocol.md)

## Notes

- 页面中的摄像头和麦克风权限仍要求 HTTPS
- 静态站点默认应优先使用 `direct` 远端后端目标
- 若你需要完整 MiniCPM 后端，请接入独立后端仓或已部署的后端服务

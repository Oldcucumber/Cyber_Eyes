# Cyber Eyes Frontend Deployment

这条 `main` 主线只负责前端部署。后端运行时和模型部署已经迁移到独立后端仓或独立后端服务。

## 1. Local Development

安装依赖：

```bash
npm install
```

如需本地代理模式，先复制一份本地配置：

```bash
cp frontend/config/backend-targets.example.json frontend/config/backend-targets.local.json
```

启动开发服务器：

```bash
npm run dev
```

默认端口是 `3000`。

## 2. Backend Targets

前端只认识两类后端目标：

- `proxy`: 浏览器只访问前端，前端服务器再把 `/status`、`/api/*`、`/ws/*` 代理到目标后端
- `direct`: 浏览器直接请求目标后端

配置文件位置：

- 默认配置：`frontend/config/backend-targets.json`
- 本地覆盖：`frontend/config/backend-targets.local.json`

字段说明：

- `id`: 目标标识
- `label`: 页面中展示的名称
- `mode`: `proxy` 或 `direct`
- `httpBaseUrl`: HTTP 基地址
- `wsBaseUrl`: WebSocket 基地址
- `enabled`: 是否可选
- `description`: 页面上的简短说明

## 3. Proxy Mode

适合本机或同机房部署：

1. 前端 Node 服务对用户开放
2. 前端 Node 服务代理到 MiniCPM 网关
3. 浏览器不直接访问后端

这种模式下，浏览器看到的是单一前端入口。

## 4. Direct Mode

适合 GitHub Pages、Cloudflare Pages 或任何纯静态托管：

1. 用户访问独立前端站点
2. 浏览器直接访问允许的远端后端

这种模式下，后端必须允许当前前端域名：

- CORS
- WebSocket `Origin`

协议要求见 [`docs/protocol.md`](protocol.md)。

## 5. Static Build

构建静态产物：

```bash
npm run build
```

本地预览：

```bash
npm run preview
```

输出目录：

- `dist/`

## 6. GitHub Pages

仓库已包含工作流：

- [frontend-deploy.yml](../.github/workflows/frontend-deploy.yml)

常用环境变量：

- `CYBER_EYES_REMOTE_HTTP_BASE_URL`
- `CYBER_EYES_REMOTE_WS_BASE_URL`
- `CYBER_EYES_ACTIVE_TARGET_ID`
- `CYBER_EYES_REMOTE_TARGET_ID`
- `CYBER_EYES_REMOTE_TARGET_LABEL`
- `CYBER_EYES_REMOTE_TARGET_DESCRIPTION`
- `CYBER_EYES_REMOTE_TARGET_MODE`
- `CYBER_EYES_PAGES_CNAME`

如果是公网静态托管，推荐默认目标直接指向 `direct` 远端后端，而不是 `proxy` 本地代理。

## 7. Custom Domain

可通过以下任一方式写入 `dist/CNAME`：

- [`frontend/CNAME`](../frontend/CNAME)
- `CYBER_EYES_PAGES_CNAME`

另外要在站点侧确保：

- HTTPS 已强制开启
- 域名不会跳回 `http://`
- 如果经由 Cloudflare，SSL 模式为 `Full` 或 `Full (strict)`

## 8. Validation Checklist

部署完成后至少检查：

1. 首页、`/dev`、`/demo` 都能打开
2. `/demo` 不依赖后端即可运行
3. `proxy` 模式下 `/status` 能经由前端代理成功
4. `direct` 模式下状态灯能正确反映后端在线或离线
5. 开发者页切换目标后，新的 HTTP / WS 请求确实切到目标后端
6. 摄像头和麦克风权限只在 HTTPS 下申请

## 9. Backend Runtime

如果你需要完整后端部署，请使用独立后端仓或已部署的后端服务。

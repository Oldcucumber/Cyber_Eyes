# Cyber Eyes Frontend / Backend Protocol

这条 `main` 主线只保留前端，因此前后端之间的契约需要稳定且明确。

## 1. Transport Modes

前端支持两种访问方式：

- `proxy`: 浏览器请求前端，前端再代理到后端
- `direct`: 浏览器直接请求后端

无论哪种模式，后端提供的 HTTP / WebSocket 协议应保持一致。

## 2. Required HTTP Endpoints

### `GET /status`

用于页面状态灯、可用 worker 数和简单排队信息。

前端至少会读取这些字段：

- `idle_workers`
- `total_workers`
- `queue_length`
- `running_tasks`

返回应为 JSON。

### `GET /health`

主要用于调试或快速健康探测。前端本身不强依赖，但建议保留。

### `GET /api/frontend_defaults`

开发者模式下可选。用于回填默认前端参数或 UI 初始值。

### `GET /api/default_ref_audio`

开发者模式下可选。用于加载默认参考音频。

## 3. Required WebSocket Endpoint

### `GET /ws/duplex/{session_id}`

这是主导盲链路的双工会话入口。

前端会发送：

- `prepare`
- `pause`
- `resume`
- `stop`
- 音频 / 图像 chunk 消息

后端至少需要返回这些消息类型：

- `queued`
- `queue_update`
- `queue_done`
- `prepared`
- `result`
- `paused`
- `resumed`
- `stopped`
- `timeout`
- `error`

## 4. Prepare Payload

`prepare` 阶段除了基础提示词外，前端还可能发送：

- `config`
- `ref_audio_base64`
- `tts_ref_audio_base64`
- `assist_context`

其中 `assist_context` 是导盲页整理后的结构化任务上下文，后端应把它视为策略输入，而不是原样播报内容。

## 5. Result Payload

前端当前会消费这些典型字段：

- `is_listen`
- `text`
- `audio_data`
- `end_of_turn`
- `cost_all_ms`
- `wall_clock_ms`
- `kv_cache_length`
- `vision_slices`
- `vision_tokens`
- `server_send_ts`

额外字段可以保留，前端会忽略未知字段。

## 6. CORS And Origin

当模式为 `direct` 时，后端必须允许当前前端域名：

- HTTP CORS
- WebSocket `Origin`

否则静态站点虽然能打开，但状态灯、参考音频和双工会话都会失败。

## 7. Frontend-Side Target Injection

前端通过 `frontend-config.js` 或本地配置文件决定目标后端，核心字段是：

- `defaultTargetId`
- `targets[].id`
- `targets[].mode`
- `targets[].httpBaseUrl`
- `targets[].wsBaseUrl`

只要后端满足本文档中的 HTTP / WebSocket 契约，前端就可以在 `proxy` 和 `direct` 两种模式之间切换。

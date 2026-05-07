# 文件管理器

基于 Go + Flutter 的本机文件管理系统，参考 SPanel 项目提取文件管理功能。

## 功能特性

- 文件浏览：目录列表、路径导航、隐藏文件显示
- 文件操作：创建、重命名、删除、复制、移动
- 文件预览：文本文件在线查看
- 文件上传：支持拖拽上传
- 文件下载：单文件或多文件打包下载
- 压缩解压：支持 tar 格式
- 权限管理：修改文件权限

## 技术栈

| 组件 | 技术 |
|------|------|
| 后端 | Go + Gin |
| 前端 | Flutter Web |
| 数据库 | SQLite (纯Go) |
| 认证 | JWT |

## 项目结构

```
filemanager/
├── main.go                 # 入口
├── go.mod                  # Go 依赖
├── Makefile                # 构建脚本
├── app/
│   └── router.go           # 路由配置
├── handlers/
│   ├── auth.go             # 登录认证
│   └── files.go            # 文件管理
├── models/
│   └── user.go             # 用户模型
├── database/
│   └── db.go               # 数据库初始化
├── security/
│   └── jwt.go              # JWT 工具
├── apiresp/
│   └── response.go         # 响应封装
├── frontend/               # Flutter 前端源码
│   └── lib/
│       ├── main.dart
│       ├── screens/
│       └── services/
└── static/                 # Flutter 编译输出
```

## 快速开始

### 环境要求

- Go 1.21+
- Flutter 3.x (编译前端)

### 构建

```bash
# 完整构建（前端 + 后端）
make build

# 仅构建后端（需已编译前端）
make build-backend

# 仅构建前端
make build-frontend
```

### 运行

```bash
# 默认监听 127.0.0.1:8080
./filemanager

# 指定监听地址
./filemanager -host 0.0.0.0:8080
```

### 默认账号

- 用户名：`admin`
- 密码：`admin123`

### WebDAV 反向代理前缀

当 WebDAV 通过反向代理挂在子路径（例如 `/g/dav`）时，可在 `config.yaml` 中设置：

```yaml
server:
  dav_public_prefix: /g/dav
```

说明：
- 不配置时默认按后端内部路由 `/dav` 处理。
- 配置后会用于 WebDAV 响应中的路径前缀，提升 Finder / 各类 DAV 客户端在反代场景下的兼容性。

## API 接口

### 认证

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/auth/login` | 登录 |
| POST | `/api/auth/change-password` | 修改密码 |

### MCP

- 端点：`GET /mcp`（探活/信息）、`POST /mcp`（JSON-RPC）
- 认证：`Authorization: Bearer <mcp-token>`
- 工具：`shell`

配置示例（`config.yaml`）：

```yaml
mcp:
  token: "your-strong-token"
```

### 文件管理

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/files?path=` | 列出目录 |
| GET | `/api/files/content?path=` | 读取文件 |
| POST | `/api/files/content` | 保存文件 |
| GET | `/api/files/properties?path=` | 文件属性 |
| GET | `/api/files/download?path=` | 下载文件 |
| POST | `/api/files/mkdir` | 创建目录 |
| POST | `/api/files/create` | 创建文件 |
| POST | `/api/files/upload` | 上传文件 |
| POST | `/api/files/copy` | 复制文件 |
| POST | `/api/files/move` | 移动文件 |
| POST | `/api/files/rename` | 重命名 |
| POST | `/api/files/delete` | 删除文件 |
| POST | `/api/files/archive` | 压缩文件 |
| POST | `/api/files/extract` | 解压文件 |
| POST | `/api/files/permissions` | 修改权限 |

## 与原项目差异

| 特性 | SPanel | 文件管理器 |
|------|--------|-----------|
| 服务器管理 | 多服务器SSH连接 | 仅本机 |
| 文件操作 | SSH命令 | Go标准库 |
| 容器管理 | Docker/Incus | 无 |
| 终端 | SSH终端 | 无 |
| 数据库 | SQLite | SQLite |

## 许可证

MIT

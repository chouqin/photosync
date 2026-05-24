# PhotoSync iOS App

基于 SwiftUI 的照片同步 App，连接自建的 PhotoSync 后端。

## 功能

### 核心功能
- 🔐 JWT 登录（密码存在 Keychain）
- 📸 从 iPhone 相册多选上传（最多 50 张）
- 🖼️ 缩略图网格浏览（本地缓存）
- 🔍 双击查看原图（支持捏合缩放）
- 🔄 下拉刷新照片列表

### 🆕 系统图库同步（新功能）

#### 1. 自动上传新照片
- 打开 App 时自动检测相册新照片并上传
- 支持后台任务定期扫描（iOS 系统调度，不保证精确时间）
- SHA-256 去重，避免重复上传
- 首次开启时需要相册读取权限

#### 2. 云端照片保存到本地相册
- 点击单张照片 → 长按/上下文菜单 → "保存到相册"
- 右上角菜单 → "全部保存到相册"（批量下载）
- 原图查看页面 → 点击下载按钮

## 项目结构

```
PhotoSync/
├── PhotoSyncApp.swift          # App 入口
├── Info.plist                  # 权限配置
├── Models/
│   └── Photo.swift             # 数据模型
├── Views/
│   ├── LoginView.swift         # 登录页
│   ├── PhotoGridView.swift     # 照片网格（含同步菜单）
│   └── PhotoDetailView.swift   # 原图查看（含保存按钮）
├── ViewModels/
│   └── PhotoViewModel.swift    # 业务逻辑
└── Utilities/
    ├── APIClient.swift         # 网络层
    ├── KeychainHelper.swift    # Token 持久化
    ├── PhotoLibrarySyncManager.swift  # 系统相册同步
    └── BackgroundTaskManager.swift    # iOS 后台任务
```

## 快速开始

### 1. 创建 Xcode 项目
Xcode → New Project → iOS App：
- Name: **PhotoSync**
- Interface: **SwiftUI**
- Language: **Swift**

### 2. 复制代码
把本目录下的所有 `.swift` 文件拖进 Xcode 项目。

### 3. 配置服务器地址

1. 复制配置文件模板：
   ```bash
   cp PhotoSync/Config.plist.example PhotoSync/Config.plist
   ```

2. 编辑 `PhotoSync/Config.plist`，填入你的服务器地址：
   ```xml
   <dict>
       <key>baseURL</key>
       <string>http://your-vm-ip-or-domain.com</string>
   </dict>
   ```

   或本地调试时用 `http://localhost:8000`。

3. 在 Xcode 中，确保 `Config.plist` 已加入 **Build Phases → Copy Bundle Resources**。

### 4. 配置 Info.plist
在 Xcode 中打开 `Info.plist`，添加：

```xml
<!-- 允许 HTTP 访问（VM 暂时没有 HTTPS） -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>

<!-- 相册读取权限 -->
<key>NSPhotoLibraryUsageDescription</key>
<string>PhotoSync 需要访问您的相册来读取和上传照片</string>

<!-- 相册写入权限 -->
<key>NSPhotoLibraryAddUsageDescription</key>
<string>PhotoSync 需要将云端照片保存到您的相册</string>

<!-- 后台任务 ID -->
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.photosync.backgroundupload</string>
</array>

<!-- 后台运行模式 -->
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>
```

> **注意**：`NSAllowsArbitraryLoads` 允许 HTTP（非 HTTPS）访问。生产环境请使用 HTTPS + 域名。

### 5. 启用后台刷新
Xcode → Signing & Capabilities → + Capability → **Background Modes**
勾选：
- ✅ Background fetch
- ✅ Background processing

### 6. 运行
1. 连接 iPhone 或选择 Simulator
2. 点击 Run
3. 输入后端配置的密码登录（默认在 `.env` 中设置）
4. 点击右上角 **⋯** 菜单 → **自动同步新照片**（开启自动上传）
5. 点击右上角 **+** 选择照片上传

## 使用说明

### 自动上传新照片
1. 进入照片网格页
2. 点击右上角 **⋯** → **自动同步新照片**
3. App 会自动检测相册中的新照片并上传
4. 上传记录通过 SHA-256 去重，不会重复上传

**限制**：
- iOS 后台运行受限，App 完全关闭后无法自动同步
- 最可靠的同步时机是用户打开 App 时
- 后台刷新由 iOS 系统调度（通常 15-30 分钟一次）

### 保存云端照片到本地
**单张保存**：
- 长按网格中的照片 → "保存到相册"
- 或点击查看原图 → 点击下载按钮

**批量保存**：
- 点击右上角 **⋯** → **全部保存到相册**
- 确认后开始批量下载

### 首次开启自动上传
系统会弹出权限请求：
- **允许访问所有照片**：推荐，可以完整扫描相册
- **选中的照片**：功能受限，只能访问手动选择的照片
- **不允许**：无法使用自动上传功能

## 安装到真机

### 方案 1：免费开发者账号（7天续签）

1. Xcode → Preferences → Accounts → 登录 Apple ID
2. Signing & Capabilities → Team 选你的个人账号
3. 连上 iPhone → 选设备 → Run
4. 设置 → 通用 → VPN与设备管理 → **信任开发者**

### 方案 2：TestFlight（$99/年）

需要 Apple Developer Program，可分发到最多 10,000 台设备。

## API 端点

| 端点 | 说明 |
|------|------|
| `POST /api/auth/token` | 登录 |
| `GET /api/photos` | 照片列表 |
| `POST /api/photos/upload` | 上传照片 |
| `GET /api/photos/{id}/thumbnail` | 缩略图 |
| `GET /api/photos/{id}/original` | 原图 |

## iOS 权限说明

| 权限 | 用途 | 是否必须 |
|------|------|---------|
| 相册读取 | 自动上传新照片 | 否（手动上传不需要）|
| 相册写入 | 云端照片保存到本地 | 否 |
| 后台刷新 | App 关闭后自动检查新照片 | 否 |

## 注意事项

- 首次启动需要输入后端密码（在服务器 `.env` 中配置）
- Token 自动保存在 iOS Keychain，下次启动免登录
- 缩略图缓存在内存中，App 重启后重新加载
- 上传时保持 App 在前台，后台上传受 iOS 限制
- 云端照片保存到本地需要 **相册写入权限**

# SecretBox MAUI

基于现有 SwiftUI 客户端设计的 Windows / Android 原生客户端子项目。使用 .NET 10 MAUI；不改变 `SecretBox/`、`server/` 或 `mcp-server/`。

## 项目结构

```text
MAUI/
  SecretBox.sln
  SecretBox.Core/          # 数据模型、捕获解析、搜索、TOTP、权限、加密存储、HTTP 适配器
  SecretBox.Maui/          # 原生 MAUI UI、依赖注入、平台安全存储与身份验证
    Views/                # 详情、编辑、设置
    Services/             # SecureStorage 密钥、系统验证、剪贴板
    Platforms/Android/    # Android Activity、Manifest
    Platforms/Windows/    # WinUI 入口、Manifest
  SecretBox.Core.Tests/    # xUnit 安全与业务回归
  scripts/verify.ps1       # 测试及双平台构建
```

## 构建与运行

需要 .NET 10 SDK、MAUI Windows / Android 工作负载，以及 Android SDK 36 和兼容 JDK。Windows 构建须在 Windows 上完成。建议使用安装了 .NET MAUI 工作负载的 Visual Studio，打开 `SecretBox.sln`，将 `SecretBox.Maui` 设为启动项目。

在仓库根目录执行：

```powershell
dotnet workload restore MAUI/SecretBox.Maui/SecretBox.Maui.csproj
dotnet restore MAUI/SecretBox.sln
dotnet test MAUI/SecretBox.Core.Tests/SecretBox.Core.Tests.csproj

# Windows（非 MSIX 打包，便于本地开发）
dotnet build MAUI/SecretBox.Maui/SecretBox.Maui.csproj -f net10.0-windows10.0.19041.0
dotnet build MAUI/SecretBox.Maui/SecretBox.Maui.csproj -f net10.0-windows10.0.19041.0 -t:Run

# Android APK；运行前连接设备或启动模拟器
dotnet build MAUI/SecretBox.Maui/SecretBox.Maui.csproj -f net10.0-android
dotnet build MAUI/SecretBox.Maui/SecretBox.Maui.csproj -f net10.0-android -t:Run

# 顺序运行测试、Windows 构建及 Android 构建
pwsh -File MAUI/scripts/verify.ps1
```

目标：Windows 10 1809+ / Windows 11；Android 6.0（API 23）及以上。构建输出在各项目的 `bin/`，Android Debug APK 位于 `SecretBox.Maui/bin/Debug/net10.0-android/`。正式发布仍需配置发布证书、签名与分发流程。

Android Debug 包显式包含托管程序集，可通过 `adb install -r MAUI/SecretBox.Maui/bin/Debug/net10.0-android/com.secretbox.maui-Signed.apk` 安装，不依赖 IDE 的快速部署目录。

不要以命令行全局 `-p:TargetFrameworks=...` 缩减目标框架，它会传递给 Core 项目；使用 `-f` 选择构建目标。不要并发构建共享同一 `obj/` 的平台目标。

## 已实现

- 宽屏（至少 1000 DIP）分类、列表、详情三栏；窄屏通过原生导航查看详情。
- 浅色 / 深色主题、空状态、关键词搜索、按模板筛选、区分大小写的密码精确匹配。
- 本地创建、编辑、删除；Redis / 数据库 URI、逐行键值账号、S3 / Kafka / AKSK 字段与纯 TOTP 的快速捕获。解析在本机进行，预览后可修正。
- Base32 / `otpauth://` 两步验证；RFC 6238 SHA1/256/512、6–8 位、15–120 秒。验证码在设备生成；已保存种子不回显。
- 只读、隐藏秘密、使用前重新验证、三级 AI 权限元数据；只读解锁需要系统验证。
- Windows Hello 与 Android 系统锁屏凭据验证。设备未配置验证或用户取消时拒绝受保护操作。
- 密码默认不显示；允许显示时通过权限检查后切换显示/隐藏，窗口失去焦点时重新遮盖。已有密码编辑时留空表示保留。验证码在隐藏或需要重新验证时也不自动显示。复制使用受权限检查的独立路径。
- 剪贴板在 30 秒后尝试清除，只有内容仍与本次复制一致时才清除；操作系统暂停应用时无法保证定时执行。
- 设置页检测现有 FastAPI `/health`；Core 提供 `/api/search` 和记录 POST/PUT 适配器，并有 JSON 契约测试。

## 安全与数据边界

保险库位于平台 `FileSystem.AppDataDirectory/vault.sbx`，整个文件使用 AES-256-GCM 加密。格式为 `SBX1` 头、12 字节随机 nonce、16 字节认证标签及密文；每次保存产生新的 nonce。加密后写入临时文件，再替换原文件，失败不会提前更新会话记录。

32 字节随机密钥单独保存在 MAUI `SecureStorage`，不写入 Preferences、日志或仓库。Windows 使用系统数据保护，Android 使用 Keystore 支持的安全存储。Android 禁用应用备份与普通屏幕截取。平台实现依据：[Microsoft SecureStorage 文档](https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/storage/secure-storage?view=net-maui-10.0)。

加载、密钥读取或完整性验证失败时禁止继续写入；不会用空保险库覆盖原文件。此版本没有主密码、密钥恢复或自动同步，卸载/清理应用数据可能导致本地记录不可恢复；应用入口使用当前系统用户会话，不复制 Swift 版本的演示账号登录。

TOTP 和密码只进入专用字段。捕获原文不存入备注；元数据校验拒绝已知秘密、TOTP URI、带密码的 URL 及秘密类型字段。HTTP 适配器不发送原始粘贴文本，不记录请求/响应正文，不展示服务端错误正文。它仍向现有服务器发送专用密码/TOTP 字段，这与 Swift 客户端 API 契约一致，不是端到端加密协议。

## 与 Swift 版本的范围差异

- 当前客户端以本地保险库为主。设置中的服务器地址仅用于连接检测，HTTP 适配器尚未接入界面读写；没有完整同步、冲突合并或远程删除。
- 没有 AI Provider 调用、智能重聚类、团队共享或自动填充扩展。
- 没有接入现有 macOS Keychain MCP 服务，AI 权限只保留模型语义；不提供无法解析的“AI 引用”按钮。
- 没有 Windows 托盘、全局快捷键或 Android 扫码；TOTP 支持手动输入和 URI 捕获。
- 服务连接设置只接受 HTTPS；Android 禁止明文 HTTP。现有开发服务器默认 HTTP，需通过可信 HTTPS 反向代理进行连接检测。
- 当前后端尚无真实认证。不要将此客户端的权限 UI 理解为后端授权机制。

## 验证

自动测试覆盖 RFC TOTP 向量、URI 解析和秘密分离、精确搜索、AES-GCM 往返与篡改拒绝、存储失败时保持内存状态、只读/重新验证拒绝路径及服务端 JSON 契约。

人工验收：新建 → 粘贴捕获 → 修正 → 保存 → 搜索 → 详情 → 复制；重启后记录仍可用；编辑时密码/种子不回显；配置系统凭据后检查只读解锁及取消重新验证；调整 Windows 窗口宽度或旋转 Android 屏幕检查导航；检查深浅色与软键盘下保存按钮。

构建通过不等于真机验收通过，平台安全存储、Windows Hello、Android 锁屏验证及剪贴板生命周期需要在实际运行环境验证。

沿用仓库根目录的 AGPL-3.0 / 商业双重许可约定。

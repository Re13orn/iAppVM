# iAppVM

[![构建](https://github.com/Re13orn/iAppVM/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/Re13orn/iAppVM/actions/workflows/build.yml)
[![公开预览版](https://img.shields.io/badge/preview-v3.8.46--preview.1-blue)](https://github.com/Re13orn/iAppVM/releases/tag/v3.8.46-preview.1)
[![许可证 AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

iAppVM 是面向非越狱 iPhone 和 iPad 的 iOS 应用测试容器。它把 IPA 导入、运行诊断、网络分析、Frida 调试和数据检查放在同一个工作台里。源码已开源，首个公开预览版提供可重签名的 iOS IPA 和 Apple Silicon Mac 安装助手。

- **运行和诊断** · 为导入的 App 准备独立测试窗口，从启动诊断查看签名、配置和进程状态。
- **网络分析** · 按 App 查看可捕获的请求、配置代理、分析 TLS 证书与认证，并按需启用测试用的 Pinning 绕过和客户端身份导出。
- **Frida 调试** · 为不同 App 配置 Gadget、自动脚本或电脑连接，分开查看各来源的日志。
- **数据检查** · 浏览和导出容器文件，查看 SQLite 和 Guest Keychain，备份并比较沙盒。

请使用自有或已获授权的测试 App。导入的 IPA 须已解密，运行需要有效签名。网络分析覆盖受支持的路径，Guest 之间没有系统 App 级别的隔离。完整性校验、系统权限或扩展依赖也会影响兼容性。流量和身份导出可能包含认证头、会话数据和私钥，分享前请检查内容。

## 下载与首次运行

打开 [GitHub Release](https://github.com/Re13orn/iAppVM/releases/tag/v3.8.46-preview.1)，在 **Assets** 选一种安装方式。

| 你的情况 | 下载与操作 |
| --- | --- |
| 有 Apple Silicon Mac（macOS 14 或更新）和 USB 线 | 下载 `iAppVM-Installer-0.1.0-arm64.zip`。解压后打开安装助手，用自己的 Apple 账号登录并按提示完成设备安装和手机签名配置。安装助手自带 iOS 宿主。[详细步骤和常见错误](MacInstaller/README.md) |
| 已有自己的 iOS 签名流程 | 下载 `iAppVM-3.8.46-unsigned.ipa`，用包含目标设备的开发签名和描述文件重签后再安装。独立测试窗口还需要正确签名的 `LiveProcess` 扩展。[签名要求和仓库脚本](docs/DEVICE-SIGNING.md) |

首次打开 iAppVM 时按设备提示完成开发者模式或信任。**宿主能打开和宿主能为导入的 App 签名是两个检查点。** 如果目标 App 显示「尚未完成签名」，在 iAppVM 设置中配置与宿主匹配的签名身份，再回到目标 App 的签名入口。安装助手用户以最后一步的手机签名自检回执为准。[手机签名说明](docs/DEVICE-SIGNING.md#phone-signing)

初次验证可下载 [iOSVMDemo.ipa](https://github.com/Re13orn/iAppVM/releases/download/v3.8.46-preview.1/iOSVMDemo.ipa)。把它存到 iPhone 的「文件」，在 **iAppVM 内**导入并启动，点击「写入测试文件」，再到该 App 的「浏览沙盒」查看 `Documents/iosvm-demo.json`。看到文件即完成导入、运行和沙盒读取的检查。

遇到问题时，在报告里注明 iAppVM 版本、设备和系统版本、卡住的步骤及错误文本。提交前移除账号、设备标识、认证头和密钥。[报告问题](https://github.com/Re13orn/iAppVM/issues/new?template=bug_report.yml)

## 从源码构建

需要 Apple Silicon Mac、Xcode 26.2 和对应的 iOS SDK，以及 Python 3 和 `xz`。从 Git 检出根目录执行：

```sh
bash scripts/build-prototype.sh
```

脚本初始化 OpenSSL 和 litehook 子模块，校验并准备固定版本的 Frida 资源，编译宿主和自有 Demo，验证 IPA 结构与签名元数据。输出为 `build/iOSVM-unsigned.ipa` 和 `build/iOSVMDemo.ipa`。前者需要使用与你的设备匹配的开发者身份重新签名。

签名安装后，打开 iAppVM，在设置中配置与宿主描述文件匹配的手机签名身份。导入自有 Demo，启动后点击“写入测试文件”，再从其数据容器中检查 `Documents/iosvm-demo.json`。这条流程可用来验证 IPA 导入、运行与沙盒查看。

如需运行完整本地回归，还需安装 Node.js。构建完成后执行：

```sh
bash scripts/run-regression.sh build/iOSVM-unsigned.ipa
```

[设备签名说明](docs/DEVICE-SIGNING.md) · [Mac 安装助手预览](MacInstaller/README.md)

## iAppVM Skill

[iAppVM Skill](skills/iappvm/SKILL.md) 提供 IPA 导入、Frida Gadget 和脚本、USB 调试、沙盒与单 App 代理的操作和排查指南，附带诊断 JS 和 Frida CLI 参数生成工具。

在 Codex 中，将整个 `skills/iappvm` 目录复制到 `~/.codex/skills/`，在新会话里用 `$iappvm` 调用。目录内的脚本和参考资料需要一并保留。

## 来源和许可证

iAppVM 基于 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 修改，上游基线为 `4dbe0f9a626de801184a42c0be8d2cb105058e3d`。iAppVM 对分析工作台、测试窗口、Frida、网络和签名流程进行了扩展。

项目沿用 GNU AGPL-3.0。第三方组件保留各自的许可和声明。

[项目许可证](LICENSE) · [上游贡献者署名](docs/UPSTREAM-CREDITS.md) · [第三方组件](docs/THIRD-PARTY.md)

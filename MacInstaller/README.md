# iAppVM 安装助手

安装助手是 Apple Silicon Mac 上的本地预览工具，支持 macOS 14 或更新系统。它把 USB 设备选择、Apple 账号认证、iOS 签名、安装和手机签名配置串在一个窗口里。

## 下载与打开

从 [GitHub Release](https://github.com/Re13orn/iAppVM/releases/tag/v3.8.46-preview.1) 下载 `iAppVM-Installer-0.1.0-arm64.zip`。ZIP 内已包含 iOS 宿主和安装所需的工具，解压即可开始，使用者无需安装 Xcode 或 Rust。

如果 macOS 首次拦截，确认 ZIP 来自上面的 Release 并核对 SHA-256 后，打开「系统设置 → 隐私与安全性」，找到刚被拦截的应用，选择「仍要打开」。[Apple 打开下载应用的说明](https://support.apple.com/102445)

## 安装与配置

1. 打开安装助手，通过 USB 连接并解锁 iPhone，按系统提示信任电脑。
2. 选择设备，输入自己的 Apple 账号和密码。按提示完成验证码和开发团队选择。
3. 如找到与团队匹配的本机 RSA 开发身份，确认后可复用该证书。系统可能提示允许访问所选钥匙串私钥。
4. 安装后，按设备提示信任开发者并打开 iAppVM。助手会等待手机签名自检回执。

同一团队使用固定的 `com.iappvm.container.<TeamID>`，可覆盖更新助手安装的实例。不同团队或其他 App ID 对应不同实例。

Apple 密码仅在本次登录中使用。账号认证请求发往 Apple，默认由 [iloader 的 Anisette 服务](https://ani.iloader.app) 提供设备认证数据。服务地址可在连接设置中修改。签名身份保存在本机与手机的钥匙串中，手机的一次性传输文件在应用读取后删除。

若 Apple 返回证书名额错误 7460，需要使用本机已有、与该团队匹配的开发证书和私钥，或在原签名电脑管理已有证书。助手仅在符合条件时复用或申请证书。

如果设备列表为空，先解锁 iPhone、确认 USB 线支持数据传输，在手机点「信任」后刷新设备列表。若 iAppVM 已装好但最后一步仍在等待，解锁并在手机上打开 iAppVM。若助手仍未收到回执，按 [手机端签名说明](../docs/DEVICE-SIGNING.md#phone-signing) 核对签名配置。

## 构建

在仓库根目录执行：

```sh
python3 MacInstaller/build.py
bash MacInstaller/check.sh
```

构建需要与 [iOS 宿主](../README.md) 相同的工具，以及 Rust 和 Cargo。依赖版本记录在 `Backend/Cargo.lock`。产物位于 `build/MacInstaller/`。预览包采用 ad-hoc 签名。

## 验证范围

本地检查覆盖设备选择、界面状态、后端回执、签名身份匹配和手机签名状态机。已验证真实 Apple 账号能进入证书准备阶段。证书复用之后的真机安装和手机签名自检仍待完整验收。

[第三方组件和许可证](../docs/THIRD-PARTY.md)

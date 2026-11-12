# iAppVM

iAppVM 是面向非越狱 iPhone 和 iPad 的 iOS 应用测试容器。它把 IPA 导入、运行诊断、网络分析、Frida 调试和数据检查放在同一个工作台里。项目目前处于源码预览阶段。

- **运行和诊断** · 为导入的 App 准备独立测试窗口，从启动诊断查看签名、配置和进程状态。
- **网络分析** · 按 App 查看可捕获的请求、配置代理、分析 TLS 证书与认证，并按需启用测试用的 Pinning 绕过和客户端身份导出。
- **Frida 调试** · 为不同 App 配置 Gadget、自动脚本或电脑连接，分开查看各来源的日志。
- **数据检查** · 浏览和导出容器文件，查看 SQLite 和 Guest Keychain，备份并比较沙盒。

请使用自有或已获授权的测试 App。导入的 IPA 须已解密，运行需要有效签名。网络分析覆盖受支持的路径，Guest 之间没有系统 App 级别的隔离。完整性校验、系统权限或扩展依赖也会影响兼容性。流量和身份导出可能包含认证头、会话数据和私钥，分享前请检查内容。

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

## 来源和许可证

iAppVM 基于 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 修改，上游基线为 `4dbe0f9a626de801184a42c0be8d2cb105058e3d`。iAppVM 对分析工作台、测试窗口、Frida、网络和签名流程进行了扩展。

项目沿用 GNU AGPL-3.0。第三方组件保留各自的许可和声明。

[项目许可证](LICENSE) · [上游贡献者署名](docs/UPSTREAM-CREDITS.md) · [第三方组件](docs/THIRD-PARTY.md)

# 第三方组件

| 组件 | 源码与声明 |
| --- | --- |
| iOS 宿主上游 | [上游贡献者署名](UPSTREAM-CREDITS.md)和[项目许可证](../LICENSE) |
| OpenSSL、litehook | 仓库记录的子模块提交与各自源码中的许可证，见 [.gitmodules](../.gitmodules) |
| Frida Gadget、gum-graft | [Frida 17.7.3 源码发布](https://github.com/frida/frida/releases/tag/17.7.3)。构建脚本锁定资产版本和 SHA-256，许可文本位于 [TestTools/Frida/licenses](../TestTools/Frida/licenses) |
| Frida 脚本支持和 Acorn | [脚本来源清单](../TestTools/Frida/ScriptSupport.bundle/provenance.json)及同目录许可证 |
| CydiaSubstrate 兼容框架 | [随框架保留的声明](../Resources/Frameworks/CydiaSubstrate.framework/LICENSE) |
| Nyxian HWHook | [参考的硬件断点实现](https://github.com/emexlab/Nyxian/tree/350dd8dbeb796bc0ff5bc91ef770f1a2994432e7/Frameworks/HWHook)，本仓库 SDK 保留来源说明 |
| SSL Kill Switch 3 | [参考来源的许可声明](../Resources/SSLKillSwitch3-LICENSE.txt) |
| Mac 安装助手依赖 | [Cargo 锁文件](../MacInstaller/Backend/Cargo.lock)及构建产物中的许可清单。修改过的 apple-codesign-quick 源码、许可证和修改说明位于 [Vendor](../MacInstaller/Backend/Vendor/apple-codesign-quick) |

发布二进制时，应为具体发布标签提供相应源码、构建脚本以及适用的第三方声明。Mac 安装助手包含 iOS 宿主，因此安装助手源码 ZIP 只能作为整个发布版本的补充。

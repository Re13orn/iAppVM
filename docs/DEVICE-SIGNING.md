# 设备签名

下载的宿主 IPA 需要用包含目标 iPhone 的开发签名重新签名。已有签名工具时，确认工具能签名 IPA 内的框架和 dylib，并为要保留的扩展提供匹配的描述文件。需要独立测试窗口时，宿主 App ID 和宿主 App ID 加 `.LiveProcess` 各需要一个显式开发描述文件，使用同一 App ID 前缀，包含同一开发证书和目标设备。没有扩展描述文件时，仓库脚本也能生成单进程宿主。[Apple 开发描述文件说明](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/)

## 使用仓库脚本签名

这个脚本读取源码编译产物。先按 [源码构建步骤](../README.md#从源码构建) 执行 `bash scripts/build-prototype.sh`。确认描述文件有效，目标 UDID 已登记，且钥匙串中有匹配开发证书的私钥。用 `security find-identity -v -p codesigning` 查看证书 SHA-1 指纹。将下面的路径、指纹和 UDID 替换为自己的值。

```sh
python3 scripts/sign-device-host.py \
  --profile /path/to/host.mobileprovision \
  --identity '<开发证书的 SHA-1 指纹>' \
  --udid '<设备 UDID>' \
  --test-windows \
  --liveprocess-profile /path/to/extension.mobileprovision
```

只需要单进程宿主时，省略 `--test-windows` 和 `--liveprocess-profile`。

签名后的宿主位于 `build/device/iOSVM.app`。使用 Xcode 的 Devices and Simulators 或 `xcrun devicectl device install app` 安装。首次打开时按设备提示配置开发者模式和开发者信任。

<a id="phone-signing"></a>

## 配置手机端签名

宿主首次能打开后，在 iAppVM 设置中选择「导入手机签名证书（.p12）」，导入与宿主签名匹配、包含私钥的 PKCS#12，并输入该文件的密码。换电脑时，如果原签名的私钥只在旧电脑上，需要从旧电脑导出原签名身份，或用新的身份和匹配的描述文件重新签名宿主。安装助手可在安装时尝试配置这一步。

用仓库脚本签名的用户也可在同一个构建目录执行 `python3 scripts/configure-device-signing.py`。脚本读取上次签名保存的设备和证书信息，通过 USB 配置手机签名。完成后，可在 iAppVM 中导入自有 Demo 验证。

开发描述文件到期后，更新签名并覆盖安装同一 App ID。覆盖安装保留原 App 的数据。不同的 App ID 对应不同的安装实例。

`devicectl device copy to --remove-existing-content true` 可能清除目标应用数据域内超出目标路径的内容。更新安装或传入单个文件时，省略此选项。

# 设备签名

先在项目根目录执行 `bash scripts/build-prototype.sh`，得到宿主构建和自有 Demo IPA。签名使用你自己的 Apple 开发证书，设备必须在描述文件中。

若需要独立测试窗口，准备两个开发描述文件。一个对应你的宿主 App ID，另一个对应宿主 App ID 加 `.LiveProcess`。使用钥匙串中匹配的签名身份执行：

```sh
python3 scripts/sign-device-host.py \
  --profile /path/to/host.mobileprovision \
  --identity '<开发证书的 SHA-1 指纹>' \
  --udid '<设备 UDID>' \
  --test-windows \
  --liveprocess-profile /path/to/extension.mobileprovision
```

签名后的宿主位于 `build/device/iOSVM.app`。使用 Xcode 的 Devices and Simulators 或 `xcrun devicectl device install app` 安装。首次打开时按设备提示配置开发者模式和开发者信任。

宿主启动后，在 iAppVM 设置中导入同一签名身份的 PKCS#12，或在构建电脑执行 `python3 scripts/configure-device-signing.py`。脚本读取本次签名保存的设备和证书配置，通过 USB 配置手机签名。之后即可导入并签名自有 Demo。

开发描述文件到期后，更新签名并覆盖安装同一 App ID。覆盖安装保留原 App 的数据。不同的 App ID 对应不同的安装实例。

`devicectl device copy to --remove-existing-content true` 可能清除目标应用数据域内超出目标路径的内容。更新安装或传入单个文件时，省略此选项。

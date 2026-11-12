# Frida 模式、电脑连接与脚本适配

## 两种模式先选一种

| 需求 | 模式 | 运行方式 |
|---|---|---|
| 手机自行执行一个或多个 JS | 自动脚本 `script-directory` | 脚本库 → 每 App 选择 → 开启自动 → 保存 → 重启 |
| 交互 REPL、电脑临时加载 JS | 电脑连接 `listen` | 关闭自动 → 导出此 App 连接包 → 重启 → USB 转发 → 客户端 |

在 App 的 Frida 页读取实际端口，或从它刚导出的 `FridaGadget.config` 读取 `interaction`。不沿用别的 App、旧设备或旧配置；切换模式后旧连接包也可能过期。默认监听手机 `127.0.0.1`，不是可直接用手机 Wi-Fi IP 访问的全局服务。

## 首选：导出电脑连接包

「Frida 调试 → 电脑连接 → 生成电脑连接包 → 分享连接包」。解压后 README 给出当前 App 的真实版本、端口、脚本文件名和是否需要 resume。包内含口令，作为私有调试材料保存。

配置中的 `interaction.type` 必须为 `listen`。示例占位符要替换为实际值，尖括号不是可执行参数：

```bash
# 在连接包目录，单独环境；先把示例版本改成当前 Gadget 版本。
GADGET_VERSION=17.7.3  # 仅为示例；替换为当前目标的实际版本
python3 -m venv .venv
.venv/bin/python -m pip install "frida==$GADGET_VERSION" frida-tools
```

上面的版本号仅演示赋值格式，应从目标 App 的版本页或连接包 README 获取。Linux/macOS 通常使用 `.venv/bin/`，Windows 通常使用 `.venv/Scripts/`，按实际环境替换，不要求固定桌面平台。

安装 `frida-tools` 后确认 `.venv/bin/python -c 'import frida; print(frida.__version__)'` 仍匹配 Gadget；若依赖解析冲突，选择兼容 tools 版本，不把已钉住的运行库升级掉。

另一个终端运行 USB 转发：

```bash
# DEVICE_PORT 来自所选 App 的 listen 配置，不能直接执行占位值。
DEVICE_PORT='实际设备端口'
# 只有一台设备时通常无需指定 UDID。
iproxy -s 127.0.0.1 "27043:$DEVICE_PORT"
```

有多台设备时，按当前 USB 工具列出的设备标识加 `-u 实际UDID`；先查看 `iproxy --help` 核对安装版本语法。未安装 iproxy 时使用所在系统可用的 USB 转发实现，保持“电脑本地端口 → 所选设备 Gadget 端口”的关系。

电脑 27043 只是例子，若占用选择其他空闲本地端口，并同步客户端地址；不终止用户原有转发器。

### 正常 frida CLI（用户想用熟悉的命令时）

使用 Skill 自带工具把私有配置转换为 `-O` 文件：

```bash
# /path/to/iappvm 是本 Skill 的实际目录；连接包 config 来自所选 App。
python3 /path/to/iappvm/scripts/make-cli-options.py \
  --config FridaGadget.config \
  --address 127.0.0.1:27043 \
  --output connection.options
.venv/bin/frida -O connection.options -n Gadget -l diagnose.js
```

先启动手机目标；先导入/复制 Skill 的 `assets/diagnose.js` 到工作目录。工具不会打印 token，也不会连接设备；输出文件须私有保存，Unix 创建权限为 0600；Windows 应放在用户私有目录并确认访问控制，不能把 Unix mode 当作 Windows ACL 保证。重复生成时另选文件名或明确处理旧文件。`-O` 文件让 token 不出现在进程命令参数中。当前 CLI 的参数以本机 `frida --help` 为准。

这里连接的是 Gadget 远端接口，而非 `frida -U -f 原始BundleID`。它只提供自身虚拟进程；需要时先用当前工具的进程列表确认名称/PID。普通 CLI 没有 iAppVM 心跳/日志回传，UI 可能仍显示“未确认”。CLI 的多个 `-l` 不当作 iAppVM 自动模式独立上下文的等价实现；需要隔离保证时使用下面的配套客户端。

### 配套客户端（需要手机回执、多独立脚本时）

```bash
.venv/bin/python frida-connect.py \
  --address 127.0.0.1:27043 \
  --config FridaGadget.config \
  --script diagnose.js \
  --script second.js \
  --initialize-scripts \
  --duration 3600 \
  --output session.json
```

只加载存在的脚本；不需要第二个就移除对应参数。`--script` 可重复，每个独立 JS 上下文。`--initialize-scripts` 会调用已导出的 `rpc.exports.init(stage, {})`，是可选的；脚本需避免顶层初始化和 init 重复装 Hook。`--duration` 为大于 0、至多 3600 秒，不传默认仅 10 秒。

以上配套命令仅在导出的包内确实包含 `frida-connect.py` 与 `client-monitor.js` 时使用；脚本和配置按包内 README 定位。不要把本 Skill 的 CLI 参数工具误当成配套连接客户端，也不要要求用户有开发仓库。缺少客户端时仍可走标准 CLI，但不会自动获得手机回执。

配套客户端回传心跳及带脚本名的 console/send/error；二进制消息附件不落盘。正常退出会尝试标记断开和 detach，客户端加载的脚本随 session 卸载；日志报告保存在指定 output。自动脚本则随目标进程退出，不受电脑 Ctrl+C 控制。

## 早期加载、等待与白屏

- `on_load=resume`：目标直接启动，后连接可能错过早期调用。
- `on_load=wait`：Gadget 构造阶段等待，界面可能尚未建立；不能仅据白屏诊断闪退。
- 需要早期脚本时，使用App 导出包的配套客户端加 `--resume`；它通过 `re.frida.Gadget` spawn-gate、attach、加载脚本后 resume。不要只 attach 后再猜早期 Hook 是否已装好。
- 非等待模式不需要 `--resume`。实际闪退要检查进程/崩溃证据；早期脚本若等待某个“主线程 UI 事件”，该事件可能要等初始化返回，避免形成等待环。

## Frida 17 与脚本能力

诊断顺序：无桥接诊断 JS → 语言桥接加载 → 确认类/模块出现时机 → 所需 Hook 方法与签名能力。

Frida 17 把 ObjC/Swift 等桥接从运行库分离。CLI REPL 对桥接的便利加载不适用于所有原始 Gadget/Python JS。需要 ObjC 的自动脚本可以在独立电脑目录准备：

```bash
npm init -y
npm install frida-objc-bridge
npm install --save-dev frida-compile @types/frida-gum
# index.js 中写 import ObjC from 'frida-objc-bridge'; 并加入实际诊断/测试代码。
npx frida-compile index.js -o agent.js
```

把编译后的 `agent.js` 导入 iAppVM；原始 ESM `import` 文件不能直接当作已打包脚本。桥接包与工具版本按目标 Gadget 核对，不无条件更新用户现有项目依赖。Swift 也按对应桥接与当前官方文档处理。Frida 16/17 的模块导出查找 API 有变化，先检查实际 API，不盲用旧 `Module.findExportByName` 或新 `Module.getGlobalExportByName`。

默认 QJS、`code_signing=required`。JS 能运行、ObjC 可用、某类存在，都不能证明任意 `Interceptor.attach/replace`、Stalker 或 JIT 代码可用。现有无调试器实验依赖 gum-graft 提前插桩及重签名，只能覆盖已准备的目标；改 JS 不会自动给新函数生成 graft。不要对系统库/Dart 任意地址承诺通用支持，也不要为了修复脚本擅自修改二进制或换代码签名策略。

## 常见报错

| 现象 | 最先检查 |
|---|---|
| iproxy `Connection refused` | 目标是否还在运行；是否启用自动模式；转发的设备端口是否等于当前配置；Gadget 本次加载是否成功 |
| `ServerNotRunningError` | 对照上项，再检查 iproxy 是否活着、设备 UDID 和本地地址；不先安装全局 frida-server |
| 认证失败 | 是否使用此 App 最新连接包，token 是否被旧配置覆盖；不在聊天/日志打印 token |
| 找不到 bundle ID / 无法枚举其他进程 | Gadget 自身接口限制；使用 `Gadget`/当前 PID，而非系统应用清单 |
| `ObjC is not defined` | 是否 Frida 17 原始 JS 未打包语言桥接 |
| `unable to intercept` / 签名相关终止 | 检查签名策略与目标函数是否具备既有插桩/调试条件；这不是连接故障 |
| JS 有输出但没 Hook 到 | 目标实例、函数/模块、调用是否发生、安装时机与插桩支持分别验证 |
| init 无输出 | 普通 create_script 不自动调用用户 RPC；配套客户端需 `--initialize-scripts`，或脚本自行顶层初始化 |
| 手机显示未连接但 REPL 正常 | 普通 CLI 不回传；看实际 attach 和脚本输出 |
| 多个 JS 的变量不可见 | iAppVM 自动模式/配套客户端刻意隔离上下文；有依赖先打包 |
| 脚本修改后没变化 | 真正退出并重启目标、确认选中的脚本 UUID/容器，以及当前仍是期望模式 |

官方来源：[Gadget](https://frida.re/docs/gadget/)、[Frida 17 发布说明](https://frida.re/news/2025/05/17/frida-17-0-0-released/)。

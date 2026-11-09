# KVM Bridge

让一台显示器和一套键鼠在 **macOS** 与 **Windows** 两台主机之间共用。两端程序完全对等，任意一端都能切换屏幕、切换键鼠模式。

当前版本：**0.5.3**

0.5.3 修复：切回 Mac 时不再无条件重配显示模式（该操作会短暂中断视频输出，造成「无信号」闪烁）；两端静止时不再轮询 DDC，避免占用显示器 I2C；Windows 端声明 DPI 感知并拦截光标回中产生的伪位移（光标乱跳）；Mac 端把注入坐标夹在屏幕边界内，避免贴边后内部坐标漂移。

---

## 功能

| 功能 | 说明 | 是否依赖网络 |
|---|---|---|
| 屏幕切换 | 通过显示器 DDC/CI（VCP `0x60`）切换输入源 | **不依赖**，纯本地 |
| 端口识别 | 检测输入端口类型（USB-C / DP / HDMI / VGA…），能识别所连主机时显示 macOS / Windows / Linux，识别不到留空 | 端口类型不需要；OS 名称需要 |
| 自动发现 | 两端在局域网互报地址，Windows 自动连上 Mac，**无需配置 IP** | 依赖局域网广播 |
| 键鼠共享 | 独立模式 / 共享模式，共享模式下可分别开关键盘与鼠标 | 依赖局域网 |
| 本地优先 | 两端同时操作时，本地键鼠优先，避免互相抢输入 | — |
| 开机自启动 | 菜单中勾选控制，Mac 用系统登录项，Windows 用计划任务 + 看门狗 | — |
| 热键 | `Ctrl+Alt+1` 切到 Mac、`Ctrl+Alt+2` 切到 Windows（Mac 上是 `⌃⌥1` / `⌃⌥2`） | — |

明确不做：剪贴板同步、文件拖拽、光标无缝跨屏、音频跟随。

> 显示器完全不支持 DDC/CI 时，菜单只显示一行精简提示「该显示器不支持」，并禁用输入源项。支持时不会显示任何多余说明。

---

## 快速开始

在 [`dist/`](dist/) 下载对应安装包：

| 文件 | 平台 | 说明 |
|---|---|---|
| `KVMBridge-0.5.3-mac.dmg` | macOS（Apple Silicon） | 拖入「应用程序」 |
| `KVMBridge-0.5.3-mac.zip` | macOS（Apple Silicon） | 同上，zip 版 |
| `KVMBridge-0.5.3-win.zip` | Windows 10 / 11 | 解压后直接运行 `KVMBridge.exe` |

### macOS 端
1. 把 `KVMBridge.app` 拖进「应用程序」并运行，菜单栏出现图标。
2. 若提示「无法打开」，右键 App → 打开 → 打开。
3. 在「系统设置 → 隐私与安全性 → 辅助功能」中允许 KVM Bridge，否则无法收发键鼠事件。
4. Mac 是服务端，监听 **TCP 24801**，并在 **UDP 24802** 广播自己的地址；请在防火墙中放行这两个端口。不需要记 IP。

### Windows 端
1. 解压到**不含空格**的目录，双击 `KVMBridge.exe`，UAC 弹窗点「是」（低级钩子需要管理员权限）。
2. `app.ico` 必须与 exe 同目录。依赖 .NET Framework 4.x（Win10/11 自带）。
3. **无需配置**：两端启动后会自动发现并连上，发现到的地址写入同目录 `last-host.txt`，重启后秒连。
4. 只有在两端**不在同一网段**、收不到广播时，才在同目录 `host.txt` 写一行 Mac 的 IP，或用命令行 `KVMBridge.exe <MacIP> [端口]` / 环境变量 `KVM_MAC_HOST` 指定。`host.txt` 有值时以它为准。
5. 图标可能在托盘「^」溢出区，可拖到任务栏常驻。

### 两端连接后
菜单显示「已连接」，端口后会标出所连系统（如 `USB-C · macOS`、`DisplayPort · Windows`）。网络异常时会给出具体原因（连接被拒绝 / 网络不可达 / 超时 / 防火墙 24801 / 心跳超时等）。

---

## 自动发现怎么工作

```text
Mac   --UDP 24802 广播/单播-->  Windows    "KVMBRIDGE1 mac <session>"
Windows --UDP 24802 广播------>  Mac       "KVMBRIDGE1 win <session>"
Windows 从报文源地址得到 Mac IP ---> TCP 24801 建立键鼠链路
```

- Mac 按每个网卡的实际掩码计算**定向广播地址**发送（macOS 对 `255.255.255.255` 会返回 `No route to host`），并在收到 Windows 广播时**单播回复**一次，双保险。
- `session` 用于忽略本机自己发出的广播；地址变化时会自动切换连接目标并更新缓存。
- 覆盖不到的场景（跨网段、路由器隔离广播、防火墙拦截 UDP）由 `host.txt` / 命令行 / 环境变量兜底。
- 屏幕切换始终走本地 DDC/CI，即使完全没连上也能正常使用。

---

## 从源码构建

```bash
# macOS 端
cd mac/MonitorSwitcher && ./build.sh          # 产出 KVMBridge.app

# Windows 端：把 windows/package 复制到 Windows，双击 build.cmd
#   用系统自带 csc.exe 编译，无需 SDK

# 生成 dist/ 安装包（需先把 Windows 端 exe 放到 build/win/KVMBridge.exe）
./scripts/pack.sh
```

Mac 端把 `vendor/m1ddc/m1ddc`（arm64）打包进 App 的 `Resources`，运行时从 bundle 内查找；源码树调试时按相对目录或 `M1DDC_PATH` 环境变量查找，不含任何本机绝对路径。

若需要在 Mac 上保持「辅助功能」授权不因重编而失效，运行一次 `mac/signing/setup-signing.sh` 生成本机固定的代码签名身份。脚本会在缺少证书时自动创建自签名证书；**私钥不会被提交到仓库**（已由 `.gitignore` 排除）。没有该身份时 `build.sh` 会自动降级为 ad-hoc 签名。构建时可用 `KVM_SIGN_PASS` 覆盖本机钥匙串密码。

---

## 目录结构

```
mac/MonitorSwitcher/   macOS 端 Swift 源码
                       （菜单、DDC、状态机、转发、注入、Discovery、调试接口）
windows/package/       Windows 端 C# 源码
                       （托盘、DDC、协议、钩子、自动发现、计划任务自启）
vendor/m1ddc/          DDC/CI 命令行工具（源码 + 预编译 arm64 二进制）
scripts/pack.sh        双端安装包打包脚本
dist/                 0.5.3 可运行安装包
DESIGN.md             系统设计
UI-SPEC.md            界面规格
```

开发期用于远程部署/回归测试的脚本与凭据不在此仓库内。

---

## 已知边界

- **切屏不依赖网络**，两端不在同一网段也能切换；但「没画面的那台隔空切回」和键鼠共享需要可达的 TCP 链路。
- 自动发现依赖 UDP 广播，通常要求两端在同一网段；跨网段请手动指定 Mac 地址。
- 显示器只响应当前活动端口的 DDC 读写，因此归属以两端协议确认结果为准，不盲信本机读数。
- Windows 未检测到任何物理鼠标时不会绘制指针，插一个 USB 鼠标或接收器即可（不必真的使用）。
- 显示器待机后无信号，两端都提供「保持显示器唤醒」。
- 自研 TCP 协议**无鉴权、无加密**，任何能访问 Mac `24801` 端口的人都能注入输入，请只在可信局域网使用。
- 部分显示器不上报 MCCS capability string，此时使用内置端口表；本机型实测 `USB-C=15 / DP=16 / HDMI1=17 / HDMI2=18`。

---

## 校验和（SHA-256）

```
14804c1e2482c1e9ad35d24877013fed5d40d67f4f6b60360e4fc3028ee1566e  KVMBridge-0.5.3-mac.dmg
89b797f215c25cbe1d9666a62d0b5cdc69454e0422e79ed6021004f730aa0cb5  KVMBridge-0.5.3-mac.zip
c958aa55fbf244ae066191ab2b91d55d1ae967367dc0006fb6b6a736cb2a0246  KVMBridge-0.5.3-win.zip
```

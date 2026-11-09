# KVM Bridge

让一台显示器和一套键鼠在 **macOS** 与 **Windows** 两台主机之间共用。两端程序完全对等，任意一端都能切换屏幕、切换键鼠模式。

当前版本：**0.5.5**

0.5.5 修复：Windows 端 `RAWMOUSE` 结构体此前多出一个 `ulButtons`、又少了 2 字节对齐填充，导致 `lLastX` 实际读到的是真实的 `lLastY`、`lLastY` 恒为 0 —— 表现为共享鼠标「只能在一条线上移动」。现按 `winuser.h` 修正布局（`Pack=4`，`lLastX@12 / lLastY@16`），加入布局自检与逐帧位移诊断，实测真实硬件帧双轴均有值。共享模式下「键盘」「鼠标」后还会实时显示当前生效的是哪台设备的键鼠（macOS / Windows），由持有屏幕的一端裁决并同步到对端。0.5.4 起 Windows 使用 Raw Input 硬件相对位移、Mac 注入器连续注入期间不回读光标。

---

## 功能

| 功能 | 说明 | 是否依赖网络 |
|---|---|---|
| 屏幕切换 | 通过显示器 DDC/CI（VCP `0x60`）切换输入源 | **不依赖**，纯本地 |
| 端口识别 | 检测输入端口类型（USB-C / DP / HDMI / VGA…），能识别所连主机时显示 macOS / Windows / Linux，识别不到留空 | 端口类型不需要；OS 名称需要 |
| 自动发现 | 两端在局域网互报地址，Windows 自动连上 Mac，**无需配置 IP** | 依赖局域网广播 |
| 键鼠共享 | 独立模式 / 共享模式，共享模式下可分别开关键盘与鼠标 | 依赖局域网 |
| 当前设备显示 | 共享模式下「键盘」「鼠标」后实时标注当前生效的设备（macOS / Windows），两端同步 | 依赖局域网 |
| 本地优先 | 两端同时操作时，本地键鼠优先，避免互相抢输入 | — |
| 开机自启动 | 菜单中勾选控制，Mac 用系统登录项，Windows 用计划任务 + 看门狗 | — |
| 热键 | `Ctrl+Alt+1` 切到 Mac、`Ctrl+Alt+2` 切到 Windows（Mac 上是 `⌃⌥1` / `⌃⌥2`） | — |

明确不做：剪贴板同步、文件拖拽、光标无缝跨屏、音频跟随。

> 共享鼠标使用 Windows **Raw Input** 的硬件相对位移，并按两端屏幕比例换算（4K 物理像素 → macOS 逻辑点）；不经过指针加速，也不受 DPI 虚拟化与光标回中影响。结构体布局严格按 `winuser.h` 对齐并带运行时自检，避免只读到单轴位移。Raw Input 不可用时自动降级到低级钩子，并做同样的缩放与限幅。

> 显示器完全不支持 DDC/CI 时，菜单只显示一行精简提示「该显示器不支持」，并禁用输入源项。支持时不会显示任何多余说明。

---

## 快速开始

在 [`dist/`](dist/) 下载对应安装包：

| 文件 | 平台 | 说明 |
|---|---|---|
| `KVMBridge-0.5.5-mac.dmg` | macOS（Apple Silicon） | 拖入「应用程序」 |
| `KVMBridge-0.5.5-mac.zip` | macOS（Apple Silicon） | 同上，zip 版 |
| `KVMBridge-0.5.5-win.zip` | Windows 10 / 11 | 解压后直接运行 `KVMBridge.exe` |

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

共享模式下，「键盘」「鼠标」两行会实时显示当前生效的是哪台设备的键鼠，例如 `键盘 · macOS`、`鼠标 · Windows`；键盘与鼠标分别判定，谁在输入就显示谁，两端菜单始终一致。刚连上或切屏后默认显示持有屏幕那台设备的键鼠；切到独立模式或连接断开时标注自动清空。

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
dist/                 0.5.5 可运行安装包
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
- **切换时显示器偶发「无信号」提示**：软件侧已移除所有会短暂中断视频输出的操作（显示模式重配、后台 DDC 轮询），并用 DDC 写日志确认每次切换只写一次 `0x60`、两端不会互写。若提示仍在，通常是显示器 OSD 的「自动信号源检测 / Auto Source」在扫描没有信号的端口——请在显示器菜单中把信号源选择改为**手动 / 关闭自动检测**。用显示器物理按键直接切源也会出现同样提示，即可确认与软件无关。

---

## 校验和（SHA-256）

```
483a0bb8724c8070bc2f8a8c095bb45f69ebde21b2f51f245db12f4591f41d64  KVMBridge-0.5.5-mac.dmg
37d8d34ac229462bcf0eb74f8c63176c6a7b33ed67c4ce75b5fa7ac6e4c301b5  KVMBridge-0.5.5-mac.zip
51810af5bbeab40d12c93e83c52484e86084670857e878f4910a79c821b557db  KVMBridge-0.5.5-win.zip
```

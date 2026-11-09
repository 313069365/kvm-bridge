#!/bin/bash
# 打包两个端的可运行文件：
#   dist/KVMBridge-<ver>-mac.zip / .dmg   macOS 端（App 自带 arm64 m1ddc）
#   dist/KVMBridge-<ver>-win.zip         Windows 端（单文件 exe，直接运行）
# 前置：mac/MonitorSwitcher/build.sh 已编译；Windows exe 已取回到 build/win/
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="0.5.8"
DIST="$ROOT/dist"
WIN="$ROOT/build/win"
MACAPP="$ROOT/mac/MonitorSwitcher/KVMBridge.app"

mkdir -p "$DIST"
[ -d "$MACAPP" ] || { echo "缺少 Mac App: $MACAPP"; exit 1; }
[ -f "$WIN/KVMBridge.exe" ] || { echo "缺少 Windows exe: $WIN/KVMBridge.exe"; exit 1; }
[ -f "$ROOT/windows/package/app.ico" ] || { echo "缺少 app.ico"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mac" "$TMP/win"

cp -R "$MACAPP" "$TMP/mac/"
cp "$WIN/KVMBridge.exe" "$TMP/win/"
cp "$ROOT/windows/package/app.ico" "$TMP/win/"

cat > "$TMP/mac/README-macOS.txt" <<'EOF'
KVM Bridge 0.5.8 — macOS 端

【安装】
把 KVMBridge.app 拖进「应用程序」，双击运行，菜单栏会出现图标。
若提示「无法打开，因为来自身份不明的开发者」：右键 App → 打开 → 打开。
首次运行请在「系统设置 → 隐私与安全性 → 辅助功能」里允许 KVM Bridge，
否则无法接收和注入键鼠事件。
本包仅支持 Apple Silicon（arm64）Mac，因为内置了 arm64 版 m1ddc。

【开机自启动】
菜单栏 → 「开机自启动」，勾选即开、取消即关，默认开启。
由系统登录项（SMAppService）管理，也可在
「系统设置 → 通用 → 登录项与扩展」里查看。

【连接】
Mac 是服务端，监听 TCP 24801，并在 UDP 24802 广播自己的地址。
Windows 端会自动发现并连上，无需配置任何 IP；发现到的地址会缓存，重启后秒连。
仅当两端不在同一网段、收不到广播时，才在 Windows 端 exe 同目录的 host.txt
里写一行 Mac 的 IP（也可用环境变量 KVM_MAC_HOST）。
屏幕切换走显示器 DDC/CI，不依赖网络；键鼠共享需要两端网络可达。
显示器完全不支持 DDC/CI 时，菜单会显示「该显示器不支持」。

【使用】
Ctrl+Option+1 切到 Mac，Ctrl+Option+2 切到 Windows。
菜单「键鼠」可切换独立模式 / 共享模式；共享模式下可分别勾选键盘、鼠标。
共享时两行后面会实时显示当前生效的是哪台设备的键鼠（macOS / Windows），两端同步。
共享鼠标速度默认已调快一档（1.3 倍）；在 Windows 端 exe 同目录写 speed.txt
（一行数字，如 1.5 或 1.2），重启后即可调整，范围 0.25～4.0。
端口后面能识别到所连主机系统时会显示 Windows / macOS / Linux，识别不到留空。

【切换后显示器显示「无信号」】
本显示器写完 DDC 切源指令后，DDC 通道会短暂失效，属显示器固件行为。
菜单里有「复位显示器连接」，点一下会尝试重建通道（屏幕会短暂黑一下）。
若仍无信号：按显示器电源键关机 10 秒再开机，这是最可靠的复位方式。
然后用显示器按键手动切到 DisplayPort，确认 Windows 那路是否真有画面：
  有画面 → 只是切换瞬间的 OSD 提示，可忽略；
  无画面 → 检查 DP 线、OSD 里的 DisplayPort 版本、Windows 显示输出设置。
OSD 里请把「输入源选择」设为自动（不要固定某个口），DDC/CI 保持开启。
任何时刻按热键都能强制再切一次，不会因「状态未知」被拒绝。

【注意】
自研 TCP 协议无鉴权、无加密，请只在可信局域网使用。
EOF

cat > "$TMP/win/README-Windows.txt" <<'EOF'
KVM Bridge 0.5.8 — Windows 端

【运行】
解压到任意文件夹（建议路径不含空格），双击 KVMBridge.exe。
会弹出 UAC 提权，请点「是」——低级键盘鼠标钩子需要管理员权限。
app.ico 必须和 exe 放在同一目录（托盘图标）。
依赖 .NET Framework 4.x，Windows 10 / 11 自带，无需额外安装。

【连接 Mac】
默认自动发现：两端启动后在局域网互报地址，本程序会自动连上 Mac，
无需填写任何 IP。发现到的地址记入同目录 last-host.txt，重启后秒连。
只有两端不在同一网段（收不到广播）时，才需要在 host.txt 里写一行 Mac 的 IP，
或用命令行参数 KVMBridge.exe <MacIP> [端口]。host.txt 有值时以它为准。
屏幕切换不依赖网络，任何情况下都可用。
屏幕切换走显示器 DDC/CI，不依赖网络；键鼠共享需要两端在同一局域网。
显示器完全不支持 DDC/CI 时，菜单会显示「该显示器不支持」。

【开机自启动】
托盘图标右键 → 「开机自启动」，勾选即开、取消即关，默认开启。
开启时程序自动创建两个计划任务：
  KVMBridge  登录时启动
  KVMWatch   每 5 分钟检查一次，进程掉了就拉起
取消勾选会禁用这两个任务（不删除），下次启动不会自动运行。

【使用】
Ctrl+Alt+1 切到 Mac，Ctrl+Alt+2 切到 Windows。
菜单可切换独立模式 / 共享模式；共享模式下可分别勾选键盘、鼠标。
共享时两行后面会实时显示当前生效的是哪台设备的键鼠（macOS / Windows），两端同步。
共享鼠标速度默认已调快一档（1.3 倍）；在 Windows 端 exe 同目录写 speed.txt
（一行数字，如 1.5 或 1.2），重启后即可调整，范围 0.25～4.0。
端口后面能识别到所连主机系统时会显示 Windows / macOS / Linux，识别不到留空。

【切换后显示器显示「无信号」】
本显示器写完 DDC 切源指令后，DDC 通道会短暂失效，属显示器固件行为。
菜单里有「复位显示器连接」，点一下会尝试重建通道（屏幕会短暂黑一下）。
若仍无信号：按显示器电源键关机 10 秒再开机，这是最可靠的复位方式。
然后用显示器按键手动切到 DisplayPort，确认 Windows 那路是否真有画面：
  有画面 → 只是切换瞬间的 OSD 提示，可忽略；
  无画面 → 检查 DP 线、OSD 里的 DisplayPort 版本、Windows 显示输出设置。
OSD 里请把「输入源选择」设为自动（不要固定某个口），DDC/CI 保持开启。
任何时刻按热键都能强制再切一次，不会因「状态未知」被拒绝。

【注意】
Windows 未检测到任何物理鼠标时不会绘制鼠标指针，
请插一个 USB 鼠标或接收器（不需要真的用它）。
自研 TCP 协议无鉴权、无加密，请只在可信局域网使用。
EOF

# host.txt 用 CRLF，方便 Windows 记事本编辑。
# 只放注释说明，不写入任何示例/真实内网地址，由使用者自行填写。
printf '# 默认自动发现，无需填写。仅当两端不在同一网段、收不到广播时，\r\n# 才在下面写一行 Mac 的局域网 IP（例如 192.168.1.100），保存后重启本程序。\r\n# 屏幕切换不依赖网络；键鼠共享需要两端网络可达。\r\n' > "$TMP/win/host.txt"

(cd "$TMP/mac" && zip -q -r -y "$DIST/KVMBridge-$VER-mac.zip" "KVMBridge.app" "README-macOS.txt")

# dmg 里额外放一个 Applications 快捷方式，方便拖拽安装
ln -s /Applications "$TMP/mac/Applications"
hdiutil create -volname "KVM Bridge" -srcfolder "$TMP/mac" \
    -ov -format UDZO "$DIST/KVMBridge-$VER-mac.dmg" >/dev/null

(cd "$TMP/win" && zip -q -r "$DIST/KVMBridge-$VER-win.zip" .)

echo "== 产物 =="
ls -lh "$DIST"/KVMBridge-"$VER"-*
echo "== Windows 包内容 =="
(cd "$TMP/win" && ls -l)

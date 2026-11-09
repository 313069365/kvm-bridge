# kvm-tray.ps1 - Windows side tray switcher for the shared monitor.
# Switches monitor input source via DDC/CI (VCP 0x60) and keeps the display
# awake so that switching to this machine never lands on a blank screen.
#
# Run:  powershell -ExecutionPolicy Bypass -File .\kvm-tray.ps1
# Stop: right-click tray icon -> Quit

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ddcSource = @'
using System;using System.Collections.Generic;using System.Runtime.InteropServices;
public class D{
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct M{public IntPtr h;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)]public string n;}
 public delegate bool P(IntPtr a,IntPtr b,IntPtr c,IntPtr d);
 [DllImport("user32.dll")]static extern bool EnumDisplayMonitors(IntPtr a,IntPtr b,P p,IntPtr d);
 [DllImport("dxva2.dll")]static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h,ref uint n);
 [DllImport("dxva2.dll")]static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h,uint n,[Out]M[] p);
 [DllImport("dxva2.dll")]public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h,byte c,out uint t,out uint v,out uint m);
 [DllImport("dxva2.dll")]public static extern bool SetVCPFeature(IntPtr h,byte c,uint v);
 static List<M> L=new List<M>();static P k;
 public static List<M> G(){L.Clear();k=delegate(IntPtr a,IntPtr b,IntPtr c,IntPtr d){uint n=0;if(GetNumberOfPhysicalMonitorsFromHMONITOR(a,ref n)&&n>0){var x=new M[n];if(GetPhysicalMonitorsFromHMONITOR(a,n,x))L.AddRange(x);}return true;};EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,k,IntPtr.Zero);return L;}
}
'@

if (-not ('D' -as [type])) { Add-Type -TypeDefinition $ddcSource }

Add-Type -Namespace W -Name Exec -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
'@

$ES_CONTINUOUS       = 0x80000000
$ES_SYSTEM_REQUIRED  = 0x00000001
$ES_DISPLAY_REQUIRED = 0x00000002

$script:sources = @(
    @{ Value = 15; Name = 'USB-C  (Mac)' },
    @{ Value = 16; Name = 'DisplayPort  (Windows)' },
    @{ Value = 17; Name = 'HDMI 1' },
    @{ Value = 18; Name = 'HDMI 2' }
)

function Get-CurrentInput {
    $mons = [D]::G()
    if ($mons.Count -eq 0) { return -1 }
    $t = [uint32]0; $v = [uint32]0; $x = [uint32]0
    $ok = [D]::GetVCPFeatureAndVCPFeatureReply($mons[0].h, 0x60, [ref]$t, [ref]$v, [ref]$x)
    if ($ok -and $v -ge 1 -and $v -le 40) { return [int]$v }
    return -1
}

function Set-InputSource([int]$value) {
    $mons = [D]::G()
    if ($mons.Count -eq 0) { return }
    foreach ($m in $mons) { [void][D]::SetVCPFeature($m.h, 0x60, [uint32]$value) }
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Text = 'KVM Switch'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

foreach ($s in $script:sources) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($s.Name)
    $item.Tag = $s.Value
    $item.add_Click({
        Set-InputSource ([int]$this.Tag)
        Start-Sleep -Milliseconds 400
        Update-State
    })
    [void]$menu.Items.Add($item)
}

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem('当前：检测中')
$statusItem.Enabled = $false
[void]$menu.Items.Add($statusItem)

$keepAwake = New-Object System.Windows.Forms.ToolStripMenuItem('保持唤醒（防黑屏）')
$keepAwake.CheckOnClick = $true
$keepAwake.Checked = $true
$keepAwake.add_Click({
    if ($this.Checked) {
        [void][W.Exec]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
    } else {
        [void][W.Exec]::SetThreadExecutionState($ES_CONTINUOUS)
    }
})
[void]$menu.Items.Add($keepAwake)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
$exitItem.add_Click({
    [void][W.Exec]::SetThreadExecutionState($ES_CONTINUOUS)
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
[void]$menu.Items.Add($exitItem)

function Update-State {
    $cur = Get-CurrentInput
    $label = '未知（可能是非活动输入）'
    foreach ($s in $script:sources) { if ($s.Value -eq $cur) { $label = $s.Name } }
    $statusItem.Text = "当前：$label"
    $notify.Text = "KVM Switch - $label"
    foreach ($it in $menu.Items) {
        if ($null -ne $it.Tag) { $it.Checked = ([int]$it.Tag -eq $cur) }
    }
}

$notify.ContextMenuStrip = $menu

[void][W.Exec]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)

Update-State
$next = (Get-Date).AddSeconds(3)

while ($true) {
    [System.Windows.Forms.Application]::DoEvents()
    if ((Get-Date) -gt $next) {
        Update-State
        $next = (Get-Date).AddSeconds(3)
    }
    Start-Sleep -Milliseconds 150
}

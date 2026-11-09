# ddc-input.ps1
# Read or set a monitor input source over DDC/CI (VCP code 0x60).
# No installation required - calls dxva2.dll directly.
#
#   List monitors and current input:
#     powershell -ExecutionPolicy Bypass -File .\ddc-input.ps1
#
#   Switch every detected monitor to input 15 (DisplayPort 1):
#     powershell -ExecutionPolicy Bypass -File .\ddc-input.ps1 -Input 15
#
#   Switch only the first monitor:
#     powershell -ExecutionPolicy Bypass -File .\ddc-input.ps1 -Input 17 -Index 0
#
# Common VCP 0x60 values: DP1=15  DP2=16  HDMI1=17  HDMI2=18  USB-C=27

param(
    [int]$Input = -1,
    [int]$Index = -1
)

Add-Type -Namespace WbDdc -Name Api -MemberDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct PHYSICAL_MONITOR {
    public IntPtr hPhysicalMonitor;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string szPhysicalMonitorDescription;
}

public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr data);

[DllImport("user32.dll")]
public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);

[DllImport("dxva2.dll", SetLastError = true)]
public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint n);

[DllImport("dxva2.dll", SetLastError = true)]
public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] p);

[DllImport("dxva2.dll", SetLastError = true)]
public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint vcpType, out uint cur, out uint max);

[DllImport("dxva2.dll", SetLastError = true)]
public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

[DllImport("dxva2.dll", SetLastError = true)]
public static extern bool DestroyPhysicalMonitor(IntPtr h);

static MonitorEnumProc _keepAlive;

public static List<PHYSICAL_MONITOR> Collect() {
    var list = new List<PHYSICAL_MONITOR>();
    _keepAlive = delegate(IntPtr hMon, IntPtr hdc, IntPtr lprc, IntPtr data) {
        uint count = 0;
        if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref count) && count > 0) {
            var arr = new PHYSICAL_MONITOR[count];
            if (GetPhysicalMonitorsFromHMONITOR(hMon, count, arr)) {
                list.AddRange(arr);
            }
        }
        return true;
    };
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, _keepAlive, IntPtr.Zero);
    _keepAlive = null;
    return list;
}
'@

$monitors = [WbDdc.Api]::Collect()

if ($monitors.Count -eq 0) {
    Write-Host "No DDC-capable physical monitor found." -ForegroundColor Red
    exit 1
}

Write-Host "Detected $($monitors.Count) physical monitor(s):" -ForegroundColor Cyan

$i = 0
foreach ($m in $monitors) {
    $name = $m.szPhysicalMonitorDescription
    $vcpType = [uint32]0
    $cur = [uint32]0
    $max = [uint32]0
    $ok = [WbDdc.Api]::GetVCPFeatureAndVCPFeatureReply($m.hPhysicalMonitor, 0x60, [ref]$vcpType, [ref]$cur, [ref]$max)

    if ($ok) {
        Write-Host ("  [{0}] {1}  ->  input = {2}" -f $i, $name, $cur)
    } else {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host ("  [{0}] {1}  ->  VCP 0x60 not readable (error {2})" -f $i, $name, $err) -ForegroundColor Yellow
    }
    $i++
}

if ($Input -lt 0) {
    foreach ($m in $monitors) { [void][WbDdc.Api]::DestroyPhysicalMonitor($m.hPhysicalMonitor) }
    Write-Host ""
    Write-Host "Read-only mode. Use -Input <value> to switch." -ForegroundColor DarkGray
    exit 0
}

Write-Host ""
Write-Host "Switching to input $Input ..." -ForegroundColor Cyan

$i = 0
$failed = 0
foreach ($m in $monitors) {
    if ($Index -ge 0 -and $i -ne $Index) { $i++; continue }

    $ok = [WbDdc.Api]::SetVCPFeature($m.hPhysicalMonitor, 0x60, [uint32]$Input)
    if ($ok) {
        Write-Host ("  [{0}] {1}  ->  write accepted" -f $i, $m.szPhysicalMonitorDescription)
    } else {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host ("  [{0}] {1}  ->  write FAILED (error {2})" -f $i, $m.szPhysicalMonitorDescription, $err) -ForegroundColor Red
        $failed++
    }
    $i++
}

Start-Sleep -Seconds 2

$i = 0
foreach ($m in $monitors) {
    if ($Index -ge 0 -and $i -ne $Index) { $i++; continue }
    $vcpType = [uint32]0
    $cur = [uint32]0
    $max = [uint32]0
    if ([WbDdc.Api]::GetVCPFeatureAndVCPFeatureReply($m.hPhysicalMonitor, 0x60, [ref]$vcpType, [ref]$cur, [ref]$max)) {
        Write-Host ("  [{0}] read back = {1}" -f $i, $cur)
    } else {
        Write-Host ("  [{0}] read back unavailable (expected if this display just left the active input)" -f $i) -ForegroundColor Yellow
    }
    $i++
}

foreach ($m in $monitors) { [void][WbDdc.Api]::DestroyPhysicalMonitor($m.hPhysicalMonitor) }

if ($failed -gt 0) { exit 2 }
exit 0

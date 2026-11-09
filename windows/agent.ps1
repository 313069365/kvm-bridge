# agent.ps1 - Windows side DDC agent (listener mode).
# Listens on TCP 8765 and waits for the Mac controller to connect.
#
# Prerequisite (admin PowerShell, once):
#   New-NetFirewallRule -DisplayName "KVM-Agent" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow -Profile Any
#
# Run:  powershell -ExecutionPolicy Bypass -File .\agent.ps1
# Stop: Ctrl+C

param(
    [int]$Port = 8765
)

$c = @'
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

Add-Type -TypeDefinition $c

function Switch-Input([int]$value) {
    $monitors = [D]::G()
    if ($monitors.Count -eq 0) { return "ERR no-monitor" }
    foreach ($m in $monitors) {
        [void][D]::SetVCPFeature($m.h, 0x60, [uint32]$value)
    }
    return "OK $value"
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "listening on 0.0.0.0:$Port - waiting for mac controller" -ForegroundColor Green

while ($true) {
    $client = $listener.AcceptTcpClient()
    Write-Host "client connected: $($client.Client.RemoteEndPoint)" -ForegroundColor Cyan

    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $line = $line.Trim()

            if ($line -match '^SWITCH\s+(\d+)$') {
                $v = [int]$matches[1]
                $reply = Switch-Input $v
                Write-Host "  SWITCH $v -> $reply"
                $writer.WriteLine($reply)
            }
            elseif ($line -eq 'PING') {
                $writer.WriteLine('PONG')
            }
            elseif ($line -eq 'QUIT') {
                $writer.WriteLine('BYE')
                break
            }
            else {
                $writer.WriteLine("ERR unknown:$line")
            }
        }
    }
    catch {
        Write-Host "session error: $_" -ForegroundColor Yellow
    }

    $client.Close()
    Write-Host "client disconnected, still listening" -ForegroundColor DarkGray
}

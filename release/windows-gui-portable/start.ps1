$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = $PSScriptRoot
$application = Join-Path $root 'sing-box.exe'
$daemon = Join-Path $root 'resources\daemon\sing-box-daemon.exe'
$dataRoot = Join-Path $root 'data'
$userData = Join-Path $dataRoot 'SFW'
$daemonData = Join-Path $dataRoot 'daemon'
$logDirectory = Join-Path $dataRoot 'logs'

foreach ($directory in @($userData, $daemonData, $logDirectory)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

function Read-RegistryValueState {
    param([string] $Name)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
    try {
        $names = @($key.GetValueNames())
        if ($names -contains $Name) {
            return [pscustomobject]@{
                Exists = $true
                Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                Kind = $key.GetValueKind($Name)
            }
        }
        return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Restore-RegistryValueState {
    param([string] $Name, $State)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
    try {
        if ($State.Exists) {
            $key.SetValue($Name, $State.Value, $State.Kind)
        } else {
            $key.DeleteValue($Name, $false)
        }
    } finally {
        $key.Dispose()
    }
}

function Notify-ProxySettingsChanged {
    if (-not ('PortableSfw.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
namespace PortableSfw {
    using System;
    using System.Runtime.InteropServices;
    public static class NativeMethods {
        [DllImport("wininet.dll", SetLastError = true)]
        public static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int length);
    }
}
'@
    }
    [PortableSfw.NativeMethods]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [PortableSfw.NativeMethods]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

$proxyNames = @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')
$proxySnapshot = @{}
foreach ($name in $proxyNames) {
    $proxySnapshot[$name] = Read-RegistryValueState $name
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
$listener.Stop()

$env:SING_BOX_PORTABLE_USER_DATA = $userData
$env:SING_BOX_PORTABLE_DAEMON_DATA = $daemonData
$env:SING_BOX_PORTABLE_DAEMON_URL = "http://127.0.0.1:$port"
$daemonOut = Join-Path $logDirectory 'daemon.stdout.log'
$daemonError = Join-Path $logDirectory 'daemon.stderr.log'
$daemonProcess = $null
$applicationProcess = $null

try {
    $daemonProcess = Start-Process -FilePath $daemon -ArgumentList @(
        'run', '--working-directory', $daemonData, '--listen', "127.0.0.1:$port"
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $daemonOut -RedirectStandardError $daemonError

    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($daemonProcess.HasExited) {
            throw "The portable daemon exited early. See $daemonError"
        }
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connect = $client.BeginConnect('127.0.0.1', $port, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne(250) -and $client.Connected) {
                $client.EndConnect($connect)
                $ready = $true
                break
            }
        } catch {
        } finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        throw "The portable daemon did not become ready. See $daemonError"
    }

    $applicationProcess = Start-Process -FilePath $application -WorkingDirectory $root -PassThru
    $applicationProcess.WaitForExit()
} finally {
    if ($null -ne $applicationProcess -and -not $applicationProcess.HasExited) {
        Stop-Process -Id $applicationProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $daemonProcess -and -not $daemonProcess.HasExited) {
        Stop-Process -Id $daemonProcess.Id -Force -ErrorAction SilentlyContinue
        $daemonProcess.WaitForExit(5000) | Out-Null
    }
    foreach ($name in $proxyNames) {
        Restore-RegistryValueState $name $proxySnapshot[$name]
    }
    Notify-ProxySettingsChanged
}

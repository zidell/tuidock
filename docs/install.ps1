# TUIDock 설치·업데이트 (Windows PowerShell 5.1 / PowerShell 7)
#   irm https://zidell.github.io/tuidock/install.ps1 | iex
# 로컬 ZIP으로 시험/오프라인 설치: ./install.ps1 -ZipUrl <ZIP 경로>
param(
    [string]$ZipUrl = 'https://github.com/zidell/tuidock/releases/latest/download/TUIDock-windows-x64.zip',
    [switch]$NoPath
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    -not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Build -lt 17763) {
    throw 'Requires Windows 10 1809 or newer, 64-bit.'
}
if (-not $env:LOCALAPPDATA -or -not $env:APPDATA) { throw 'User application directories are unavailable.' }
$installDir = Join-Path $env:LOCALAPPDATA 'Programs/TUIDock'
$installedExe = [IO.Path]::GetFullPath((Join-Path $installDir 'tuidock.exe'))
foreach ($process in Get-Process tuidock -ErrorAction SilentlyContinue) {
    if ($process.Path -and [string]::Equals($process.Path, $installedExe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Close running TUIDock app windows before updating.'
    }
}
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$staging = Join-Path $tempRoot ('tuidock-install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    $archive = Join-Path $staging 'TUIDock.zip'
    Write-Host 'Downloading...'
    if (Test-Path -LiteralPath $ZipUrl -PathType Leaf) {
        Copy-Item -LiteralPath $ZipUrl -Destination $archive
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $ZipUrl -OutFile $archive -UseBasicParsing
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    $package = Join-Path $staging 'TUIDock-windows-x64'
    foreach ($file in 'tuidock.exe', 'Qt6Core.dll', 'Qt6Gui.dll', 'Qt6Widgets.dll', 'platforms/qwindows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'fonts/OFL.txt', 'LICENSE') {
        if (-not (Test-Path -LiteralPath (Join-Path $package $file) -PathType Leaf)) { throw "Invalid Windows package: missing $file" }
    }
    Get-ChildItem -LiteralPath $package -File -Recurse | Unblock-File
    $installer = Start-Process -FilePath (Join-Path $package 'tuidock.exe') -ArgumentList 'install' -Wait -PassThru -NoNewWindow
    if ($installer.ExitCode -ne 0) { throw "TUIDock installation failed (exit $($installer.ExitCode))." }
    if (-not (Test-Path -LiteralPath $installedExe)) { throw 'Installed executable not found.' }
    if (-not $NoPath) {
        $userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
        $present = @($userPath -split ';' | Where-Object { $_.TrimEnd('\', '/') -ieq $installDir.TrimEnd('\', '/') }).Count -gt 0
        if (-not $present) {
            [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $installDir).TrimStart(';'), 'User')
            # Explorer가 새 터미널에 최신 사용자 PATH를 넘기도록 변경을 알린다.
            if (-not ('TUIDockInstall.Environment' -as [type])) {
                Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace TUIDockInstall {
    public static class Environment {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
        public static void Refresh() {
            UIntPtr result;
            SendMessageTimeout(new IntPtr(0xffff), 0x001a, UIntPtr.Zero, "Environment", 2, 1000, out result);
        }
    }
}
'@
            }
            [TUIDockInstall.Environment]::Refresh()
        }
        if (-not (@($env:PATH -split ';' | Where-Object { $_.TrimEnd('\', '/') -ieq $installDir.TrimEnd('\', '/') }).Count -gt 0)) {
            $env:PATH = $env:PATH.TrimEnd(';') + ';' + $installDir
        }
    }
    Write-Host "Installed: $installedExe"
    Write-Host 'Start > TUIDock'
    if (-not $NoPath) { Write-Host 'CLI: tuidock --help (new terminals also use the updated user PATH).' }
} finally {
    # 이 실행에서 만든 임시 폴더 하나만 지운다.
    $resolved = (Resolve-Path -LiteralPath $staging).Path
    if (-not $resolved.StartsWith($tempRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^tuidock-install-[0-9a-f]{32}$') { throw 'Refusing to clean an unexpected path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

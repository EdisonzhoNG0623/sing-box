param(
    [string] $Installer = '',
    [string] $GoArchive = '',
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'dist')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$version = '1.14.0'
$installerName = "SFW-$version-x64.exe"
$installerUrl = "https://github.com/SagerNet/sing-box/releases/download/v$version/$installerName"
$installerSha256 = '633D67C5D0009BB8A256C1C84FA7A9B3F5ADAA1A2CC982842EE9CA905ACC126E'
$desktopSourceRevision = '92b69e160d30249e8fc21a1106df6af538f0fb92'
$coreSourceRevision = '0b8995879f29a9b98ee027bc17b75e101445b238'
$goVersion = '1.26.7'
$goArchiveName = "go$goVersion.windows-amd64.zip"
$goArchiveUrl = "https://go.dev/dl/$goArchiveName"
$goArchiveSha256 = 'F4F534A486E4BC3387FA18F08208F2F854B7AAEA8A08F2A2D829A914A05ABB11'
$portableName = "SFW-$version-windows-x64-portable-noadmin"
$outputParent = [IO.Path]::GetFullPath($OutputDirectory)
$destination = Join-Path $outputParent $portableName
$outputZip = Join-Path $outputParent "$portableName.zip"
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("sfw-portable-build-" + [Guid]::NewGuid().ToString('N'))
$certificate = $null
$sourceWorktree = $null
$sourceWorktreeCreated = $false

[IO.Directory]::CreateDirectory($outputParent) | Out-Null
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $outputZip)) {
    throw "Output already exists: $destination"
}
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

try {
    if ([string]::IsNullOrWhiteSpace($Installer)) {
        $installerPath = Join-Path $temporaryRoot $installerName
        Write-Host "Downloading official SFW asset: $installerUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $installerUrl -OutFile $installerPath
    } else {
        $installerPath = (Resolve-Path -LiteralPath $Installer).Path
    }
    $actualInstallerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    if ($actualInstallerHash -ne $installerSha256) {
        throw "Official installer SHA-256 mismatch. Expected $installerSha256, got $actualInstallerHash."
    }

    $installerExtracted = Join-Path $temporaryRoot 'installer-extracted'
    [IO.Directory]::CreateDirectory($installerExtracted) | Out-Null
    & tar.exe -xf $installerPath -C $installerExtracted
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract the official NSIS/7z SFX (exit $LASTEXITCODE)." }

    $nestedApplication = Join-Path $installerExtracted '$PLUGINSDIR\app-64.7z'
    if (Test-Path -LiteralPath $nestedApplication) {
        $extracted = Join-Path $temporaryRoot 'extracted'
        [IO.Directory]::CreateDirectory($extracted) | Out-Null
        & tar.exe -xf $nestedApplication -C $extracted
        if ($LASTEXITCODE -ne 0) { throw "Failed to extract the official application payload (exit $LASTEXITCODE)." }
    } else {
        $extracted = $installerExtracted
    }

    $application = Join-Path $extracted 'sing-box.exe'
    $daemon = Join-Path $extracted 'resources\daemon\sing-box-daemon.exe'
    $asar = Join-Path $extracted 'resources\app.asar'
    foreach ($required in @($application, $daemon, $asar)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Official SFW layout is missing $required" }
    }

    if ([string]::IsNullOrWhiteSpace($GoArchive)) {
        $goArchivePath = Join-Path $temporaryRoot $goArchiveName
        Write-Host "Downloading official Go toolchain: $goArchiveUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $goArchiveUrl -OutFile $goArchivePath
    } else {
        $goArchivePath = (Resolve-Path -LiteralPath $GoArchive).Path
    }
    $actualGoHash = (Get-FileHash -LiteralPath $goArchivePath -Algorithm SHA256).Hash
    if ($actualGoHash -ne $goArchiveSha256) {
        throw "Go archive SHA-256 mismatch. Expected $goArchiveSha256, got $actualGoHash."
    }
    $goRoot = Join-Path $temporaryRoot 'go-toolchain'
    Expand-Archive -LiteralPath $goArchivePath -DestinationPath $goRoot
    $goExecutable = Join-Path $goRoot 'go\bin\go.exe'

    $sourceWorktree = Join-Path $temporaryRoot 'sing-box-source'
    & git.exe worktree add --detach $sourceWorktree $coreSourceRevision
    if ($LASTEXITCODE -ne 0) { throw "Failed to create the 1.14.0 source worktree (exit $LASTEXITCODE)." }
    $sourceWorktreeCreated = $true
    & git.exe -C $sourceWorktree apply (Join-Path $PSScriptRoot 'daemon-tcp-identity.patch')
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply the Windows TCP identity patch (exit $LASTEXITCODE)." }
    $previousPath = $env:PATH
    $previousToolchain = $env:GOTOOLCHAIN
    Push-Location $sourceWorktree
    try {
        $env:PATH = (Join-Path $goRoot 'go\bin') + ';' + $previousPath
        $env:GOTOOLCHAIN = 'local'
        & $goExecutable run ./cmd/internal/build_boxdd '-target=windows/amd64' ("-output=" + $daemon)
        if ($LASTEXITCODE -ne 0) { throw "Failed to build the patched 1.14.0 daemon (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
        $env:PATH = $previousPath
        if ($null -eq $previousToolchain) { Remove-Item Env:GOTOOLCHAIN -ErrorAction SilentlyContinue } else { $env:GOTOOLCHAIN = $previousToolchain }
    }

    $originalAsar = Join-Path $temporaryRoot 'app.original.asar'
    Copy-Item -LiteralPath $asar -Destination $originalAsar
    $asarSource = Join-Path $temporaryRoot 'app-source'
    & npx.cmd --yes '@electron/asar@4.2.0' extract $asar $asarSource
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract app.asar (exit $LASTEXITCODE)." }
    & node.exe (Join-Path $PSScriptRoot 'patch-app.cjs') patch-source $asarSource
    if ($LASTEXITCODE -ne 0) { throw "Failed to patch app source (exit $LASTEXITCODE)." }
    Remove-Item -LiteralPath $asar -Force
    & npx.cmd --yes '@electron/asar@4.2.0' pack $asarSource $asar
    if ($LASTEXITCODE -ne 0) { throw "Failed to repack app.asar (exit $LASTEXITCODE)." }
    & node.exe (Join-Path $PSScriptRoot 'patch-app.cjs') patch-integrity $application $originalAsar $asar
    if ($LASTEXITCODE -ne 0) { throw "Failed to patch the embedded ASAR integrity hash (exit $LASTEXITCODE)." }

    $launcher = Join-Path $temporaryRoot 'sing-box-portable.exe'
    $csharpCompiler = Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET\Framework64') -Recurse -Filter csc.exe -ErrorAction Stop |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $csharpCompiler) { throw 'The .NET Framework x64 C# compiler was not found.' }
    & $csharpCompiler /nologo /target:winexe ("/out:" + $launcher) (Join-Path $PSScriptRoot 'launcher.cs')
    if ($LASTEXITCODE -ne 0) { throw "Failed to compile the portable launcher (exit $LASTEXITCODE)." }

    $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=SFW Portable No-Admin Build' -CertStoreLocation 'Cert:\CurrentUser\My' -HashAlgorithm SHA256 -KeyAlgorithm RSA -KeyLength 3072 -NotAfter (Get-Date).AddYears(20)
    $pfxPath = Join-Path $temporaryRoot 'signing.pfx'
    $pfxPasswordText = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    $pfxPassword = ConvertTo-SecureString -String $pfxPasswordText -AsPlainText -Force
    Export-PfxCertificate -Cert $certificate -FilePath $pfxPath -Password $pfxPassword | Out-Null
    $signTool = Get-ChildItem -LiteralPath 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction Stop |
        Where-Object { $_.DirectoryName -match '\\x64$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $signTool) { throw 'Windows SDK x64 signtool.exe was not found.' }
    & $signTool sign /fd SHA256 /f $pfxPath /p $pfxPasswordText $application $daemon $launcher
    if ($LASTEXITCODE -ne 0) { throw "Authenticode signing failed (exit $LASTEXITCODE)." }

    $appSignature = Get-AuthenticodeSignature -FilePath $application
    $daemonSignature = Get-AuthenticodeSignature -FilePath $daemon
    if ($null -eq $appSignature.SignerCertificate -or $null -eq $daemonSignature.SignerCertificate -or
        $appSignature.SignerCertificate.Thumbprint -ne $daemonSignature.SignerCertificate.Thumbprint) {
        throw 'The application and daemon do not have matching signing certificates.'
    }

    Remove-Item -LiteralPath (Join-Path $extracted 'resources\elevate.exe') -Force -ErrorAction SilentlyContinue
    $portableRoot = Join-Path $temporaryRoot 'portable-root'
    $portableApplication = Join-Path $portableRoot 'app'
    [IO.Directory]::CreateDirectory($portableRoot) | Out-Null
    [IO.Directory]::Move($extracted, $portableApplication)
    Copy-Item -LiteralPath $launcher -Destination $portableRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start.ps1') -Destination $portableRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start.cmd') -Destination $portableRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.txt') -Destination $portableRoot
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'LICENSE') -Destination (Join-Path $portableRoot 'LICENSE-sing-box.txt')

    $sourceText = @"
UNOFFICIAL DERIVATIVE PORTABLE BUILD
====================================

Official release asset
----------------------
Project:          SagerNet/sing-box (official SFW graphical client)
Version:          v$version
Asset:            $installerUrl
Original SHA-256: $installerSha256
Core revision:    $coreSourceRevision
Desktop source:   https://github.com/SagerNet/sing-box-for-desktop/tree/$desktopSourceRevision
Core source:      https://github.com/SagerNet/sing-box/tree/$coreSourceRevision

Portable patch
--------------
- Extracted the official SFW Electron application from its installer.
- Moved the original Electron runtime under app and added one obvious root-level
  sing-box-portable.exe launcher, so the service-install UI is not an entry point.
- Redirected the packaged Windows desktop gRPC transport to an official
  sing-box-daemon.exe TCP loopback endpoint selected by start.ps1.
- Rebuilt sing-box-daemon.exe from the exact 1.14.0 source revision with one
  Windows-only patch: TCP development mode inherits the current user only when
  its configured listen IP is loopback. The launcher binds to 127.0.0.1 and the
  fallback remains disabled for every non-loopback listen address.
- Redirected Electron userData to data\SFW inside the portable folder.
- Rejected configurations containing a TUN inbound so the package cannot
  silently fall back to an administrator-only driver path.
- Removed resources\elevate.exe because this package never installs or repairs
  a Windows service.
- Updated Electron's embedded app.asar integrity hash after the patch.
- Re-signed app\sing-box.exe, sing-box-daemon.exe, and the portable launcher with
  one build-local self-signed code-signing certificate to satisfy worker authentication.
- Added start scripts, documentation, source attribution, and licenses.
- Added no configuration, subscription, node, key, credential, or settings database.

Derived signer
--------------
Subject:         $($appSignature.SignerCertificate.Subject)
Thumbprint:      $($appSignature.SignerCertificate.Thumbprint)
Valid until:     $($appSignature.SignerCertificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
This is NOT the official Project S signing certificate.
"@
    [IO.File]::WriteAllText((Join-Path $portableRoot 'SOURCE.txt'), $sourceText, [Text.UTF8Encoding]::new($false))

    [IO.Directory]::Move($portableRoot, $destination)
    Compress-Archive -LiteralPath $destination -DestinationPath $outputZip -CompressionLevel Optimal
    $zipHash = (Get-FileHash -LiteralPath $outputZip -Algorithm SHA256).Hash
    Write-Host "Created: $outputZip"
    Write-Host "SHA-256: $zipHash"
    Write-Host "Signer: $($appSignature.SignerCertificate.Thumbprint)"
} catch {
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    if (Test-Path -LiteralPath $outputZip) { Remove-Item -LiteralPath $outputZip -Force }
    throw
} finally {
    if ($null -ne $certificate) {
        Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $certificate.Thumbprint) -Force -ErrorAction SilentlyContinue
    }
    if ($sourceWorktreeCreated -and $null -ne $sourceWorktree) {
        & git.exe worktree remove --force $sourceWorktree 2>$null
    }
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

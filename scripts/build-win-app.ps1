[CmdletBinding()]
param(
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $RepoRoot

try {
    . (Join-Path $PSScriptRoot 'win-env.ps1')

    Write-Host '==> Verifying pinned ICC and LUT SHA-256 checksums...'
    $expected = @{
        'ICC\DCIP3_D65.icc' = 'eafc15fd36e56bc496b084d3aaacbdca419e65e03fac9a1930d024b1e8d9b32b'
        'assets\DerivedLUTs\diffuse-white-v1\Kodak 2383.cube' = '652199a63b1d38998dbd70247d6ea13c8c17963cfcdc0fc0508a42056739a207'
        'assets\DerivedLUTs\diffuse-white-v1\Fujifilm 3513DI.cube' = '03839ed74c1d52766d3b1ae200460260cb0a0078e8f666b00c483fc695ee0757'
    }
    foreach ($rel in $expected.Keys) {
        $full = Join-Path $RepoRoot $rel
        if (-not (Test-Path $full)) {
            throw "Missing required asset: $full"
        }
        $actual = (Get-FileHash -Path $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected[$rel]) {
            throw "Asset checksum mismatch for $rel : expected $($expected[$rel]), got $actual"
        }
    }

    Write-Host '==> Building PrintroomWinBridge (Release, native)...'
    & swift build -c release -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=simplify-cfg --build-system native --product PrintroomWinBridge
    if ($LASTEXITCODE -ne 0) {
        throw "swift build failed with exit code $LASTEXITCODE"
    }

    $SwiftReleaseDir = Join-Path $RepoRoot '.build\x86_64-unknown-windows-msvc\release'
    $BridgeDll = Join-Path $SwiftReleaseDir 'PrintroomWinBridge.dll'
    $CoreResources = Join-Path $SwiftReleaseDir 'Printroom_PrintroomCore.resources'
    if (-not (Test-Path $BridgeDll)) {
        throw "Missing built PrintroomWinBridge.dll at $BridgeDll"
    }
    if (-not (Test-Path $CoreResources)) {
        throw "Missing built Printroom_PrintroomCore.resources at $CoreResources"
    }

    Write-Host '==> Publishing WPF PrintroomApp (Release, self-contained win-x64)...'
    $Csproj = Join-Path $RepoRoot 'Windows\PrintroomApp\PrintroomApp.csproj'
    & dotnet publish $Csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE"
    }

    $PublishDir = Join-Path $RepoRoot 'Windows\PrintroomApp\bin\Release\net8.0-windows\win-x64\publish'
    if (-not (Test-Path (Join-Path $PublishDir 'Printroom.exe'))) {
        throw "Missing published Printroom.exe at $PublishDir"
    }

    $OutputRoot = Join-Path $RepoRoot 'output'
    $StageDir = Join-Path $OutputRoot 'Printroom-Windows-x64'
    $ZipPath = Join-Path $OutputRoot 'Printroom-v1.0.4-Windows-x64.zip'

    if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

    Write-Host "==> Assembling portable bundle at $StageDir..."
    Copy-Item -Path (Join-Path $PublishDir '*') -Destination $StageDir -Recurse -Force
    Copy-Item -Path $BridgeDll -Destination $StageDir -Force
    Copy-Item -Path $CoreResources -Destination (Join-Path $StageDir 'Printroom_PrintroomCore.resources') -Recurse -Force

    # Bundle Swift 6.4.3 runtime + MSVC CRT DLLs
    $SwiftRuntimeBin = 'D:\DevTools\Swift\Runtimes\6.4.3\usr\bin'
    if (-not (Test-Path $SwiftRuntimeBin)) {
        throw "Missing Swift runtime bin directory: $SwiftRuntimeBin"
    }
    Get-ChildItem -Path $SwiftRuntimeBin -Filter '*.dll' | Copy-Item -Destination $StageDir -Force

    $MsvcRedistCrt = Get-ChildItem -Path 'D:\DevTools\MSVC\VC\Redist\MSVC' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC145.CRT' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if ($MsvcRedistCrt) {
        Get-ChildItem -Path $MsvcRedistCrt -Filter '*.dll' | Copy-Item -Destination $StageDir -Force
    }

    # Bundle ICC and LUT assets
    $AssetsDest = Join-Path $StageDir 'Assets'
    New-Item -ItemType Directory -Force -Path (Join-Path $AssetsDest 'ICC') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $AssetsDest 'assets\DerivedLUTs\diffuse-white-v1') | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'ICC\DCIP3_D65.icc') -Destination (Join-Path $AssetsDest 'ICC') -Force
    Copy-Item -Path (Join-Path $RepoRoot 'assets\DerivedLUTs\diffuse-white-v1\*.cube') -Destination (Join-Path $AssetsDest 'assets\DerivedLUTs\diffuse-white-v1') -Force

    # Bundle GPL-3.0 notices and third-party source archives matching build-app.sh
    Copy-Item -Path (Join-Path $RepoRoot 'LICENSE') -Destination $StageDir -Force
    Copy-Item -Path (Join-Path $RepoRoot 'THIRD_PARTY_NOTICES.md') -Destination $StageDir -Force
    $ThirdPartyDest = Join-Path $StageDir 'ThirdParty'
    New-Item -ItemType Directory -Force -Path $ThirdPartyDest | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'ThirdParty\LibRaw') -Destination (Join-Path $ThirdPartyDest 'LibRaw') -Recurse -Force
    Copy-Item -Path (Join-Path $RepoRoot 'ThirdParty\libdeflate') -Destination (Join-Path $ThirdPartyDest 'libdeflate') -Recurse -Force
    $FontsThirdPartyDest = Join-Path $ThirdPartyDest 'Fonts'
    New-Item -ItemType Directory -Force -Path $FontsThirdPartyDest | Out-Null
    Get-ChildItem -Path (Join-Path $RepoRoot 'Windows\PrintroomApp\Assets\Fonts') -Filter '*.txt' -ErrorAction SilentlyContinue | Copy-Item -Destination $FontsThirdPartyDest -Force

    if (-not $SkipSmokeTest) {
        $ExePath = Join-Path $StageDir 'Printroom.exe'
        $origPath = $env:PATH
        $env:PATH = 'C:\Windows\System32;C:\Windows'
        try {
            Write-Host '==> Clean-PATH smoke test: Printroom.exe --verify-resources'
            $verifyOutFile = Join-Path $StageDir '.verify-stdout.tmp'
            $verifyErrFile = Join-Path $StageDir '.verify-stderr.tmp'
            $verifyProc = Start-Process -FilePath $ExePath -WorkingDirectory $StageDir -ArgumentList '--verify-resources' -Wait -PassThru -RedirectStandardOutput $verifyOutFile -RedirectStandardError $verifyErrFile
            $verifyOut = ((Get-Content $verifyOutFile -Raw -ErrorAction SilentlyContinue) + (Get-Content $verifyErrFile -Raw -ErrorAction SilentlyContinue)).Trim()
            Remove-Item $verifyOutFile, $verifyErrFile -Force -ErrorAction SilentlyContinue
            Write-Host $verifyOut
            if ($verifyProc.ExitCode -ne 0 -or ($verifyOut -notmatch 'GPU=')) {
                throw "Clean-PATH --verify-resources failed (exit=$($verifyProc.ExitCode)): $verifyOut"
            }

            Write-Host '==> Clean-PATH GUI launch smoke test...'
            $guiProc = Start-Process -FilePath $ExePath -WorkingDirectory $StageDir -PassThru
            try {
                $null = $guiProc.WaitForInputIdle(8000)
                for ($i = 0; $i -lt 20; $i++) {
                    $guiProc.Refresh()
                    if ($guiProc.HasExited -or $guiProc.MainWindowHandle -ne [IntPtr]::Zero) { break }
                    Start-Sleep -Milliseconds 250
                }
                $guiProc.Refresh()
                if ($guiProc.HasExited) {
                    throw "GUI exited prematurely with code $($guiProc.ExitCode)"
                }
                if ($guiProc.MainWindowHandle -eq [IntPtr]::Zero) {
                    throw 'GUI process running but MainWindowHandle is still 0 after waiting'
                }
                Write-Host "GUI smoke test OK (PID=$($guiProc.Id), MainWindowTitle=$($guiProc.MainWindowTitle))"
            }
            finally {
                if (-not $guiProc.HasExited) {
                    $null = $guiProc.CloseMainWindow()
                    if (-not $guiProc.WaitForExit(3000)) {
                        $guiProc.Kill()
                    }
                }
            }
        }
        finally {
            $env:PATH = $origPath
        }
    }

    Write-Host "==> Creating portable archive $ZipPath..."
    Compress-Archive -Path $StageDir -DestinationPath $ZipPath -CompressionLevel Optimal
    $zipInfo = Get-Item $ZipPath
    Write-Host ("==> Done: {0} ({1:N1} MB)" -f $zipInfo.FullName, ($zipInfo.Length / 1MB))
}
finally {
    Pop-Location
}

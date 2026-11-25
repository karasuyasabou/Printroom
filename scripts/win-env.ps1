$ErrorActionPreference = 'Stop'

$msvcRoot = 'D:\DevTools\MSVC'
$swiftRoot = 'D:\DevTools\Swift'
$dotnetRoot = 'D:\DevTools\dotnet'

if (-not (Test-Path $msvcRoot)) { throw "Missing Portable MSVC at $msvcRoot" }
if (-not (Test-Path $swiftRoot)) { throw "Missing Swift toolchain at $swiftRoot" }

$vcToolDir = Get-ChildItem (Join-Path $msvcRoot 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $vcToolDir) { throw "Missing VC Tools inside $msvcRoot" }
$vcToolsVersion = $vcToolDir.Name
$vcToolsInstallDir = $vcToolDir.FullName + '\'

$winSdkDir = Join-Path $msvcRoot 'Windows Kits\10\'
$sdkVerDir = Get-ChildItem (Join-Path $winSdkDir 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkVerDir) { throw "Missing Windows SDK Include inside $winSdkDir" }
$sdkVersion = $sdkVerDir.Name

$swiftToolchainBin = (Get-ChildItem (Join-Path $swiftRoot 'Toolchains') -Recurse -Directory -Filter 'bin' | Where-Object { $_.Parent.Name -eq 'usr' } | Select-Object -First 1).FullName
$swiftRuntimeBin = (Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Recurse -Directory -Filter 'bin' | Where-Object { $_.Parent.Name -eq 'usr' } | Select-Object -First 1).FullName
$swiftSdkRoot = (Get-ChildItem (Join-Path $swiftRoot 'Platforms') -Recurse -Directory -Filter 'Windows.sdk' | Select-Object -First 1).FullName
$swiftSdkBin = Join-Path $swiftSdkRoot 'usr\bin'

if (-not $swiftToolchainBin) { throw "Missing Swift toolchain bin under $swiftRoot" }
if (-not $swiftSdkRoot) { throw "Missing Swift Windows.sdk under $swiftRoot" }

$env:VCToolsVersion = $vcToolsVersion
$env:VCToolsInstallDir = $vcToolsInstallDir
$env:WindowsSdkDir = $winSdkDir
$env:UniversalCRTSdkDir = $winSdkDir
$env:WindowsSDKVersion = $sdkVersion + '\'
$env:UCRTVersion = $sdkVersion
$env:WindowsSdkVerBinPath = Join-Path $winSdkDir "bin\$sdkVersion\"
$env:SDKROOT = $swiftSdkRoot

$env:INCLUDE = @(
  (Join-Path $vcToolsInstallDir 'include'),
  (Join-Path $winSdkDir "Include\$sdkVersion\ucrt"),
  (Join-Path $winSdkDir "Include\$sdkVersion\shared"),
  (Join-Path $winSdkDir "Include\$sdkVersion\um"),
  (Join-Path $winSdkDir "Include\$sdkVersion\winrt"),
  (Join-Path $winSdkDir "Include\$sdkVersion\cppwinrt")
) -join ';'

$env:LIB = @(
  (Join-Path $vcToolsInstallDir 'lib\x64'),
  (Join-Path $winSdkDir "Lib\$sdkVersion\ucrt\x64"),
  (Join-Path $winSdkDir "Lib\$sdkVersion\um\x64")
) -join ';'

$pathEntries = @(
  $swiftToolchainBin,
  $swiftRuntimeBin,
  $swiftSdkBin,
  $dotnetRoot,
  (Join-Path $vcToolsInstallDir 'bin\Hostx64\x64'),
  (Join-Path $winSdkDir "bin\$sdkVersion\x64")
) | Where-Object { $_ -and (Test-Path $_) }

$env:PATH = ($pathEntries -join ';') + ';' + $env:PATH

$repoRoot = Split-Path -Parent $PSScriptRoot
$env:TEMP = 'D:\DevTools\Temp'
$env:TMP = 'D:\DevTools\Temp'
$env:DOTNET_CLI_HOME = 'D:\DevTools\dotnet-home'
$env:NUGET_PACKAGES = 'D:\DevTools\nuget'
$env:CLANG_MODULE_CACHE_PATH = Join-Path $repoRoot '.build\ModuleCache'
$env:SWIFTPM_MODULECACHE_OVERRIDE = Join-Path $repoRoot '.build\ModuleCache'

$shareDir = Join-Path $swiftSdkRoot 'usr\share'
$modulePairs = @(
  @((Join-Path $shareDir 'ucrt.modulemap'), (Join-Path $winSdkDir "Include\$sdkVersion\ucrt\module.modulemap")),
  @((Join-Path $shareDir 'vcruntime.modulemap'), (Join-Path $vcToolsInstallDir 'include\module.modulemap')),
  @((Join-Path $shareDir 'vcruntime.apinotes'), (Join-Path $vcToolsInstallDir 'include\vcruntime.apinotes')),
  @((Join-Path $shareDir 'winsdk_shared.modulemap'), (Join-Path $winSdkDir "Include\$sdkVersion\shared\module.modulemap")),
  @((Join-Path $shareDir 'winsdk_um.modulemap'), (Join-Path $winSdkDir "Include\$sdkVersion\um\module.modulemap"))
)
foreach ($pair in $modulePairs) {
  if ((Test-Path $pair[0]) -and -not (Test-Path $pair[1])) {
    Copy-Item -Force $pair[0] $pair[1]
  }
}

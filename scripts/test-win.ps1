$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
  . (Join-Path $PSScriptRoot 'win-env.ps1')
  $hasFilter = $args -contains '--filter'
  $hasBuildSystem = $args -contains '--build-system'
  $extra = @()
  if (-not $hasBuildSystem) {
    $extra += @('--build-system', 'native')
  }
  if ($hasFilter) {
    swift test @extra @args
  } else {
    swift test @extra --filter PrintroomCoreTests @args
  }
  exit $LASTEXITCODE
} finally {
  Pop-Location
}

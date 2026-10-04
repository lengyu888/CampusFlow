param(
  [ValidateSet('debug', 'release')]
  [string]$BuildMode = 'debug'
)

$ErrorActionPreference = 'Stop'

$devEcoRoot = if ($env:DEVECO_STUDIO_HOME) {
  $env:DEVECO_STUDIO_HOME
} else {
  'C:\Program Files\Huawei\DevEco Studio'
}

$arkUiXSdkRoot = if ($env:ARKUIX_SDK_HOME) {
  $env:ARKUIX_SDK_HOME
} else {
  Join-Path $env:LOCALAPPDATA 'ArkUI-X\Sdk'
}

$hvigor = Join-Path $devEcoRoot 'tools\hvigor\bin\hvigorw.bat'
$nodeRoot = Join-Path $devEcoRoot 'tools\node'
$javaRoot = Join-Path $devEcoRoot 'jbr'
$devEcoSdkRoot = Join-Path $devEcoRoot 'sdk'

foreach ($requiredPath in @($hvigor, $nodeRoot, $javaRoot, $devEcoSdkRoot, $arkUiXSdkRoot)) {
  if (-not (Test-Path -LiteralPath $requiredPath)) {
    throw "Missing build dependency: $requiredPath"
  }
}

$env:NODE_HOME = $nodeRoot
$env:JAVA_HOME = $javaRoot
$env:DEVECO_SDK_HOME = $devEcoSdkRoot
$env:ARKUIX_SDK_HOME = $arkUiXSdkRoot
$env:Path = "$(Join-Path $javaRoot 'bin');$nodeRoot;$env:Path"

& $hvigor assembleHap --mode module -p product=default -p "buildMode=$BuildMode" --no-daemon --stacktrace
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$artifactRoot = Join-Path $PSScriptRoot '..\entry\build\default\outputs\default'
$artifacts = Get-ChildItem -LiteralPath $artifactRoot -Filter '*.hap' -File -ErrorAction SilentlyContinue
if (-not $artifacts) {
  throw "Build completed but no HAP artifact was found in $artifactRoot."
}

$artifacts | Select-Object FullName, Length, LastWriteTime

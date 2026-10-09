function ConvertTo-ArkUiXSdkRoot {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $candidate = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
  if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
    return $null
  }

  $candidate = (Resolve-Path -LiteralPath $candidate).Path

  # Accept the SDK root selected in DevEco Studio, a version directory such as
  # `Sdk\24`, or the final `Sdk\24\arkui-x` directory. Always return the SDK
  # root because both ARKUIX_SDK_HOME and arkui-x.dir expect that level.
  if (Test-Path -LiteralPath (Join-Path $candidate 'sdkConfig.json') -PathType Leaf) {
    if ((Split-Path -Leaf $candidate) -eq 'arkui-x') {
      return (Split-Path -Parent (Split-Path -Parent $candidate))
    }
  }

  if (Test-Path -LiteralPath (Join-Path $candidate 'arkui-x\sdkConfig.json') -PathType Leaf) {
    return (Split-Path -Parent $candidate)
  }

  $version = Get-ChildItem -LiteralPath $candidate -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'arkui-x\sdkConfig.json') -PathType Leaf } |
    Select-Object -First 1
  if ($version) {
    return $candidate
  }

  $sdkChild = Join-Path $candidate 'Sdk'
  if (Test-Path -LiteralPath $sdkChild -PathType Container) {
    return ConvertTo-ArkUiXSdkRoot -Path $sdkChild
  }

  return $null
}

function Get-DevEcoConfiguredArkUiXPath {
  $configRoots = @(
    (Join-Path $env:APPDATA 'Huawei'),
    (Join-Path $env:LOCALAPPDATA 'Huawei')
  ) | Select-Object -Unique

  foreach ($configRoot in $configRoots) {
    if (-not (Test-Path -LiteralPath $configRoot -PathType Container)) {
      continue
    }

    $settingFiles = Get-ChildItem -LiteralPath $configRoot -Filter 'other.xml' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue
    foreach ($settingFile in $settingFiles) {
      $content = Get-Content -LiteralPath $settingFile.FullName -Raw -ErrorAction SilentlyContinue
      if ($content -match '"arkuix\.sdk\.location"\s*:\s*"(?<path>(?:\\\\|[^"])*)"') {
        return $Matches.path.Replace('\\', '\')
      }
    }
  }

  return $null
}

function Get-ProjectConfiguredArkUiXPath {
  param([Parameter(Mandatory)][string]$ProjectRoot)

  $localProperties = Join-Path $ProjectRoot 'local.properties'
  if (-not (Test-Path -LiteralPath $localProperties -PathType Leaf)) {
    return $null
  }

  $line = Get-Content -LiteralPath $localProperties -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '^\s*arkui-x\.dir\s*=' } |
    Select-Object -Last 1
  if (-not $line) {
    return $null
  }

  return (($line -split '=', 2)[1].Trim()).Replace('/', '\')
}

function Resolve-ArkUiXSdkRoot {
  param(
    [AllowNull()][string]$RequestedPath,
    [Parameter(Mandatory)][string]$ProjectRoot
  )

  $candidatePaths = @(
    $RequestedPath,
    $env:ARKUIX_SDK_HOME,
    ([Environment]::GetEnvironmentVariable('ARKUIX_SDK_HOME', 'User')),
    (Get-ProjectConfiguredArkUiXPath -ProjectRoot $ProjectRoot),
    (Get-DevEcoConfiguredArkUiXPath),
    (Join-Path $env:LOCALAPPDATA 'ArkUI-X\Sdk'),
    (Join-Path $env:LOCALAPPDATA 'Huawei\ArkUI-X\Sdk')
  )

  foreach ($candidatePath in $candidatePaths) {
    $resolved = ConvertTo-ArkUiXSdkRoot -Path $candidatePath
    if ($resolved) {
      return $resolved
    }
  }

  throw @"
ArkUI-X SDK was not found.

In DevEco Studio open File > Settings > ArkUI-X, click Edit next to the
installation path, choose an SDK root folder, and install ArkUI-X API 24.
The selected root must contain a path like 24\arkui-x\sdkConfig.json.

Then run either:
  npm run fix:deveco
or:
  npm run fix:deveco -- -SdkPath "D:\path\to\ArkUI-X\Sdk"
"@
}

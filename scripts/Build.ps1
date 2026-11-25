# Windows PowerShell 5.1 以降で実行できます。
# Visual Studio の MSBuild を優先し、見つからなければ .NET SDK の MSBuild を使います。
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
$solutionPath = Join-Path $repositoryDirectory 'CPLogger.sln'

if (-not (Test-Path -LiteralPath $solutionPath -PathType Leaf)) {
    throw "ソリューションが見つかりません: $solutionPath"
}

# 実行環境の .NET Framework と、コンパイル時に必要な参照アセンブリは別物です。
# 4.8 等がインストール済みでも、4.7.2 用 Developer Pack が必要です。
$referenceDirectory = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2'
if (-not (Test-Path -LiteralPath (Join-Path $referenceDirectory 'mscorlib.dll') -PathType Leaf)) {
    throw '.NET Framework 4.7.2 Developer Pack をインストールしてください。'
}

$buildCommand = Get-Command 'MSBuild.exe' -ErrorAction SilentlyContinue
if ($null -ne $buildCommand) {
    & $buildCommand.Source $solutionPath '/m' '/nologo' '/t:Build' "/p:Configuration=$Configuration" '/p:Platform=Any CPU'
} else {
    $vswherePath = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'
    $visualStudioMSBuild = $null
    if (Test-Path -LiteralPath $vswherePath -PathType Leaf) {
        $foundBuildPaths = @(& $vswherePath '-latest' '-products' '*' '-requires' 'Microsoft.Component.MSBuild' '-find' 'MSBuild\**\Bin\MSBuild.exe')
        if ($LASTEXITCODE -eq 0 -and $foundBuildPaths.Count -gt 0) {
            $visualStudioMSBuild = $foundBuildPaths[0]
        }
    }

    if ($visualStudioMSBuild) {
        & $visualStudioMSBuild $solutionPath '/m' '/nologo' '/t:Build' "/p:Configuration=$Configuration" '/p:Platform=Any CPU'
    } else {
        $dotnetCommand = Get-Command 'dotnet.exe' -ErrorAction SilentlyContinue
        if ($null -eq $dotnetCommand) {
            throw 'Visual Studio の MSBuild または .NET SDK が必要です。'
        }
        & $dotnetCommand.Source 'msbuild' $solutionPath '/m' '/nologo' '/t:Build' "/p:Configuration=$Configuration" '/p:Platform=Any CPU'
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "ビルドに失敗しました。終了コード: $LASTEXITCODE"
}

Write-Host "ビルドが完了しました: $Configuration"

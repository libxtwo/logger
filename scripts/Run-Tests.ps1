# 管理者権限やサービス登録を伴わない自動テストを実行します。
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build.ps1') -Configuration $Configuration
}

$repositoryDirectory = Split-Path -Parent $PSScriptRoot
$testExecutable = Join-Path $repositoryDirectory "src\CPLogger.Tests\bin\$Configuration\CPLogger.Tests.exe"
if (-not (Test-Path -LiteralPath $testExecutable -PathType Leaf)) {
    throw "テストプログラムが見つかりません: $testExecutable"
}

& $testExecutable
if ($LASTEXITCODE -ne 0) {
    throw "自動テストで失敗が発生しました。終了コード: $LASTEXITCODE"
}

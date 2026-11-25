# 親 Windows サービスが起動した CPLogger 子プロセスへの実機統合試験です。
# 本体の Test-InstalledService.ps1 を呼び、単発3件と複数プログラム同時呼び出しを照合します。
[CmdletBinding()]
param(
    # 試験の集計・標準出力・読み戻したイベント等を保存する先です。
    [string]$OutputDirectory,
    [ValidatePattern('^[A-Za-z0-9-]{8,80}$')]
    [string]$RunId,
    [ValidateRange(2, 16)] [int]$ProcessCount = 4,
    [ValidateRange(2, 1000)] [int]$RequestsPerProcess = 50,
    [ValidateRange(1, 64)] [int]$ParallelPerProcess = 8,
    [string]$TestClientPath,
    [ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')]
    [string]$ParentServiceName = 'CPLogger.TestParentService',
    [ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')]
    [string]$PipeName = 'CPLogger',
    [string]$ChildExecutablePath,
    [string]$ExpectedServiceAccount = 'NT AUTHORITY\LocalService'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 指定された引数だけを転送し、RunId 省略時は試験本体に一意な値を生成させます。
& (Join-Path $PSScriptRoot 'Test-InstalledService.ps1') @PSBoundParameters

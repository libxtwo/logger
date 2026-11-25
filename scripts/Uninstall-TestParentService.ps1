# 確認用親サービスの登録だけを削除します。実行ファイル・イベントソース・ログは保持します。
[CmdletBinding()]
param(
    # 登録済み実行ファイルの取り違えを防ぐため、登録時と同じ配置先を指定します。
    [string]$InstallationDirectory = (Join-Path $env:ProgramFiles 'CPLogger.ParentTest')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment-Common.ps1')
Assert-DeploymentPrivileges
$InstallationDirectory = Get-DeploymentDirectoryPath $InstallationDirectory
$information = Get-CimInstance -ClassName Win32_Service -Filter "Name='CPLogger.TestParentService'"
if ($null -eq $information) { Write-Host '確認用親サービスは登録されていません。'; return }
$expected = Join-Path $InstallationDirectory 'CPLogger.TestParentService.exe'
$registered = Get-RegisteredServiceExecutable $information.PathName
if (-not [String]::Equals($expected, $registered, [StringComparison]::OrdinalIgnoreCase)) {
    throw "登録済み実行ファイルが指定配置先と一致しません。自動削除しません: $($information.PathName)"
}
$controller = Get-Service -Name 'CPLogger.TestParentService'
try {
    if ($controller.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
        # 親の OnStop が子へ STOP を送り、受理済みログの処理と子の終了を待ちます。
        Stop-Service -Name 'CPLogger.TestParentService'
        $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
    }
} finally { $controller.Dispose() }
& "$env:SystemRoot\System32\sc.exe" 'delete' 'CPLogger.TestParentService' | Out-Host
if ($LASTEXITCODE -ne 0) { throw "親サービスの登録削除に失敗しました: $LASTEXITCODE" }
Write-Host '確認用親サービス登録を削除しました。配置ファイル、イベントソース、ログは保持しています。'

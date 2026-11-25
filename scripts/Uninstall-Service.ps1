# サービス登録のみを削除します。ログとイベントソース、配置済みファイルは保存します。
[CmdletBinding()]
param(
    [string]$InstallationDirectory = (Join-Path $env:ProgramFiles 'CPLogger')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '管理者として起動した Windows PowerShell で実行してください。'
}

$serviceInformation = Get-CimInstance -ClassName Win32_Service -Filter "Name='CPLogger'"
if ($null -eq $serviceInformation) {
    Write-Host 'CPLogger サービスは登録されていません。'
    return
}

# 別の実行ファイルが同名で登録されている場合は、取り違えて削除しないように停止します。
$expectedExecutable = [IO.Path]::GetFullPath((Join-Path $InstallationDirectory 'CPLogger.Service.exe'))
$registeredExecutable = $serviceInformation.PathName.Trim().Trim('"')
if (-not [String]::Equals($registeredExecutable, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
    throw "登録済み実行ファイルが指定配置先と一致しません。正しい -InstallationDirectory を指定してください。登録値: $($serviceInformation.PathName)"
}

$serviceController = Get-Service -Name 'CPLogger'
if ($serviceController.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
    Stop-Service -Name 'CPLogger'
    $serviceController.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
}
$serviceController.Dispose()

& "$env:SystemRoot\System32\sc.exe" 'delete' 'CPLogger'
if ($LASTEXITCODE -ne 0) {
    throw "サービス登録の削除に失敗しました。終了コード: $LASTEXITCODE"
}

Write-Host 'CPLogger サービス登録を削除しました。配置済みファイル、ログ、イベントソースは保持しています。'
Write-Host 'サービス管理画面等が開いていると削除待ちになります。その画面を閉じてから再登録してください。'

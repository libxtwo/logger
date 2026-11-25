# 実機試験専用の親 Windows サービスを配置・登録します。
# ログ出力ワーカー自身はサービス登録せず、親が子プロセスとして起動します。
[CmdletBinding()]
param(
    # 確認用親サービスの Release 出力先です。
    [string]$ParentSourceDirectory,
    # 子ワーカーの Release 出力先です。
    [string]$WorkerSourceDirectory,
    # 新規または空の親サービス配置先です。ワーカーは worker サブフォルダーへ配置します。
    [string]$InstallationDirectory = (Join-Path $env:ProgramFiles 'CPLogger.ParentTest'),
    # LocalService に変更権限を追加するログ保存先です。
    [string[]]$AdditionalLogDirectory = @(),
    # 旧単独 CPLogger サービスを停止・登録削除して移行します。旧ログ・ファイルは残します。
    [switch]$MigrateLegacyService,
    # 旧サービスの実行ファイル照合に使用する旧配置先です。
    [string]$LegacyInstallationDirectory = (Join-Path $env:ProgramFiles 'CPLogger'),
    # 指定した場合だけ、登録後に親サービスを起動します。開始種別は手動です。
    [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment-Common.ps1')
Assert-DeploymentPrivileges
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
if ([String]::IsNullOrWhiteSpace($ParentSourceDirectory)) { $ParentSourceDirectory = Join-Path $repositoryDirectory 'src\CPLogger.TestParentService\bin\Release' }
if ([String]::IsNullOrWhiteSpace($WorkerSourceDirectory)) { $WorkerSourceDirectory = Join-Path $repositoryDirectory 'src\CPLogger.Service\bin\Release' }
$ParentSourceDirectory = Get-DeploymentDirectoryPath $ParentSourceDirectory -AllowReparsePoints
$WorkerSourceDirectory = Get-DeploymentDirectoryPath $WorkerSourceDirectory -AllowReparsePoints
$InstallationDirectory = Get-DeploymentDirectoryPath $InstallationDirectory
$LegacyInstallationDirectory = Get-DeploymentDirectoryPath $LegacyInstallationDirectory
$workerDirectory = Join-Path $InstallationDirectory 'worker'
Assert-EmptyDeploymentDirectory $InstallationDirectory
Assert-LegacyServiceMigration $LegacyInstallationDirectory ([bool]$MigrateLegacyService)
if (Get-Service -Name 'CPLogger.TestParentService' -ErrorAction SilentlyContinue) {
    throw 'CPLogger.TestParentService は既に登録されています。既存登録を確認し、更新時は停止・登録削除後に空の配置先へ再配置してください。'
}
# 親配下へログ用変更権限が付かないことも、子の準備スクリプトを実行する前に検証します。
$null = @(Get-DeploymentLogDirectories (@((Join-Path $env:ProgramData 'CPLogger\Logs')) + @($AdditionalLogDirectory)) @($InstallationDirectory))
$parentFiles = @('CPLogger.TestParentService.exe', 'CPLogger.TestParentService.exe.config')
foreach ($file in $parentFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $ParentSourceDirectory $file) -PathType Leaf)) {
        throw "親の配置元に必要なファイルがありません: $file。先に Release ビルドを完了してください。"
    }
}

# 子の配置・イベントソース・ログ ACL の設定は、通常導入時と共通の手順を使用します。
& (Join-Path $PSScriptRoot 'Prepare-ChildProcess.ps1') -SourceDirectory $WorkerSourceDirectory `
    -InstallationDirectory $workerDirectory -ServiceAccountSid 'S-1-5-19' `
    -AdditionalLogDirectory $AdditionalLogDirectory -MigrateLegacyService:$MigrateLegacyService `
    -LegacyInstallationDirectory $LegacyInstallationDirectory
foreach ($file in $parentFiles) { Copy-Item -LiteralPath (Join-Path $ParentSourceDirectory $file) -Destination $InstallationDirectory }
$parentExecutable = Join-Path $InstallationDirectory 'CPLogger.TestParentService.exe'
$serviceCreated = $false
try {
    # 手動開始で登録し、LocalService への変更が完了する前には起動しません。
    New-Service -Name 'CPLogger.TestParentService' -DisplayName 'CPLogger.TestParentService' `
        -BinaryPathName ('"{0}"' -f $parentExecutable) -StartupType Manual `
        -Description 'CPLogger 子プロセスの起動・停止を確認する試験専用の親 Windows サービス' | Out-Null
    $serviceCreated = $true
    & "$env:SystemRoot\System32\sc.exe" 'config' 'CPLogger.TestParentService' 'obj=' 'NT AUTHORITY\LocalService' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "親サービスの実行アカウント設定に失敗しました: $LASTEXITCODE" }
    if ($Start) {
        Start-Service -Name 'CPLogger.TestParentService'
        $controller = Get-Service -Name 'CPLogger.TestParentService'
        try { $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30)) }
        finally { $controller.Dispose() }
    }
} catch {
    $failure = $_
    if ($serviceCreated) {
        # この実行で作成した登録だけを後始末します。ファイル・ログ・イベントソースは診断用に残します。
        try {
            $controller = Get-Service -Name 'CPLogger.TestParentService'
            try {
                if ($controller.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
                    Stop-Service -Name 'CPLogger.TestParentService'
                    $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
                }
            } finally { $controller.Dispose() }
        } catch { Write-Warning "失敗後の親サービス停止を完了できませんでした: $($_.Exception.Message)" }
        & "$env:SystemRoot\System32\sc.exe" 'delete' 'CPLogger.TestParentService' | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning '失敗後の親サービス登録削除も失敗しました。登録状態を確認してください。' }
    }
    throw $failure
}
Write-Host "確認用親サービス CPLogger.TestParentService を LocalService・手動開始で登録しました: $InstallationDirectory"
if (-not $Start) { Write-Host '設定を確認後、Start-Service CPLogger.TestParentService で親と子を起動してください。' }

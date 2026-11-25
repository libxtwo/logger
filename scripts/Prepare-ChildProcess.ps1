# CPLogger を既存 Windows サービスの子プロセスとして動かすための事前準備を行います。
# CPLogger 自体の Windows サービス登録は作成しません。管理者 Windows PowerShell 5.1 用です。
[CmdletBinding()]
param(
    # Release ビルドで生成したワーカーの exe・config・共有 DLL の格納先です。
    [string]$SourceDirectory,
    # 新規または空の配置先です。親サービスがこの中の exe を子プロセスとして起動します。
    [string]$InstallationDirectory = (Join-Path $env:ProgramFiles 'CPLogger.Child'),
    # 親サービスの実行アカウントの SID です。子は親のアカウントを継承します。
    [string]$ServiceAccountSid = 'S-1-5-19',
    # 業務ログ保存先です。指定しても診断ログ・テストログの既定先は変更しません。
    [string]$LogDirectory = (Join-Path $env:ProgramData 'CPLogger\Logs'),
    # この親サービスアカウントに変更権限を追加する、任意のログ保存先です。
    [string[]]$AdditionalLogDirectory = @(),
    # 旧 CPLogger サービスだけを停止・無効化・登録削除する明示的な移行指定です。
    [switch]$MigrateLegacyService,
    # 旧サービスの実行ファイルを照合するための旧配置先です。
    [string]$LegacyInstallationDirectory = (Join-Path $env:ProgramFiles 'CPLogger')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment-Common.ps1')
Assert-DeploymentPrivileges
if ([String]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\CPLogger.Service\bin\Release'
}

# 全引数と既存サービスを先に検証し、入力誤りによる途中までの変更を抑えます。
# 読み取り専用の配置元には OneDrive 等のリパースポイントを許可します。
# 変更する配置先・ログ ACL 設定先ではリパースポイントを拒否します。
$SourceDirectory = Get-DeploymentDirectoryPath $SourceDirectory -AllowReparsePoints
$InstallationDirectory = Get-DeploymentDirectoryPath $InstallationDirectory
$LegacyInstallationDirectory = Get-DeploymentDirectoryPath $LegacyInstallationDirectory
$accountSid = New-Object Security.Principal.SecurityIdentifier($ServiceAccountSid)
$defaultLogs = Join-Path $env:ProgramData 'CPLogger\Logs'
$logDirectories = @(Get-DeploymentLogDirectories (@($defaultLogs, $LogDirectory) + @($AdditionalLogDirectory)) @($InstallationDirectory))
Assert-EmptyDeploymentDirectory $InstallationDirectory
Assert-LegacyServiceMigration $LegacyInstallationDirectory ([bool]$MigrateLegacyService)
$requiredFiles = @('CPLogger.Service.exe', 'CPLogger.Service.exe.config', 'CPLogger.Shared.dll')
foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory $file) -PathType Leaf)) {
        throw "配置元に必要なファイルがありません: $file。先に Release ビルドを完了してください。"
    }
}
Initialize-CPLoggerEventSource
[IO.Directory]::CreateDirectory($InstallationDirectory) | Out-Null
foreach ($file in $requiredFiles) { Copy-Item -LiteralPath (Join-Path $SourceDirectory $file) -Destination $InstallationDirectory }
Set-DeploymentLogPermissions $logDirectories $accountSid
Invoke-LegacyServiceMigration $LegacyInstallationDirectory ([bool]$MigrateLegacyService)

Write-Host "子プロセス用 CPLogger を配置しました: $InstallationDirectory"
Write-Host "ログ保存先の変更権限を付与した SID: $ServiceAccountSid。CPLogger 自体のサービス登録は作成していません。"
Write-Host '親サービスから --child --parent-pid PID --parent-start-time-utc-ticks TICKS --pipe-name CPLogger を指定し、標準入出力をリダイレクトして起動してください。'

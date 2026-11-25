# 配置スクリプトで共通利用する検証処理です。単体では実行しません。
# 実行ファイル・ログ・既存サービスの取り違えを、変更処理より先に検出します。

# イベントソース、Program Files、サービス登録を操作できる実行環境かを検証します。
function Assert-DeploymentPrivileges {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw '管理者として起動した Windows PowerShell 5.1 (powershell.exe) で実行してください。'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '管理者として起動した Windows PowerShell で実行してください。'
    }
}

# UNC・デバイスパス・ドライブ直下を拒否し、ローカルの絶対ディレクトリへ正規化します。
function Get-DeploymentDirectoryPath([string]$Candidate, [switch]$AllowReparsePoints) {
    if ([String]::IsNullOrWhiteSpace($Candidate) -or $Candidate -notmatch '^[A-Za-z]:\\' -or
        $Candidate.IndexOf(':', 2) -ge 0 -or $Candidate.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
        throw "ローカルドライブの絶対ディレクトリを指定してください: $Candidate"
    }
    $normalized = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    if ($normalized.Length -le 3) { throw "ドライブ直下は指定できません: $Candidate" }
    # ジャンクション経由で別アプリや実行ファイルへ権限を与えないよう、既存の祖先も検査します。
    $existing = $normalized
    while (-not [String]::IsNullOrWhiteSpace($existing)) {
        if (Test-Path -LiteralPath $existing) {
            $item = Get-Item -LiteralPath $existing -Force
            if (-not $item.PSIsContainer) { throw "ディレクトリ以外を含むパスです: $existing" }
            if (-not $AllowReparsePoints -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "配置・権限設定先にジャンクションやシンボリックリンクは使用できません: $existing"
            }
        }
        $existing = [IO.Path]::GetDirectoryName($existing)
    }
    return $normalized
}

# 既存の配置内容へ上書きしないよう、新規または空のフォルダーだけを許可します。
function Assert-EmptyDeploymentDirectory([string]$Directory) {
    if ((Test-Path -LiteralPath $Directory) -and @(Get-ChildItem -LiteralPath $Directory -Force).Count -ne 0) {
        throw "配置先は新規または空のフォルダーを指定してください: $Directory"
    }
}

# 引数のない登録値だけを解釈し、空白を含む引用符付き実行ファイルも正しく取得します。
function Get-RegisteredServiceExecutable([string]$CommandLine) {
    if ($CommandLine -match '^\s*"([^"]+)"\s*$') { return [IO.Path]::GetFullPath($Matches[1]) }
    if ($CommandLine -match '^\s*([^"\s]+\.exe)\s*$') { return [IO.Path]::GetFullPath($Matches[1]) }
    throw "引数付きまたは曖昧なサービス登録値のため、自動変更しません: $CommandLine"
}

# 対象が以前の本プロジェクトのサービスであることを照合し、移行の明示指定を確認します。
function Assert-LegacyServiceMigration([string]$LegacyDirectory, [bool]$Migrate) {
    $legacy = Get-CimInstance -ClassName Win32_Service -Filter "Name='CPLogger'"
    if ($null -eq $legacy) { return }
    $expected = Join-Path $LegacyDirectory 'CPLogger.Service.exe'
    $registered = Get-RegisteredServiceExecutable $legacy.PathName
    if (-not [String]::Equals($registered, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "既存 CPLogger の実行ファイルが旧配置先と一致しません。自動移行しません: $($legacy.PathName)"
    }
    if (-not $Migrate) {
        throw '旧 CPLogger サービスが登録されています。旧登録を停止・削除して子プロセス構成へ移行する場合は -MigrateLegacyService を指定してください。旧ファイル・ログは保持されます。'
    }
}

# 検証済み旧サービスだけを停止・無効化・登録削除します。旧配置ファイルとログは保存します。
function Invoke-LegacyServiceMigration([string]$LegacyDirectory, [bool]$Migrate) {
    Assert-LegacyServiceMigration $LegacyDirectory $Migrate
    $controller = Get-Service -Name 'CPLogger' -ErrorAction SilentlyContinue
    if ($null -eq $controller) { return }
    try {
        if ($controller.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name 'CPLogger'
            $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
        }
        Set-Service -Name 'CPLogger' -StartupType Disabled
        & "$env:SystemRoot\System32\sc.exe" 'delete' 'CPLogger' | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "旧 CPLogger サービスの登録削除に失敗しました: $LASTEXITCODE" }
        Write-Host '旧 CPLogger サービス登録を停止・削除しました。旧実行ファイル・イベントソース・ログは保持しています。'
    } finally { $controller.Dispose() }
}

# ログ用ディレクトリが実行ファイルの配置先またはその祖先・子孫と重複しないことを検証します。
function Get-DeploymentLogDirectories([string[]]$Candidates, [string[]]$ExecutableDirectories) {
    $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $Candidates) {
        $directory = Get-DeploymentDirectoryPath $candidate
        foreach ($executableDirectory in $ExecutableDirectories) {
            if ([String]::Equals($directory, $executableDirectory, [StringComparison]::OrdinalIgnoreCase) -or
                $executableDirectory.StartsWith($directory + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $directory.StartsWith($executableDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "実行ファイルの配置先と重複する場所にはログ用変更権限を付与できません: $directory"
            }
        }
        [void]$directories.Add($directory)
    }
    return @($directories)
}

# 出力先だけへ指定 SID の変更権限を与えます。実行ファイルの書き換え権限は追加しません。
function Set-DeploymentLogPermissions([string[]]$Directories, [Security.Principal.SecurityIdentifier]$AccountSid) {
    foreach ($directory in $Directories) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $acl = Get-Acl -LiteralPath $directory
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $AccountSid, [Security.AccessControl.FileSystemRights]::Modify,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $directory -AclObject $acl
    }
}

# 管理者がイベントソースを事前作成します。ワーカーはレジストリへの作成権限を必要としません。
function Initialize-CPLoggerEventSource {
    if ([Diagnostics.EventLog]::SourceExists('CPLogger')) {
        $log = [Diagnostics.EventLog]::LogNameFromSourceName('CPLogger', '.')
        if ($log -ne 'Application') { throw "イベントソース CPLogger は別ログに登録されています: $log" }
    } else { [Diagnostics.EventLog]::CreateEventSource('CPLogger', 'Application') }
}

# 登録・起動済みの親 Windows サービスと CPLogger 子プロセスに対し、実イベントログと実ファイルを照合します。
# サービス登録、イベントソース作成、ログ削除、サービス停止は行いません。
# Windows PowerShell 5.1 と PowerShell 7 の両方で実行できます。
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidatePattern('^[A-Za-z0-9-]{8,80}$')]
    [string]$RunId = ('LiveTest-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)),
    [ValidateRange(2, 16)] [int]$ProcessCount = 4,
    [ValidateRange(2, 1000)] [int]$RequestsPerProcess = 50,
    [ValidateRange(1, 64)] [int]$ParallelPerProcess = 8,
    [string]$TestClientPath,
    # ログワーカーを子プロセスとして起動している親 Windows サービス名です。
    [ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')]
    [string]$ParentServiceName = 'CPLogger.TestParentService',
    # 子ワーカーと確認用クライアントを接続する、同一 PC 内の名前付きパイプ名です。
    [ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')]
    [string]$PipeName = 'CPLogger',
    # 子 exe の絶対パスです。省略時は親EXE配下のworkerを使用します。定義クラスで配置先を変えた場合は明示します。
    [string]$ChildExecutablePath,
    # 実サービスと子プロセスの実行アカウントの期待値です。
    [string]$ExpectedServiceAccount = 'NT AUTHORITY\LocalService'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
# Windows PowerShell 5.1 の -File 起動では、param の既定値評価時に PSScriptRoot が未設定の場合があります。
# スクリプトの配置先に依存する既定パスは、本文が始まってから組み立てます。
if ([String]::IsNullOrWhiteSpace($TestClientPath)) {
    $TestClientPath = Join-Path $repositoryDirectory 'src\CPLogger.TestClient\bin\Release\CPLogger.TestClient.exe'
}
if ([String]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryDirectory ('artifacts\live-child-service-' + $RunId)
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$summaryPath = Join-Path $OutputDirectory 'summary.json'
if (Test-Path -LiteralPath $summaryPath) { throw "既存の検証結果を上書きしません: $summaryPath" }

# 起動したプロセスのみを追跡します。既存アプリケーションを列挙して停止することはありません。
$startedClients = New-Object 'System.Collections.Generic.List[object]'
$clientResults = New-Object 'System.Collections.Generic.List[object]'
$expected = New-Object 'System.Collections.Generic.List[object]'
$startedUtc = [DateTime]::UtcNow
$summary = [ordered]@{
    Passed = $false
    RunId = $RunId
    StartedUtc = $startedUtc.ToString('O')
    CompletedUtc = $null
    ExpectedSingleCount = 3
    ExpectedConcurrentCount = $ProcessCount * $RequestsPerProcess
    ProcessCount = $ProcessCount
    RequestsPerProcess = $RequestsPerProcess
    ParallelPerProcess = $ParallelPerProcess
    ParentService = $null
    ChildProcess = $null
    PipeName = $PipeName
    OutputDirectory = $OutputDirectory
    SingleLogPath = $null
    ConcurrentLogPath = $null
    FileRecordCount = 0
    EventRecordCount = 0
    ClientResponseCount = 0
    UniqueRequestIds = 0
    ConcurrentProcessLifetimesOverlap = $false
    ConcurrentProcessSequencesInterleave = $false
    ConcurrentProcessSequenceRanges = @()
    ConcurrentSequencesOrdered = $false
    EventAndFileOrderMatches = $false
    RenderedEventMessagesMatch = $false
    TestingPrincipal = $null
    TestingProcessId = $PID
    TestingProcessElevated = $null
    ClientResults = @()
    Error = $null
}

# 条件が成立しなければ、検証結果を保存する finally を通して試験を失敗させます。
function Assert-Condition([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw $Description }
}

# 試験の集計・実際に読み戻した記録を UTF-8 の JSON で保存します。
function Save-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 12), $utf8)
}

# ProcessStartInfo へ渡す引数を Windows の引用符規則でエスケープします。
function ConvertTo-NativeArgument([string]$Value) {
    # シェルを介さず ProcessStartInfo.Arguments を使います。
    # Windows/.NET の引数解析規則に合わせ、引用符直前と末尾の逆斜線を二重化します。
    # 日本語、改行、引用符、空白を含む本文も、単一の引数として子プロセスへ渡します。
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

# 独立した確認用プログラムを起動し、標準出力・標準エラーを直ちに読み始めます。
function Start-Client([string]$Label, [int]$EventId, [string]$EntryType, [string]$Message, [string]$FilePath, [int]$Count, [int]$Parallel) {
    $arguments = @('--event-id', [string]$EventId, '--type', $EntryType, '--message', $Message,
        '--file', $FilePath, '--count', [string]$Count, '--parallel', [string]$Parallel, '--timeout', '60000', '--pipe', $PipeName)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $TestClientPath
    $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName($TestClientPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    Assert-Condition ($process.Start()) ('呼び出しプログラムを起動できません: ' + $Label)
    $client = [pscustomobject]@{
        Label = $Label
        Process = $process
        ProcessId = $process.Id
        StartedUtc = $process.StartTime.ToUniversalTime()
        StandardOutputTask = $process.StandardOutput.ReadToEndAsync()
        StandardErrorTask = $process.StandardError.ReadToEndAsync()
        EventId = $EventId
        EntryType = $EntryType
        Message = $Message
        Count = $Count
        Parallel = $Parallel
        Result = $null
    }
    [void]$startedClients.Add($client)
    return $client
}

# 作成した確認用プログラムの終了コードと、すべての成功応答を照合します。
function Complete-Client($Client) {
    # stdout と stderr は起動直後から非同期に読みます。バッファ満杯による待ち合わせを防ぎます。
    $remaining = [Math]::Max(1, 120000 - [int]([DateTime]::UtcNow - $Client.StartedUtc).TotalMilliseconds)
    Assert-Condition ($Client.Process.WaitForExit($remaining)) ('呼び出しが120秒以内に終了しません: ' + $Client.Label)
    $stdout = $Client.StandardOutputTask.GetAwaiter().GetResult()
    $stderr = $Client.StandardErrorTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $OutputDirectory ($Client.Label + '.stdout.txt')), $stdout, $utf8)
    [IO.File]::WriteAllText((Join-Path $OutputDirectory ($Client.Label + '.stderr.txt')), $stderr, $utf8)
    $result = [pscustomobject]@{
        Label = $Client.Label
        ProcessId = $Client.ProcessId
        StartedUtc = $Client.StartedUtc.ToString('O')
        CompletedUtc = $Client.Process.ExitTime.ToUniversalTime().ToString('O')
        ExitCode = $Client.Process.ExitCode
        EventId = $Client.EventId
        EntryType = $Client.EntryType
        Count = $Client.Count
        Parallel = $Client.Parallel
        Responses = @()
    }
    $Client.Result = $result
    [void]$clientResults.Add($result)
    Assert-Condition ($result.ExitCode -eq 0) ('呼び出しプログラム失敗: ' + $Client.Label + ' / ' + $stderr)
    Assert-Condition ([String]::IsNullOrWhiteSpace($stderr)) ('標準エラー出力があります: ' + $Client.Label + ' / ' + $stderr)
    $responsePattern = '(?m)^\d+/\d+ RequestId=(?<id>[0-9a-fA-F-]{36}) 順序=(?<sequence>\d+) 受付=True イベントログ=True ファイル=True\r?$'
    $responses = @([Regex]::Matches($stdout, $responsePattern) | ForEach-Object {
        [pscustomobject]@{ RequestId = $_.Groups['id'].Value; Sequence = [long]$_.Groups['sequence'].Value }
    })
    $result.Responses = $responses
    Assert-Condition ($responses.Count -eq $Client.Count) ('成功応答件数が一致しません: ' + $Client.Label)
    Assert-Condition ($stdout.Contains(('完了: 要求={0}, 成功={0}, 失敗=0,' -f $Client.Count))) ('正常完了の集計がありません: ' + $Client.Label)
}

# JSON Lines を読み戻し、件数・受付順・試験の識別子を検査します。
function Read-LogRecords([string]$Path, [int]$ExpectedCount) {
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) ('出力ファイルがありません: ' + $Path)
    # JSON Lines の全行を復元します。途中の壊れた行、空行、余分な行も試験失敗にします。
    $lines = [IO.File]::ReadAllLines($Path, $utf8)
    Assert-Condition ($lines.Length -eq $ExpectedCount) ('ファイルの行数が一致しません: ' + $Path + ' / 実際=' + $lines.Length)
    $records = @($lines | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    $previousSequence = 0L
    foreach ($record in $records) {
        Assert-Condition ([long]$record.Sequence -gt $previousSequence) ('ファイルの受付番号が昇順ではありません: ' + $Path)
        $previousSequence = [long]$record.Sequence
        Assert-Condition ([string]$record.Message).Contains($RunId) ('別試験のメッセージが混在しています: ' + $Path)
    }
    return $records
}

try {
    $testingIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $testingPrincipal = New-Object Security.Principal.WindowsPrincipal($testingIdentity)
    $summary.TestingPrincipal = $testingIdentity.Name
    $summary.TestingProcessElevated = $testingPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $TestClientPath = [IO.Path]::GetFullPath($TestClientPath)
    Assert-Condition (Test-Path -LiteralPath $TestClientPath -PathType Leaf) ('Release の確認用プログラムがありません: ' + $TestClientPath)
    $service = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $ParentServiceName)
    Assert-Condition ($null -ne $service) ('親サービスが登録されていません。先に Install-TestParentService.ps1 を実行してください: ' + $ParentServiceName)
    Assert-Condition ($service.State -eq 'Running') ('親サービスが起動していません: ' + $ParentServiceName)
    Assert-Condition ([String]::Equals($service.StartName, $ExpectedServiceAccount, [StringComparison]::OrdinalIgnoreCase)) ('親サービスの実行アカウントが期待値と一致しません: ' + $service.StartName)
    $summary.ParentService = [ordered]@{ Name = $service.Name; State = $service.State; StartName = $service.StartName; ProcessId = $service.ProcessId; PathName = $service.PathName; StartMode = $service.StartMode }
    # 子の既定配置先は親EXEの配置フォルダーを基準に解決します。
    if ($service.PathName -match '^\s*"([^"]+)"') { $parentExecutable = $Matches[1] }
    elseif ($service.PathName -match '^\s*([^\s]+\.exe)') { $parentExecutable = $Matches[1] }
    else { throw ('親サービスの実行ファイルを解決できません: ' + $service.PathName) }
    if ([String]::IsNullOrWhiteSpace($ChildExecutablePath)) {
        $ChildExecutablePath = Join-Path ([IO.Path]::GetDirectoryName($parentExecutable)) 'worker\CPLogger.Service.exe'
    }
    $ChildExecutablePath = [IO.Path]::GetFullPath($ChildExecutablePath)
    # 単に同名 exe が存在するだけでは不十分です。OS が記録した親 PID・パス・所有者を検証します。
    $children = @(Get-CimInstance -ClassName Win32_Process -Filter ('ParentProcessId={0}' -f $service.ProcessId) |
        Where-Object { $_.Name -eq 'CPLogger.Service.exe' })
    Assert-Condition ($children.Count -eq 1) '親サービス直下の CPLogger 子プロセスがちょうど1個ではありません。'
    $child = $children[0]
    Assert-Condition (-not [String]::IsNullOrWhiteSpace([string]$child.ExecutablePath)) '子プロセスのパスを取得できません。プロセスの実行アカウント確認のため、管理者 PowerShell でこの統合試験を実行してください。'
    Assert-Condition ([String]::Equals($child.ExecutablePath, $ChildExecutablePath, [StringComparison]::OrdinalIgnoreCase)) ('子プロセスの実行ファイルが期待値と一致しません: ' + $child.ExecutablePath)
    $owner = Invoke-CimMethod -InputObject $child -MethodName GetOwner
    Assert-Condition ($owner.ReturnValue -eq 0) '子プロセスの実行アカウントを取得できません。管理者 PowerShell で実行してください。'
    $childAccount = $owner.Domain + '\' + $owner.User
    $ownerSid = Invoke-CimMethod -InputObject $child -MethodName GetOwnerSid
    Assert-Condition ($ownerSid.ReturnValue -eq 0) '子プロセスの実行アカウント SID を取得できません。管理者 PowerShell で実行してください。'
    # SCM の LocalService と WMI の LOCAL SERVICE は同じアカウントです。表示名の差を SID で吸収します。
    if ([String]::Equals($ExpectedServiceAccount, 'NT AUTHORITY\LocalService', [StringComparison]::OrdinalIgnoreCase)) {
        $expectedAccountSid = 'S-1-5-19'
    } else {
        $expectedAccount = New-Object Security.Principal.NTAccount($ExpectedServiceAccount)
        $expectedAccountSid = $expectedAccount.Translate([Security.Principal.SecurityIdentifier]).Value
    }
    Assert-Condition ($ownerSid.Sid -eq $expectedAccountSid) ('子プロセスの実行アカウント SID が期待値と一致しません: ' + $childAccount + ' / ' + $ownerSid.Sid)
    $summary.ChildProcess = [ordered]@{ Name = $child.Name; ProcessId = $child.ProcessId; ParentProcessId = $child.ParentProcessId; ExecutablePath = $child.ExecutablePath; CommandLine = $child.CommandLine; Account = $childAccount; AccountSid = $ownerSid.Sid; CreationDate = $child.CreationDate.ToUniversalTime().ToString('O') }
    $summary.TestClientSha256 = (Get-FileHash -LiteralPath $TestClientPath -Algorithm SHA256).Hash
    $logDirectory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'CPLogger\Logs'
    $singleLogPath = Join-Path $logDirectory ($RunId + '-single.log')
    $concurrentLogPath = Join-Path $logDirectory ($RunId + '-concurrent.log')
    $summary.SingleLogPath = $singleLogPath
    $summary.ConcurrentLogPath = $concurrentLogPath
    Assert-Condition (-not (Test-Path -LiteralPath $singleLogPath)) 'この RunId の単発試験ログが既に存在します。新しい RunId を指定してください。'
    Assert-Condition (-not (Test-Path -LiteralPath $concurrentLogPath)) 'この RunId の並行試験ログが既に存在します。新しい RunId を指定してください。'

    $types = @('Error', 'Warning', 'Information')
    $emoji = [char]::ConvertFromUtf32(0x1F600)
    for ($index = 0; $index -lt 3; $index++) {
        $body = '{0} 単発試験 {1} 日本語 "引用符" 逆斜線\ {2}' -f $RunId, $types[$index], $emoji
        if ($index -eq 0) { $body += "`r`n改行したメッセージも欠けずに保存されます。" }
        [void]$expected.Add([pscustomobject]@{ Message = $body; EventId = 41001 + $index; EntryType = $types[$index] })
        $singleClient = Start-Client ('single-' + $types[$index]) (41001 + $index) $types[$index] $body $singleLogPath 1 1
        Complete-Client $singleClient
    }

    # 全プロセスを起動し終えるまで待ち合わせません。それぞれが複数のパイプ接続を並行実行します。
    # 既定では 4 プロセス × 8 並列で、サービスの既定16接続を超える状態も確認します。
    $concurrentClients = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt $ProcessCount; $index++) {
        $entryType = $types[$index % $types.Length]
        $body = '{0} 並行試験 Batch={1}' -f $RunId, $index
        $client = Start-Client ('concurrent-' + $index) (42000 + $index) $entryType $body $concurrentLogPath $RequestsPerProcess $ParallelPerProcess
        [void]$concurrentClients.Add($client)
        for ($number = 1; $number -le $RequestsPerProcess; $number++) {
            [void]$expected.Add([pscustomobject]@{
                Message = $body + (' [PID={0}, No={1}]' -f $client.ProcessId, $number)
                EventId = 42000 + $index
                EntryType = $entryType
            })
        }
    }
    foreach ($client in $concurrentClients) { Complete-Client $client }

    # 単に別プロセスを順に起動しただけになっていないか、実際の OS の開始・終了時刻で確認します。
    $latestStart = ($concurrentClients | ForEach-Object { $_.StartedUtc } | Sort-Object | Select-Object -Last 1)
    $earliestEnd = ($concurrentClients | ForEach-Object { $_.Process.ExitTime.ToUniversalTime() } | Sort-Object | Select-Object -First 1)
    $summary.ConcurrentProcessLifetimesOverlap = $latestStart -lt $earliestEnd
    Assert-Condition $summary.ConcurrentProcessLifetimesOverlap '全プロセスの実行時間が重なっていません。件数を増やして再検証してください。'

    $singleRecords = @(Read-LogRecords $singleLogPath 3)
    $concurrentRecords = @(Read-LogRecords $concurrentLogPath ($ProcessCount * $RequestsPerProcess))
    $allRecords = @($singleRecords) + @($concurrentRecords)
    $summary.FileRecordCount = $allRecords.Count
    $summary.ConcurrentSequencesOrdered = $true
    Save-Json (Join-Path $OutputDirectory 'file-records.json') $allRecords
    # OS上の生存時間だけでなく、異なるPIDの要求が受付番号の途中に入り込んだことも確認します。
    $sequenceRanges = @($concurrentClients | ForEach-Object {
        $clientPid = $_.ProcessId
        $pidMarker = ' [PID=' + $clientPid + ', No='
        $pidRecords = @($concurrentRecords | Where-Object { ([string]$_.Message).Contains($pidMarker) })
        Assert-Condition ($pidRecords.Count -eq $RequestsPerProcess) ('プロセス別のファイル件数が一致しません: PID=' + $clientPid)
        $range = $pidRecords | Measure-Object -Property Sequence -Minimum -Maximum
        [pscustomobject]@{ ProcessId = $clientPid; Count = $pidRecords.Count; MinimumSequence = [long]$range.Minimum; MaximumSequence = [long]$range.Maximum }
    })
    $summary.ConcurrentProcessSequenceRanges = $sequenceRanges
    for ($left = 0; $left -lt $sequenceRanges.Count; $left++) {
        for ($right = $left + 1; $right -lt $sequenceRanges.Count; $right++) {
            if ($sequenceRanges[$left].MinimumSequence -lt $sequenceRanges[$right].MaximumSequence -and
                $sequenceRanges[$right].MinimumSequence -lt $sequenceRanges[$left].MaximumSequence) {
                $summary.ConcurrentProcessSequencesInterleave = $true
            }
        }
    }
    Assert-Condition $summary.ConcurrentProcessSequencesInterleave '異なるプロセスの要求が実際の受付順で交錯していません。件数を増やして再検証してください。'
    # メッセージは大文字・小文字も含めた完全一致で比較します。
    $recordsByMessage = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $recordsByRequestId = @{}
    $sequenceSet = New-Object 'System.Collections.Generic.HashSet[long]'
    foreach ($record in $allRecords) {
        Assert-Condition (-not $recordsByMessage.ContainsKey([string]$record.Message)) 'ファイルに重複メッセージがあります。'
        Assert-Condition (-not $recordsByRequestId.ContainsKey([string]$record.RequestId)) 'ファイルに重複 RequestId があります。'
        Assert-Condition ($sequenceSet.Add([long]$record.Sequence)) 'ファイルに重複した受付番号があります。'
        $recordsByMessage[[string]$record.Message] = $record
        $recordsByRequestId[[string]$record.RequestId] = $record
    }
    $summary.UniqueRequestIds = $recordsByRequestId.Count
    Assert-Condition ($allRecords.Count -eq $expected.Count) 'ファイルと要求の総数が一致しません。'
    foreach ($item in $expected) {
        Assert-Condition ($recordsByMessage.ContainsKey($item.Message)) ('ファイルに要求がありません: ' + $item.Message)
        $record = $recordsByMessage[$item.Message]
        Assert-Condition ([String]::Equals($record.Message, $item.Message, [StringComparison]::Ordinal)) 'ファイルの本文が要求と完全一致しません。'
        Assert-Condition ([int]$record.EventId -eq $item.EventId -and [string]$record.EntryType -ceq $item.EntryType) 'ファイルのイベント ID または区分が指定値と一致しません。'
    }

    # 応答にも全 RequestId が返り、ファイルに保存された受付番号と一致することを確認します。
    $responseIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($clientResult in $clientResults) {
        foreach ($response in $clientResult.Responses) {
            Assert-Condition ($responseIds.Add($response.RequestId)) '成功応答の RequestId が重複しています。'
            Assert-Condition ($recordsByRequestId.ContainsKey($response.RequestId)) '成功応答に対応するファイルレコードがありません。'
            Assert-Condition ([long]$recordsByRequestId[$response.RequestId].Sequence -eq $response.Sequence) '応答とファイルの受付番号が一致しません。'
        }
    }
    $summary.ClientResponseCount = $responseIds.Count
    Assert-Condition ($responseIds.Count -eq $expected.Count) '成功応答件数が要求の総数と一致しません。'

    # イベントは、この実行の識別子を含むものだけを抽出します。過去のイベントを消去しません。
    # イベントビューアーの表示用本文ではなく、記録された挿入文字列を照合の基準にします。
    $eventRecords = @()
    $eventQuery = @{ LogName = 'Application'; ProviderName = 'CPLogger'; StartTime = $startedUtc.AddSeconds(-2).ToLocalTime() }
    $rawEvents = @(Get-WinEvent -FilterHashtable $eventQuery -ErrorAction Stop)
    foreach ($event in $rawEvents) {
        try {
            if ($event.Properties.Count -lt 1) { continue }
            $eventMessage = [string]$event.Properties[0].Value
            if (-not $eventMessage.Contains($RunId)) { continue }
            $entryType = switch ([int]$event.Level) { 2 { 'Error' } 3 { 'Warning' } 4 { 'Information' } default { 'Unknown' } }
            $rendered = $null
            try { $rendered = $event.Message } catch { }
            $eventRecords += [pscustomobject]@{
                RecordId = [long]$event.RecordId
                TimeCreatedUtc = $event.TimeCreated.ToUniversalTime().ToString('O')
                EventId = [int]$event.Id
                EntryType = $entryType
                Message = $eventMessage
                RenderedMessage = $rendered
                RenderedMessageMatches = [String]::Equals($eventMessage, $rendered, [StringComparison]::Ordinal)
            }
        } finally { $event.Dispose() }
    }
    $eventRecords = @($eventRecords | Sort-Object RecordId)
    $summary.EventRecordCount = $eventRecords.Count
    Save-Json (Join-Path $OutputDirectory 'event-records.json') $eventRecords
    Assert-Condition ($eventRecords.Count -eq $expected.Count) ('イベント件数が一致しません。期待=' + $expected.Count + ' / 実際=' + $eventRecords.Count)
    $eventMessages = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($eventRecord in $eventRecords) {
        Assert-Condition ($eventMessages.Add($eventRecord.Message)) 'イベントログに重複メッセージがあります。'
        Assert-Condition ($recordsByMessage.ContainsKey($eventRecord.Message)) 'イベントに対応するファイルレコードがありません。'
        $record = $recordsByMessage[$eventRecord.Message]
        Assert-Condition ([String]::Equals($record.Message, $eventRecord.Message, [StringComparison]::Ordinal)) 'イベントの本文がファイルと完全一致しません。'
        Assert-Condition ([int]$record.EventId -eq $eventRecord.EventId -and [string]$record.EntryType -ceq $eventRecord.EntryType) 'イベントとファイルの ID または区分が一致しません。'
    }
    # 単一ワーカーはイベント→ファイルの順で1件ずつ完了します。両保存先の実順序も同一であるべきです。
    $orderedFiles = @($allRecords | Sort-Object { [long]$_.Sequence })
    for ($index = 0; $index -lt $orderedFiles.Count; $index++) {
        Assert-Condition ([String]::Equals($orderedFiles[$index].Message, $eventRecords[$index].Message, [StringComparison]::Ordinal)) 'イベントの RecordId 順とファイルの受付番号順が一致しません。'
    }
    $summary.EventAndFileOrderMatches = $true
    $summary.RenderedEventMessagesMatch = @($eventRecords | Where-Object { -not $_.RenderedMessageMatches }).Count -eq 0
    Assert-Condition $summary.RenderedEventMessagesMatch 'イベントビューアーの表示用本文が指定メッセージと完全一致しません。'
    $summary.Passed = $true
    Write-Host ('PASS: 単発3件 + {0}プロセス × {1}件 = 合計{2}件。成功応答・イベント・ファイルをすべて照合しました。' -f $ProcessCount, $RequestsPerProcess, $expected.Count)
    Write-Host ('イベント/ファイル順序一致、RequestId重複なし、全プロセス実行時間の重複あり。結果: ' + $summaryPath)
} catch {
    $summary.Error = $_.Exception.ToString()
    throw
} finally {
    foreach ($client in $startedClients) {
        try {
            if (-not $client.Process.HasExited) {
                # このスクリプトが作成したプロセスだけを、異常終了時に後始末します。
                $client.Process.Kill()
                [void]$client.Process.WaitForExit(5000)
            }
        } finally { $client.Process.Dispose() }
    }
    $summary.CompletedUtc = [DateTime]::UtcNow.ToString('O')
    $summary.ClientResults = @($clientResults.ToArray())
    Save-Json $summaryPath $summary
}

# Windows Event Logger

Windows の **アプリケーション** イベントログに書き込む C# ロガーです。情報・警告・エラー、イベント ID（0～65535）、メッセージを指定できます。Windows と .NET 10 SDK が必要です。

## 実行方法

このフォルダーでビルドします。

```powershell
dotnet build
```

初回だけ、**管理者として起動した PowerShell** で同じフォルダーを開き、イベントソースを登録します。

```powershell
.\bin\Debug\net10.0-windows\WindowsEventLogger.exe register
```

以降は通常の PowerShell から書き込めます。実行ユーザーには Application ログへの書き込み権限が必要です。

```powershell
.\bin\Debug\net10.0-windows\WindowsEventLogger.exe write info 1000 'アプリケーションを起動しました。'
.\bin\Debug\net10.0-windows\WindowsEventLogger.exe write warning 2000 '設定値を既定値に戻しました。'
.\bin\Debug\net10.0-windows\WindowsEventLogger.exe write error 3000 '処理に失敗しました。'
```

イベントビューアーの **Windows ログ → Application（アプリケーション）** を開き、ソース `CSharpEventLogger` で確認できます。PowerShell でも確認できます。

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'CSharpEventLogger' } -MaxEvents 5 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message
```

ソース名を変更する場合は、`register` と `write` の最後に同じ名前を指定してください。

## C# コードから呼び出す

Windows 向けの .NET プロジェクトに `WindowsEventLogger.cs` を追加し、`System.Diagnostics.EventLog` パッケージを参照します。上記の手順でソースを登録してから使用してください。

```csharp
using System.Diagnostics;
using WindowsEventLogging;

var logger = new WindowsEventLogger();
logger.Write("アプリケーションを起動しました。", eventId: 1000);
logger.Write("設定値を既定値に戻しました。", EventLogEntryType.Warning, 2000);
```

using System.Diagnostics;
using Microsoft.Win32;

namespace WindowsEventLogging;

public sealed class WindowsEventLogger
{
    public const string DefaultSource = "CSharpEventLogger";
    public const string LogName = "Application";

    private readonly string _source;

    public WindowsEventLogger(string source = DefaultSource)
    {
        ValidateSource(source);

        // Check only Application so this also works without access to the Security log.
        using var key = Registry.LocalMachine.OpenSubKey(
            $@"SYSTEM\CurrentControlSet\Services\EventLog\{LogName}\{source}");
        if (key is null)
        {
            throw new InvalidOperationException(
                $"イベントソース「{source}」は Application ログに未登録です。管理者として register を実行してください。");
        }

        _source = source;
    }

    // Run once during installation from an elevated process. Safe to run again.
    public static void RegisterSource(string source = DefaultSource)
    {
        ValidateSource(source);
        var existingLog = EventLog.LogNameFromSourceName(source, ".");

        if (string.IsNullOrEmpty(existingLog))
        {
            EventLog.CreateEventSource(source, LogName);
        }
        else if (!string.Equals(existingLog, LogName, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"イベントソース「{source}」は既に「{existingLog}」ログに登録されています。別の名前を指定してください。");
        }
    }

    public void Write(string message, EventLogEntryType level = EventLogEntryType.Information, int eventId = 0)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        if (message.Contains('\0'))
        {
            throw new ArgumentException("メッセージに NUL 文字は使用できません。", nameof(message));
        }

        if (level is not (EventLogEntryType.Information or EventLogEntryType.Warning or EventLogEntryType.Error))
        {
            throw new ArgumentOutOfRangeException(nameof(level), "情報、警告、エラーのいずれかを指定してください。");
        }

        ArgumentOutOfRangeException.ThrowIfNegative(eventId);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(eventId, ushort.MaxValue);

        using var log = new EventLog(LogName, ".", _source);
        log.WriteEntry(message, level, eventId);
    }

    private static void ValidateSource(string source)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(source);
        if (source.Contains('\\') || source.Contains('\0'))
        {
            throw new ArgumentException("イベントソース名にバックスラッシュや NUL 文字は使用できません。", nameof(source));
        }
    }
}

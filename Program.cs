using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Security;
using System.Security.Principal;
using WindowsEventLogging;

const string usage = """
    使用方法:
      WindowsEventLogger register [source]
      WindowsEventLogger write <info|warning|error> <event-id> <message> [source]

    source の既定値: CSharpEventLogger
    event-id: 0～65535
    register は管理者として実行してください。
    """;

if (args is [] or ["--help"] or ["-h"])
{
    Console.WriteLine(usage);
    return 0;
}

try
{
    switch (args[0])
    {
        case "register" when args.Length is 1 or 2:
        {
            using var identity = WindowsIdentity.GetCurrent();
            if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
            {
                Console.Error.WriteLine("register は管理者として実行してください。");
                return 1;
            }

            var source = args.Length == 2 ? args[1] : WindowsEventLogger.DefaultSource;
            WindowsEventLogger.RegisterSource(source);
            Console.WriteLine($"イベントソース「{source}」は Application ログに登録済みです。");
            return 0;
        }

        case "write" when args.Length is 4 or 5:
        {
            var level = args[1].ToLowerInvariant() switch
            {
                "info" => EventLogEntryType.Information,
                "warning" => EventLogEntryType.Warning,
                "error" => EventLogEntryType.Error,
                _ => throw new ArgumentException("レベルは info、warning、error のいずれかを指定してください。"),
            };

            if (!ushort.TryParse(args[2], NumberStyles.None, CultureInfo.InvariantCulture, out var eventId))
            {
                throw new ArgumentException("イベント ID は 0～65535 の整数を指定してください。");
            }

            var source = args.Length == 5 ? args[4] : WindowsEventLogger.DefaultSource;
            new WindowsEventLogger(source).Write(args[3], level, eventId);
            Console.WriteLine($"Application ログに書き込みました (ソース: {source}, ID: {eventId})。");
            return 0;
        }

        default:
            Console.Error.WriteLine(usage);
            return 2;
    }
}
catch (ArgumentException ex)
{
    Console.Error.WriteLine(ex.Message);
    return 2;
}
catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or SecurityException or UnauthorizedAccessException)
{
    Console.Error.WriteLine($"イベントログの操作に失敗しました: {ex.Message}");
    return 1;
}

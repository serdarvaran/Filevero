using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace Filevero.Core;

public sealed record OperationProgress(double? Fraction, string Label);
public sealed record ProcessResult(string Output, string Error);

public static class ProcessRunner
{
    public static async Task<ProcessResult> RunAsync(string executable, IEnumerable<string> arguments,
        CancellationToken token = default, Action<string>? outputLine = null)
    {
        token.ThrowIfCancellationRequested();
        if (!Path.IsPathFullyQualified(executable)) throw new ArgumentException("A fully qualified tool path is required.");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
            RedirectStandardInput = true, CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        var values = arguments.ToList();
        var tool = Path.GetFileNameWithoutExtension(executable).ToLowerInvariant();
        var restrict = tool is "ffmpeg" or "ffprobe" && !values.Contains("-protocol_whitelist");
        // ffprobe takes one positional input; ffmpeg's whitelist is a per-input option, so every -i gets its own.
        if (restrict && tool == "ffprobe") { start.ArgumentList.Add("-protocol_whitelist"); start.ArgumentList.Add(Protocols); }
        foreach (var value in values)
        {
            if (restrict && tool == "ffmpeg" && value == "-i") { start.ArgumentList.Add("-protocol_whitelist"); start.ArgumentList.Add(Protocols); }
            start.ArgumentList.Add(value);
        }
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new IOException("The processing tool could not start.");
        process.StandardInput.Close();
        using var cancellation = token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        // Streamed output keeps only its tail; output parsed afterwards (JSON) must arrive whole.
        var stdout = DrainAsync(process.StandardOutput, outputLine, keepWhole: outputLine is null);
        var stderr = DrainAsync(process.StandardError, null, keepWhole: false);
        await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        var results = await Task.WhenAll(stdout, stderr).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (results[0] is null) throw new InvalidDataException("The tool returned too much data to read.");
        var error = results[1]!;
        if (process.ExitCode != 0) throw new IOException(string.IsNullOrWhiteSpace(error) ? "The processing tool failed." : error[Math.Max(0, error.Length - 6000)..].Trim());
        return new(results[0]!, error);
    }

    private const string Protocols = "file,pipe,crypto,data";
    private const int TailLimit = 2_000_000, WholeLimit = 32_000_000;

    private static async Task<string?> DrainAsync(StreamReader stream, Action<string>? onLine, bool keepWhole)
    {
        var capture = new StringBuilder(); var overflow = false; var line = new StringBuilder(); var buffer = new char[4096];
        while (true)
        {
            var count = await stream.ReadAsync(buffer).ConfigureAwait(false);
            if (count == 0) break;
            capture.Append(buffer, 0, count);
            // Keep reading after an overflow so the tool never blocks on a full pipe.
            if (keepWhole && capture.Length > WholeLimit) { overflow = true; capture.Clear(); }
            if (!keepWhole && capture.Length > TailLimit) capture.Remove(0, capture.Length - TailLimit);
            if (onLine is null) continue;
            for (var index = 0; index < count; index++)
            {
                var character = buffer[index];
                if (character == '\n') { onLine(line.ToString().TrimEnd('\r')); line.Clear(); }
                else if (line.Length < 16_384) line.Append(character);
            }
        }
        if (onLine is not null && line.Length > 0) onLine(line.ToString());
        return overflow ? null : capture.ToString();
    }
}

public sealed class FFmpegProgress(double? duration, Action<OperationProgress> report, string label)
{
    private double last;
    public void ReadLine(string line)
    {
        const string prefix = "out_time_us=";
        if (duration is not > 0 || !double.IsFinite(duration.Value) || !line.StartsWith(prefix, StringComparison.Ordinal) ||
            !double.TryParse(line[prefix.Length..], NumberStyles.Float, CultureInfo.InvariantCulture, out var microseconds) ||
            !double.IsFinite(microseconds) || microseconds < 0) return;
        var fraction = Math.Min(.995, microseconds / 1_000_000 / duration.Value);
        if (fraction <= last) return;
        last = fraction; report(new(fraction, label));
    }
}

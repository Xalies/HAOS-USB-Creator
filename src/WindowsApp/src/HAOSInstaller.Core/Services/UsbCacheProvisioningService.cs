using HAOSInstaller.Core.Models;
using System.Diagnostics;
using System.Management;
using System.Runtime.Versioning;
using System.Text.Json;

namespace HAOSInstaller.Core.Services;

public sealed class UsbCacheProvisioningService
{
    private const int CopyBufferSize = 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public async Task WriteInstallerConfigAsync(
        string usbCacheRoot,
        bool unattendedInstallEnabled,
        CancellationToken cancellationToken)
    {
        var destinationCacheDirectory = Path.Combine(usbCacheRoot, "cache");
        Directory.CreateDirectory(destinationCacheDirectory);

        var config = new InstallerConfig(
            SchemaVersion: 1,
            Unattended: new UnattendedInstallConfig(
                Enabled: unattendedInstallEnabled,
                Mode: unattendedInstallEnabled ? "first-available-single-disk" : "disabled",
                RunOnce: unattendedInstallEnabled));

        var configPath = Path.Combine(destinationCacheDirectory, "installer-config.json");
        await using var stream = new FileStream(configPath, FileMode.Create, FileAccess.Write, FileShare.Read, 16 * 1024, useAsync: true);
        await JsonSerializer.SerializeAsync(stream, config, JsonOptions, cancellationToken);
    }

    public async Task<UsbCacheProvisionResult> ProvisionAsync(
        HaosPayloadStageResult stagedPayload,
        string usbCacheRoot,
        IProgress<ImageWriteProgress> progress,
        CancellationToken cancellationToken)
    {
        if (!Directory.Exists(stagedPayload.CacheDirectory))
        {
            throw new DirectoryNotFoundException($"Prepared Home Assistant OS files were not found: {stagedPayload.CacheDirectory}");
        }

        var destinationCacheDirectory = Path.Combine(usbCacheRoot, "cache");
        Directory.CreateDirectory(destinationCacheDirectory);

        progress.Report(new ImageWriteProgress("Adding Home Assistant OS to the USB.", 0));

        var imageDestination = Path.Combine(destinationCacheDirectory, Path.GetFileName(stagedPayload.ImagePath));
        var checksumDestination = Path.Combine(destinationCacheDirectory, Path.GetFileName(stagedPayload.ChecksumPath));
        var manifestDestination = Path.Combine(destinationCacheDirectory, "manifest.json");

        await CopyFileAsync(
            stagedPayload.ImagePath,
            imageDestination,
            "Home Assistant OS image",
            startPercent: 0,
            endPercent: 94,
            progress,
            cancellationToken);
        progress.Report(new ImageWriteProgress("Home Assistant OS image copied.", 94));

        progress.Report(new ImageWriteProgress("Finishing USB setup.", 97));
        await CopySmallFileAsync(stagedPayload.ChecksumPath, checksumDestination, cancellationToken);
        await CopySmallFileAsync(stagedPayload.ManifestPath, manifestDestination, cancellationToken);
        progress.Report(new ImageWriteProgress("Finished adding Home Assistant OS to the USB.", 100));

        return new UsbCacheProvisionResult(destinationCacheDirectory, imageDestination, checksumDestination, manifestDestination);
    }

    private static async Task CopyFileAsync(
        string source,
        string destination,
        string label,
        double startPercent,
        double endPercent,
        IProgress<ImageWriteProgress> progress,
        CancellationToken cancellationToken)
    {
        var sourceInfo = new FileInfo(source);
        var totalBytes = sourceInfo.Length;
        var copiedBytes = 0L;
        var buffer = new byte[CopyBufferSize];
        var lastReportedPercent = -1;

        progress.Report(new ImageWriteProgress($"Copying {label}: 0 of {totalBytes:N0} bytes.", startPercent));

        await using var sourceStream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, CopyBufferSize, useAsync: true);
        await using var destinationStream = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, CopyBufferSize, useAsync: true);

        int read;
        while ((read = await sourceStream.ReadAsync(buffer, cancellationToken)) > 0)
        {
            await destinationStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            copiedBytes += read;

            var filePercent = totalBytes == 0
                ? 100d
                : copiedBytes * 100d / totalBytes;
            var overallPercent = startPercent + ((endPercent - startPercent) * filePercent / 100d);
            var roundedOverallPercent = (int)Math.Floor(overallPercent);

            if (roundedOverallPercent != lastReportedPercent || copiedBytes == totalBytes)
            {
                lastReportedPercent = roundedOverallPercent;
                progress.Report(new ImageWriteProgress(
                    $"Copying {label}: {copiedBytes:N0} of {totalBytes:N0} bytes.",
                    overallPercent));
            }
        }

        await destinationStream.FlushAsync(cancellationToken);
    }

    private static async Task CopySmallFileAsync(
        string source,
        string destination,
        CancellationToken cancellationToken)
    {
        await using var sourceStream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, CopyBufferSize, useAsync: true);
        await using var destinationStream = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, CopyBufferSize, useAsync: true);
        await sourceStream.CopyToAsync(destinationStream, cancellationToken);
        await destinationStream.FlushAsync(cancellationToken);
    }
}

public sealed class UsbCacheVolumeLocator
{
    public async Task<string> WaitForCacheRootAsync(
        IProgress<ImageWriteProgress> progress,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        progress.Report(new ImageWriteProgress("Waiting for the USB to be ready.", 0));

        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var matches = FindVolumesByLabel("HAOS-CACHE").ToArray();

            if (matches.Length == 1)
            {
                var volume = matches[0];
                if (!string.IsNullOrWhiteSpace(volume.DriveLetter))
                {
                    progress.Report(new ImageWriteProgress("Preparing the USB for copying.", 70));
                    RemoveDriveLetter(volume.DriveLetter, progress);
                    await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
                }

                var root = EnsureTrailingSlash(volume.DeviceId);
                progress.Report(new ImageWriteProgress("USB is ready for Home Assistant OS.", 100));
                return root;
            }

            if (matches.Length > 1)
            {
                throw new InvalidOperationException("More than one HAOS-CACHE volume is mounted. Remove extra installer USBs and retry.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(500), cancellationToken);
        }

        throw new TimeoutException("Timed out waiting for the HAOS-CACHE partition.");
    }

    private static IEnumerable<VolumeMountInfo> FindVolumesByLabel(string label)
    {
        if (!OperatingSystem.IsWindows())
        {
            return [];
        }

        var escapedLabel = label.Replace("'", "''", StringComparison.Ordinal);
        using var searcher = new ManagementObjectSearcher(
            $"SELECT DeviceID, DriveLetter, Label FROM Win32_Volume WHERE Label = '{escapedLabel}'");

        return searcher
            .Get()
            .Cast<ManagementObject>()
            .Select(volume => new VolumeMountInfo(
#pragma warning disable CA1416
                Convert.ToString(volume["DeviceID"]) ?? string.Empty,
                Convert.ToString(volume["DriveLetter"]),
                Convert.ToString(volume["Label"]) ?? string.Empty))
#pragma warning restore CA1416
            .Where(volume => !string.IsNullOrWhiteSpace(volume.DeviceId))
            .ToArray();
    }

    private static void RemoveDriveLetter(string driveLetter, IProgress<ImageWriteProgress> progress)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var letter = driveLetter.Trim().TrimEnd('\\');
        if (letter.Length != 2 || letter[1] != ':')
        {
            return;
        }

        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "mountvol.exe",
            Arguments = $"{letter} /D",
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });

        if (process is null)
        {
            progress.Report(new ImageWriteProgress("Could not finish preparing the USB: mountvol.exe did not start."));
            return;
        }

        process.WaitForExit();
        if (process.ExitCode == 0)
        {
            progress.Report(new ImageWriteProgress("USB prepared for copying."));
            return;
        }

        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        progress.Report(new ImageWriteProgress($"Could not finish preparing the USB: {output} {error}".Trim()));
    }

    private static string EnsureTrailingSlash(string volumeDeviceId) =>
        volumeDeviceId.EndsWith('\\') ? volumeDeviceId : volumeDeviceId + "\\";

    private sealed record VolumeMountInfo(string DeviceId, string? DriveLetter, string Label);
}

[SupportedOSPlatform("windows")]
public sealed class UsbAutomountGuard : IDisposable
{
    private readonly IProgress<ImageWriteProgress> _progress;
    private bool _restoreNeeded;
    private bool _disposed;

    private UsbAutomountGuard(IProgress<ImageWriteProgress> progress)
    {
        _progress = progress;
    }

    public static UsbAutomountGuard DisableNewVolumeAutomount(IProgress<ImageWriteProgress> progress)
    {
        var guard = new UsbAutomountGuard(progress);

        if (!OperatingSystem.IsWindows())
        {
            return guard;
        }

        RunMountvol("/N", "disable automatic drive letters for new USB partitions", progress);
        guard._restoreNeeded = true;
        progress.Report(new ImageWriteProgress("Windows automatic drive letters paused while the installer USB is written."));
        return guard;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (!_restoreNeeded || !OperatingSystem.IsWindows())
        {
            return;
        }

        try
        {
            RunMountvol("/E", "restore automatic drive letters", _progress);
            _progress.Report(new ImageWriteProgress("Windows automatic drive letters restored."));
        }
        catch (Exception ex)
        {
            _progress.Report(new ImageWriteProgress($"Could not restore Windows automatic drive letters: {ex.Message}"));
        }
    }

    private static void RunMountvol(string arguments, string action, IProgress<ImageWriteProgress> progress)
    {
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "mountvol.exe",
            Arguments = arguments,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        }) ?? throw new InvalidOperationException($"Could not start mountvol.exe to {action}.");

        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Could not {action}: {output} {error}".Trim());
        }
    }
}

[SupportedOSPlatform("windows")]
public sealed class UsbDriveLetterHider
{
    private static readonly string[] HaosVolumeLabels = ["HAOSINSTLR", "HAOS-INSTLR", "HAOS-BOOT", "HAOS-CACHE"];

    public void HideHaosVolumes(IProgress<ImageWriteProgress> progress)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        HideVolumesByLabel(progress);
        foreach (var drive in DriveInfo.GetDrives())
        {
            if (!TryIsHaosInstallerVolume(drive, out var label))
            {
                continue;
            }

            progress.Report(new ImageWriteProgress($"Detected {label} at {drive.RootDirectory.FullName}; hiding drive letter."));
            RemoveDriveLetter(drive.RootDirectory.FullName, progress);
        }
    }

    private static void HideVolumesByLabel(IProgress<ImageWriteProgress> progress)
    {
        foreach (var label in HaosVolumeLabels)
        {
            var escapedLabel = label.Replace("'", "''", StringComparison.Ordinal);
            using var searcher = new ManagementObjectSearcher(
                $"SELECT DeviceID, DriveLetter, Label FROM Win32_Volume WHERE Label = '{escapedLabel}'");

            foreach (ManagementObject volume in searcher.Get().Cast<ManagementObject>())
            {
                var driveLetter = Convert.ToString(volume["DriveLetter"]);
                if (string.IsNullOrWhiteSpace(driveLetter))
                {
                    continue;
                }

                progress.Report(new ImageWriteProgress($"Detected {label} at {driveLetter}; hiding drive letter."));
                RemoveDriveLetter(driveLetter, progress);
            }
        }
    }

    private static bool TryIsHaosInstallerVolume(DriveInfo drive, out string label)
    {
        label = string.Empty;
        try
        {
            if (!drive.IsReady)
            {
                return false;
            }

            label = drive.VolumeLabel;
            return HaosVolumeLabels.Contains(label, StringComparer.OrdinalIgnoreCase);
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void RemoveDriveLetter(string root, IProgress<ImageWriteProgress> progress)
    {
        var letter = root.TrimEnd('\\');
        if (letter.Length != 2 || letter[1] != ':')
        {
            return;
        }

        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "mountvol.exe",
            Arguments = $"{letter} /D",
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });

        if (process is null)
        {
            return;
        }

        process.WaitForExit();
        if (process.ExitCode == 0)
        {
            progress.Report(new ImageWriteProgress($"Drive letter {letter} removed."));
        }
    }
}

public sealed record UsbCacheProvisionResult(
    string CacheDirectory,
    string ImagePath,
    string ChecksumPath,
    string ManifestPath);

public sealed record InstallerConfig(
    int SchemaVersion,
    UnattendedInstallConfig Unattended);

public sealed record UnattendedInstallConfig(
    bool Enabled,
    string Mode,
    bool RunOnce);

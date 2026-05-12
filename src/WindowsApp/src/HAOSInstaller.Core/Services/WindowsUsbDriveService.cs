using System.Runtime.Versioning;
using System.Management;
using System.Diagnostics;
using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

[SupportedOSPlatform("windows")]
public sealed class WindowsUsbDriveService : IUsbDriveService
{
    public Task<IReadOnlyList<UsbDriveInfo>> GetRemovableDrivesAsync(CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows())
        {
            return Task.FromResult<IReadOnlyList<UsbDriveInfo>>([]);
        }

        return Task.Run<IReadOnlyList<UsbDriveInfo>>(() =>
        {
            var systemDrive = Path.GetPathRoot(Environment.SystemDirectory)?.TrimEnd('\\');
            var drives = new List<UsbDriveInfo>();

            try
            {
                using var searcher = new ManagementObjectSearcher(
                    "SELECT Index,Model,Size,InterfaceType,MediaType,DeviceID,PNPDeviceID FROM Win32_DiskDrive");

                foreach (ManagementObject disk in searcher.Get().Cast<ManagementObject>())
                {
                    cancellationToken.ThrowIfCancellationRequested();

                    var index = Convert.ToUInt32(disk["Index"]);
                    var interfaceType = Convert.ToString(disk["InterfaceType"]) ?? string.Empty;
                    var mediaType = Convert.ToString(disk["MediaType"]) ?? string.Empty;
                    var pnpDeviceId = Convert.ToString(disk["PNPDeviceID"]) ?? string.Empty;
                    var isRemovable =
                        interfaceType.Equals("USB", StringComparison.OrdinalIgnoreCase) ||
                        mediaType.Contains("removable", StringComparison.OrdinalIgnoreCase) ||
                        mediaType.Contains("external hard", StringComparison.OrdinalIgnoreCase) ||
                        pnpDeviceId.StartsWith("USBSTOR", StringComparison.OrdinalIgnoreCase);

                    if (!isRemovable)
                    {
                        continue;
                    }

                    var diskVolumes = GetVolumesForDisk(index, cancellationToken);
                    var driveLetters = diskVolumes
                        .Select(volume => volume.DriveLetter)
                        .Where(letter => !string.IsNullOrWhiteSpace(letter))
                        .Cast<string>()
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .Order()
                        .ToArray();
                    var isSystemDisk = driveLetters.Any(letter => string.Equals(letter.TrimEnd('\\'), systemDrive, StringComparison.OrdinalIgnoreCase));
                    var isHaosInstaller = diskVolumes.Any(volume => IsHaosInstallerLabel(volume.Label)) ||
                        HasHaosInstallerVolumes(index);
                    var model = Convert.ToString(disk["Model"]);
                    var devicePath = $@"\\.\PhysicalDrive{index}";
                    var size = ToUInt64(disk["Size"]);
                    var displayName = BuildDisplayName(model, driveLetters, size, devicePath);

                    drives.Add(new UsbDriveInfo(
                        displayName,
                        model,
                        string.Join(", ", driveLetters.Select(letter => letter.TrimEnd('\\'))),
                        devicePath,
                        size,
                        IsRemovable: true,
                        isSystemDisk,
                        interfaceType,
                        HasWindowsPartitions(index),
                        isHaosInstaller));
                }
            }
            catch (ManagementException)
            {
                return Array.Empty<UsbDriveInfo>();
            }

            return drives
                .OrderBy(drive => drive.DriveLetter)
                .ThenBy(drive => drive.DisplayName)
                .ToArray();
        }, cancellationToken);
    }

    private static IReadOnlyList<DiskVolumeInfo> GetVolumesForDisk(uint diskIndex, CancellationToken cancellationToken)
    {
        var volumes = new List<DiskVolumeInfo>();
        var escapedDeviceId = $@"\\.\PHYSICALDRIVE{diskIndex}".Replace(@"\", @"\\");

        using var partitionSearcher = new ManagementObjectSearcher(
            $"ASSOCIATORS OF {{Win32_DiskDrive.DeviceID=\"{escapedDeviceId}\"}} WHERE AssocClass = Win32_DiskDriveToDiskPartition");

        foreach (ManagementObject partition in partitionSearcher.Get().Cast<ManagementObject>())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var partitionDeviceId = Convert.ToString(partition["DeviceID"])?.Replace(@"\", @"\\").Replace("\"", "\\\"");
            if (string.IsNullOrWhiteSpace(partitionDeviceId))
            {
                continue;
            }

            using var logicalSearcher = new ManagementObjectSearcher(
                $"ASSOCIATORS OF {{Win32_DiskPartition.DeviceID=\"{partitionDeviceId}\"}} WHERE AssocClass = Win32_LogicalDiskToPartition");

            foreach (ManagementObject logicalDisk in logicalSearcher.Get().Cast<ManagementObject>())
            {
                var name = Convert.ToString(logicalDisk["Name"]);
                if (!string.IsNullOrWhiteSpace(name))
                {
                    volumes.Add(new DiskVolumeInfo(name, GetVolumeLabel(name)));
                }
            }
        }

        return volumes
            .DistinctBy(volume => volume.DriveLetter, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string? GetVolumeLabel(string driveLetter)
    {
        try
        {
            var escapedDriveLetter = driveLetter.Replace("'", "''", StringComparison.Ordinal);
            using var searcher = new ManagementObjectSearcher(
                $"SELECT VolumeName FROM Win32_LogicalDisk WHERE DeviceID='{escapedDriveLetter}'");

            return searcher
                .Get()
                .Cast<ManagementObject>()
                .Select(volume => Convert.ToString(volume["VolumeName"]))
                .FirstOrDefault(label => !string.IsNullOrWhiteSpace(label));
        }
        catch (ManagementException)
        {
            return null;
        }
    }

    private static bool HasHaosInstallerVolumes(uint diskIndex)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -Command \"Get-Partition -DiskNumber {diskIndex} -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FileSystemLabel\"",
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            });

            if (process is null)
            {
                return false;
            }

            if (!process.WaitForExit(3000))
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch
                {
                    // Best-effort cleanup only.
                }

                return false;
            }

            var output = process.StandardOutput.ReadToEnd();
            return output
                .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Any(IsHaosInstallerLabel);
        }
        catch
        {
            return false;
        }
    }

    private static bool HasWindowsPartitions(uint diskIndex)
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                $"SELECT Name, Type FROM Win32_DiskPartition WHERE DiskIndex={diskIndex}");

            foreach (ManagementObject partition in searcher.Get().Cast<ManagementObject>())
            {
                var partitionType = Convert.ToString(partition["Type"]) ?? string.Empty;
                if (partitionType.Contains("GPT: System", StringComparison.OrdinalIgnoreCase) ||
                    partitionType.Contains("GPT: Microsoft", StringComparison.OrdinalIgnoreCase) ||
                    partitionType.Contains("Installable File", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }
        catch (ManagementException)
        {
            return false;
        }

        return false;
    }

    private static bool IsHaosInstallerLabel(string? label) =>
        string.Equals(label, "HAOSINSTLR", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(label, "HAOS-INSTLR", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(label, "HAOS-BOOT", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(label, "HAOS-CACHE", StringComparison.OrdinalIgnoreCase);

    private static ulong ToUInt64(object? value)
    {
        return value is null ? 0 : Convert.ToUInt64(value);
    }

    private static string BuildDisplayName(string? model, IReadOnlyList<string> driveLetters, ulong size, string devicePath)
    {
        var letterText = driveLetters.Count == 0 ? "no drive letter" : string.Join(", ", driveLetters.Select(letter => letter.TrimEnd('\\')));
        return $"{model ?? "USB drive"} ({letterText}, {FormatBytes(size)}, {devicePath})";
    }

    private static string FormatBytes(ulong bytes)
    {
        const double gib = 1024d * 1024d * 1024d;
        return bytes == 0 ? "unknown size" : $"{bytes / gib:0.##} GiB";
    }

    private sealed record DiskVolumeInfo(string? DriveLetter, string? Label);
}

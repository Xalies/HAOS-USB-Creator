namespace HAOSInstaller.Core.Models;

public sealed record UsbDriveInfo(
    string DisplayName,
    string? Model,
    string? DriveLetter,
    string DevicePath,
    ulong SizeBytes,
    bool IsRemovable,
    bool IsSystemDisk,
    string? InterfaceType = null,
    bool HasWindowsPartitions = false,
    bool IsHaosInstaller = false)
{
    public string SizeDisplay => FormatBytes(SizeBytes);

    public bool IsLargeDrive => SizeBytes > 128_000_000_000UL;

    public bool ShowWindowsLayoutWarning => HasWindowsPartitions && !IsHaosInstaller;

    private static string FormatBytes(ulong bytes)
    {
        const double gib = 1024d * 1024d * 1024d;
        return bytes == 0 ? "Unknown size" : $"{bytes / gib:0.##} GiB";
    }
}

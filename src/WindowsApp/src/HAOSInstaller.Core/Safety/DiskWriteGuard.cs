using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Safety;

public sealed class DiskWriteGuard
{
    public const ulong DefaultMaximumUsbTargetBytes = 128UL * 1024 * 1024 * 1024;

    public DiskWriteApproval Evaluate(UsbDriveInfo drive, DiskWriteMode mode, bool destructiveWriteConfirmed)
    {
        if (mode == DiskWriteMode.DryRun)
        {
            return DiskWriteApproval.Approved("Dry-run mode; no destructive write will occur.");
        }

        if (mode == DiskWriteMode.DeveloperFileTarget)
        {
            return destructiveWriteConfirmed
                ? DiskWriteApproval.Approved("Developer file target approved.")
                : DiskWriteApproval.Rejected("Developer write requires explicit confirmation.");
        }

        if (!destructiveWriteConfirmed)
        {
            return DiskWriteApproval.Rejected("Physical USB write requires explicit confirmation.");
        }

        if (!drive.IsRemovable)
        {
            return DiskWriteApproval.Rejected("Refusing to write because the selected device is not removable.");
        }

        if (drive.IsSystemDisk)
        {
            return DiskWriteApproval.Rejected("Refusing to write because the selected device appears to be a system disk.");
        }

        if (string.IsNullOrWhiteSpace(drive.DevicePath))
        {
            return DiskWriteApproval.Rejected("Refusing to write because the selected device path is missing.");
        }

        if (!drive.DevicePath.StartsWith(@"\\.\PhysicalDrive", StringComparison.OrdinalIgnoreCase))
        {
            return DiskWriteApproval.Rejected("Refusing to write because the selected device path is not a raw physical drive path.");
        }

        if (drive.SizeBytes == 0)
        {
            return DiskWriteApproval.Rejected("Refusing to write because the selected USB size could not be detected.");
        }

        if (drive.SizeBytes > DefaultMaximumUsbTargetBytes)
        {
            return DiskWriteApproval.Rejected("Refusing to write because the selected USB is larger than the MVP safety limit.");
        }

        return DiskWriteApproval.Approved("Physical USB target passed MVP safety checks.");
    }
}

public sealed record DiskWriteApproval(bool IsApproved, string Reason)
{
    public static DiskWriteApproval Approved(string reason) => new(true, reason);

    public static DiskWriteApproval Rejected(string reason) => new(false, reason);
}

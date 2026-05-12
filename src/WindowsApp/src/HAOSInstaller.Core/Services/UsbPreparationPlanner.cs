using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public sealed class UsbPreparationPlanner
{
    public UsbPreparationPlan CreatePlan(
        UsbDriveInfo target,
        HaosInstallerBootImage bootImage,
        HaosPayloadStageResult? stagedPayload,
        string cacheDestinationRoot,
        bool isDeveloperTarget)
    {
        if (string.IsNullOrWhiteSpace(target.DevicePath))
        {
            throw new InvalidOperationException("USB target device path is required.");
        }

        if (!File.Exists(bootImage.ImagePath))
        {
            throw new FileNotFoundException("HAOS Installer boot image was not found.", bootImage.ImagePath);
        }

        if (stagedPayload is not null)
        {
            RequireFile(stagedPayload.ImagePath, "Staged HAOS payload image was not found.");
            RequireFile(stagedPayload.ChecksumPath, "Staged HAOS payload checksum was not found.");
            RequireFile(stagedPayload.ManifestPath, "Staged HAOS payload manifest was not found.");
        }

        if (string.IsNullOrWhiteSpace(cacheDestinationRoot))
        {
            throw new InvalidOperationException("USB cache destination is required.");
        }

        return new UsbPreparationPlan(
            target,
            bootImage,
            stagedPayload,
            cacheDestinationRoot,
            isDeveloperTarget);
    }

    public static string BuildSummary(UsbPreparationPlan plan)
    {
        var payloadSummary = plan.StagedPayload is null
            ? "HAOS payload: not cached yet. The installer USB will still boot and can check online later."
            : $"HAOS payload: cached and ready to copy to the USB.";

        return
            $"Target: {plan.Target.DevicePath}{Environment.NewLine}" +
            $"Model: {plan.Target.Model ?? "USB drive"}{Environment.NewLine}" +
            $"Size: {FormatBytes(plan.Target.SizeBytes)}{Environment.NewLine}" +
            $"Drive letter: {plan.Target.DriveLetter ?? "none"}{Environment.NewLine}{Environment.NewLine}" +
            payloadSummary;
    }

    private static void RequireFile(string path, string message)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(message, path);
        }
    }

    private static string FormatBytes(ulong bytes)
    {
        const double gib = 1024d * 1024d * 1024d;
        return bytes == 0 ? "Unknown size" : $"{bytes / gib:0.##} GiB";
    }
}

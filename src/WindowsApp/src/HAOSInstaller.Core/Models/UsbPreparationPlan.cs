namespace HAOSInstaller.Core.Models;

public sealed record UsbPreparationPlan(
    UsbDriveInfo Target,
    HaosInstallerBootImage BootImage,
    HaosPayloadStageResult? StagedPayload,
    string CacheDestinationRoot,
    bool IsDeveloperTarget)
{
    public bool HasPayloadCache => StagedPayload is not null;
}

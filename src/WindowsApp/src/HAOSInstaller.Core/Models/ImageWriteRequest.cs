using HAOSInstaller.Core.Safety;

namespace HAOSInstaller.Core.Models;

public sealed record ImageWriteRequest(
    UsbDriveInfo Target,
    string SourceImagePath,
    DiskWriteMode Mode,
    bool DestructiveWriteConfirmed,
    string? DeveloperOutputPath = null);

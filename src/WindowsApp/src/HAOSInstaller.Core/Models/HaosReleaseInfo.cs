namespace HAOSInstaller.Core.Models;

public sealed record HaosReleaseInfo(
    string Version,
    string Filename,
    Uri DownloadUrl,
    string? Sha256,
    long FileSizeBytes,
    DateTimeOffset PublishedAtUtc);

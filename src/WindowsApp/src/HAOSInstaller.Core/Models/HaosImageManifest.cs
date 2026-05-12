namespace HAOSInstaller.Core.Models;

public sealed record HaosImageManifest
{
    public int SchemaVersion { get; init; } = 1;
    public string ImageType { get; init; } = "haos_generic-x86-64";
    public required string Version { get; init; }
    public required string Filename { get; init; }
    public required string Sha256 { get; init; }
    public required string SourceUrl { get; init; }
    public required DateTimeOffset DownloadedAtUtc { get; init; }
    public string CreatedBy { get; init; } = "HAOS Installer";
    public long FileSizeBytes { get; init; }
}

namespace HAOSInstaller.Core.Models;

public sealed record HaosInstallerBootImage(
    string ImagePath,
    string? ChecksumPath,
    string? ManifestPath,
    string? Sha256,
    long SizeBytes,
    bool ChecksumVerified,
    string Format);

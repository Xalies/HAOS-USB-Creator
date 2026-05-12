namespace HAOSInstaller.Core.Models;

public sealed record HaosPayloadStageResult(
    string CacheDirectory,
    string ImagePath,
    string ChecksumPath,
    string ManifestPath);

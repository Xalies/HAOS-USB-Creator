namespace HAOSInstaller.Core.Models;

public sealed record HaosInstallerBootImageManifest(
    int SchemaVersion,
    string ArtifactType,
    string Format,
    string Filename,
    string? Sha256,
    long? FileSizeBytes,
    DateTimeOffset? BuiltAtUtc,
    string? Builder);

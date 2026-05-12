using System.Security.Cryptography;

namespace HAOSInstaller.Core.Services;

public sealed class Sha256Verifier
{
    public async Task<string> ComputeFileHashAsync(string path, IProgress<ImageWriteProgress>? progress, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, useAsync: true);
        using var sha256 = SHA256.Create();

        var buffer = new byte[1024 * 1024];
        long readTotal = 0;
        var length = stream.Length;
        int read;

        while ((read = await stream.ReadAsync(buffer, cancellationToken)) > 0)
        {
            sha256.TransformBlock(buffer, 0, read, null, 0);
            readTotal += read;

            if (progress is not null && length > 0)
            {
                progress.Report(new ImageWriteProgress($"Verifying image hash: {readTotal:N0} of {length:N0} bytes.", readTotal * 100d / length));
            }
        }

        sha256.TransformFinalBlock([], 0, 0);
        return Convert.ToHexString(sha256.Hash!).ToLowerInvariant();
    }

    public async Task VerifyFileHashAsync(string path, string expectedSha256, IProgress<ImageWriteProgress>? progress, CancellationToken cancellationToken)
    {
        var actual = await ComputeFileHashAsync(path, progress, cancellationToken);
        if (!string.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"SHA-256 verification failed. Expected {expectedSha256}, got {actual}.");
        }
    }
}

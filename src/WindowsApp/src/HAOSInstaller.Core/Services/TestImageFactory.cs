namespace HAOSInstaller.Core.Services;

public sealed class TestImageFactory
{
    public async Task<string> CreateAsync(string directory, IProgress<ImageWriteProgress> progress, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "haos-installer-test-image.bin");

        progress.Report(new ImageWriteProgress($"Creating dummy test image: {path}", 0));

        var buffer = new byte[1024 * 1024];
        await using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, buffer.Length, useAsync: true);

        for (var i = 0; i < 16; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            FillDeterministicPattern(buffer, i);
            await stream.WriteAsync(buffer, cancellationToken);
            progress.Report(new ImageWriteProgress($"Created {(i + 1):N0} MiB of 16 MiB.", (i + 1) * 100d / 16));
        }

        await stream.FlushAsync(cancellationToken);
        progress.Report(new ImageWriteProgress("Dummy test image ready.", 100));
        return path;
    }

    private static void FillDeterministicPattern(byte[] buffer, int blockIndex)
    {
        for (var i = 0; i < buffer.Length; i++)
        {
            buffer[i] = unchecked((byte)(blockIndex + i));
        }
    }
}

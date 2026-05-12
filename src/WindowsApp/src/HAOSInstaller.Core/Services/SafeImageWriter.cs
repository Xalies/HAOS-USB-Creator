using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Safety;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace HAOSInstaller.Core.Services;

public sealed class SafeImageWriter(DiskWriteGuard guard) : IImageWriter
{
    private const int BufferSize = 4 * 1024 * 1024;

    public async Task WriteAsync(
        ImageWriteRequest request,
        IProgress<ImageWriteProgress> progress,
        CancellationToken cancellationToken)
    {
        var approval = guard.Evaluate(request.Target, request.Mode, request.DestructiveWriteConfirmed);
        progress.Report(new ImageWriteProgress(approval.Reason));

        if (!approval.IsApproved)
        {
            throw new InvalidOperationException(approval.Reason);
        }

        switch (request.Mode)
        {
            case DiskWriteMode.DryRun:
                progress.Report(new ImageWriteProgress(
                    $"DRY RUN: would write '{request.SourceImagePath}' to '{request.Target.DevicePath}'.",
                    100));
                return;

            case DiskWriteMode.DeveloperFileTarget:
                await CopyToDeveloperFileTargetAsync(request, progress, cancellationToken);
                return;

            case DiskWriteMode.PhysicalUsb:
                await Task.Run(
                    () => WriteToPhysicalUsbAsync(request, progress, cancellationToken),
                    cancellationToken);
                return;

            default:
                throw new ArgumentOutOfRangeException(nameof(request), "Unknown disk write mode.");
        }
    }

    private static async Task WriteToPhysicalUsbAsync(
        ImageWriteRequest request,
        IProgress<ImageWriteProgress> progress,
        CancellationToken cancellationToken)
    {
        if (!IsRunningAsAdministrator())
        {
            throw new InvalidOperationException("Administrator privileges are required to write a bootable USB.");
        }

        if (!File.Exists(request.SourceImagePath))
        {
            throw new FileNotFoundException("Boot image was not found.", request.SourceImagePath);
        }

        var sourceInfo = new FileInfo(request.SourceImagePath);
        if ((ulong)sourceInfo.Length > request.Target.SizeBytes)
        {
            throw new InvalidOperationException("Boot image is larger than the selected USB drive.");
        }

        progress.Report(new ImageWriteProgress($"Preparing physical USB target: {request.Target.DevicePath}", 0));
        var lockedVolumes = LockAndDismountDriveLetters(request.Target.DriveLetter, progress);

        progress.Report(new ImageWriteProgress($"Writing boot image to {request.Target.DevicePath}. Do not remove the USB.", 0));

        try
        {
            CleanDiskPartitionTable(request.Target.DevicePath, progress);

            await using var source = new FileStream(
                request.SourceImagePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                BufferSize,
                useAsync: true);

            using var targetHandle = OpenPhysicalDriveForWrite(request.Target.DevicePath, progress);
            TryDeviceIoControl(targetHandle, NativeMethods.FsctlLockVolume, "lock physical drive", progress);
            TryDeviceIoControl(
                targetHandle,
                NativeMethods.FsctlAllowExtendedDasdIo,
                "disable I/O boundary checks",
                progress,
                reportFailure: false);

            var buffer = new byte[BufferSize];
            long copied = 0;
            int read;

            while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
            {
                WriteAll(targetHandle, buffer, read, request.Target.DevicePath);
                copied += read;
                var percent = sourceInfo.Length == 0 ? 100 : copied * 100d / sourceInfo.Length;
                progress.Report(new ImageWriteProgress($"Wrote {copied:N0} of {sourceInfo.Length:N0} bytes.", percent));
            }

            if (!NativeMethods.FlushFileBuffers(targetHandle))
            {
                progress.Report(new ImageWriteProgress($"Could not flush {request.Target.DevicePath}: {new Win32Exception(Marshal.GetLastWin32Error()).Message}"));
            }

            TryDeviceIoControl(targetHandle, NativeMethods.IoctlDiskUpdateProperties, "refresh disk layout", progress);
            progress.Report(new ImageWriteProgress("Boot environment written to the USB.", 100));
        }
        finally
        {
            foreach (var volume in lockedVolumes)
            {
                volume.Dispose();
            }
        }
    }

    private static async Task CopyToDeveloperFileTargetAsync(
        ImageWriteRequest request,
        IProgress<ImageWriteProgress> progress,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.DeveloperOutputPath))
        {
            throw new InvalidOperationException("Developer output path is required for file target mode.");
        }

        if (!File.Exists(request.SourceImagePath))
        {
            throw new FileNotFoundException("Source test image was not found.", request.SourceImagePath);
        }

        var outputDirectory = Path.GetDirectoryName(Path.GetFullPath(request.DeveloperOutputPath));
        if (!string.IsNullOrWhiteSpace(outputDirectory))
        {
            Directory.CreateDirectory(outputDirectory);
        }

        var sourceInfo = new FileInfo(request.SourceImagePath);
        progress.Report(new ImageWriteProgress($"Writing test image to developer file target: {request.DeveloperOutputPath}", 0));

        await using var source = new FileStream(
            request.SourceImagePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            BufferSize,
            useAsync: true);

        await using var destination = new FileStream(
            request.DeveloperOutputPath,
            FileMode.Create,
            FileAccess.Write,
            FileShare.None,
            BufferSize,
            useAsync: true);

        var buffer = new byte[BufferSize];
        long copied = 0;
        int read;

        while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
        {
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            copied += read;
            var percent = sourceInfo.Length == 0 ? 100 : copied * 100d / sourceInfo.Length;
            progress.Report(new ImageWriteProgress($"Copied {copied:N0} of {sourceInfo.Length:N0} bytes.", percent));
        }

        await destination.FlushAsync(cancellationToken);
        progress.Report(new ImageWriteProgress("Developer file target write complete.", 100));
    }

    private static List<SafeFileHandle> LockAndDismountDriveLetters(string? driveLetters, IProgress<ImageWriteProgress> progress)
    {
        var lockedVolumes = new List<SafeFileHandle>();
        if (string.IsNullOrWhiteSpace(driveLetters))
        {
            return lockedVolumes;
        }

        foreach (var driveLetter in driveLetters.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var letter = driveLetter.Trim().TrimEnd(':', '\\');
            if (letter.Length != 1 || !char.IsLetter(letter[0]))
            {
                continue;
            }

            var volumePath = $@"\\.\{letter}:";
            progress.Report(new ImageWriteProgress($"Locking volume {letter}:"));
            var volumeHandle = NativeMethods.CreateFile(
                volumePath,
                NativeMethods.GenericRead | NativeMethods.GenericWrite,
                NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
                IntPtr.Zero,
                NativeMethods.OpenExisting,
                NativeMethods.FileAttributeNormal,
                IntPtr.Zero);

            if (volumeHandle.IsInvalid)
            {
                progress.Report(new ImageWriteProgress($"Could not open volume {letter}: {new Win32Exception(Marshal.GetLastWin32Error()).Message}"));
                volumeHandle.Dispose();
                continue;
            }

            if (!TryDeviceIoControl(volumeHandle, NativeMethods.FsctlLockVolume, $"lock volume {letter}:", progress))
            {
                volumeHandle.Dispose();
                continue;
            }

            TryDeviceIoControl(volumeHandle, NativeMethods.FsctlDismountVolume, $"dismount volume {letter}:", progress);
            lockedVolumes.Add(volumeHandle);
        }

        return lockedVolumes;
    }

    private static SafeFileHandle OpenPhysicalDriveForWrite(string devicePath, IProgress<ImageWriteProgress> progress)
    {
        const int attempts = 30;
        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            var handle = NativeMethods.CreateFile(
                devicePath,
                NativeMethods.GenericRead | NativeMethods.GenericWrite,
                NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
                IntPtr.Zero,
                NativeMethods.OpenExisting,
                NativeMethods.FileAttributeNormal | NativeMethods.FileFlagWriteThrough,
                IntPtr.Zero);

            if (!handle.IsInvalid)
            {
                progress.Report(new ImageWriteProgress($"Opened {devicePath} for raw write access."));
                return handle;
            }

            var error = Marshal.GetLastWin32Error();
            handle.Dispose();

            if (error != NativeMethods.ErrorAccessDenied && error != NativeMethods.ErrorSharingViolation)
            {
                throw new IOException($"Could not open {devicePath}: {new Win32Exception(error).Message}", error);
            }

            if (attempt == 1)
            {
                progress.Report(new ImageWriteProgress($"Waiting for raw disk access to {devicePath}."));
            }

            Thread.Sleep(500);
        }

        throw new UnauthorizedAccessException($"Could not open {devicePath} for raw write access after waiting. Close File Explorer, Disk Management, antivirus scanners, or other tools using the USB.");
    }

    private static void CleanDiskPartitionTable(string devicePath, IProgress<ImageWriteProgress> progress)
    {
        var diskNumber = GetDiskNumberFromDevicePath(devicePath);
        if (diskNumber is null)
        {
            progress.Report(new ImageWriteProgress($"Skipping partition cleanup because the disk number could not be parsed from {devicePath}."));
            return;
        }

        var scriptPath = Path.Combine(Path.GetTempPath(), $"haos-installer-diskpart-{Guid.NewGuid():N}.txt");
        File.WriteAllText(
            scriptPath,
            string.Join(
                Environment.NewLine,
                $"select disk {diskNumber.Value}",
                "attributes disk clear readonly",
                "online disk noerr",
                "clean",
                "rescan",
                string.Empty));

        try
        {
            progress.Report(new ImageWriteProgress($"Clearing existing partition table on Disk {diskNumber.Value}."));
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "diskpart.exe",
                Arguments = $"/s \"{scriptPath}\"",
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            }) ?? throw new InvalidOperationException("Could not start diskpart.exe.");

            var output = process.StandardOutput.ReadToEnd();
            var error = process.StandardError.ReadToEnd();
            process.WaitForExit();

            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException($"diskpart clean failed for Disk {diskNumber.Value}: {output} {error}".Trim());
            }

            progress.Report(new ImageWriteProgress($"Disk {diskNumber.Value} partition table cleared."));
            Thread.Sleep(1500);
        }
        finally
        {
            try
            {
                File.Delete(scriptPath);
            }
            catch
            {
                // Best-effort cleanup only.
            }
        }
    }

    private static int? GetDiskNumberFromDevicePath(string devicePath)
    {
        const string prefix = @"\\.\PhysicalDrive";
        if (!devicePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return int.TryParse(devicePath[prefix.Length..], out var diskNumber)
            ? diskNumber
            : null;
    }

    private static bool TryDeviceIoControl(
        SafeFileHandle handle,
        uint controlCode,
        string action,
        IProgress<ImageWriteProgress> progress,
        bool reportFailure = true)
    {
        var ok = NativeMethods.DeviceIoControl(
            handle,
            controlCode,
            IntPtr.Zero,
            0,
            IntPtr.Zero,
            0,
            out _,
            IntPtr.Zero);

        if (ok)
        {
            return true;
        }

        if (reportFailure)
        {
            progress.Report(new ImageWriteProgress($"Could not {action}: {new Win32Exception(Marshal.GetLastWin32Error()).Message}"));
        }

        return false;
    }

    private static void WriteAll(SafeFileHandle handle, byte[] buffer, int count, string devicePath)
    {
        var offset = 0;
        while (offset < count)
        {
            var bytesToWrite = count - offset;
            if (!NativeMethods.WriteFile(handle, buffer.AsSpan(offset, bytesToWrite).ToArray(), (uint)bytesToWrite, out var written, IntPtr.Zero))
            {
                var error = Marshal.GetLastWin32Error();
                throw new IOException($"Raw write to {devicePath} failed: {new Win32Exception(error).Message}", error);
            }

            if (written == 0)
            {
                throw new IOException($"Raw write to {devicePath} failed: Windows reported 0 bytes written.");
            }

            offset += (int)written;
        }
    }

    private static bool IsRunningAsAdministrator()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static class NativeMethods
    {
        public const uint GenericRead = 0x80000000;
        public const uint GenericWrite = 0x40000000;
        public const uint FileShareRead = 0x00000001;
        public const uint FileShareWrite = 0x00000002;
        public const uint OpenExisting = 3;
        public const uint FileAttributeNormal = 0x00000080;
        public const uint FileFlagWriteThrough = 0x80000000;
        public const int ErrorAccessDenied = 5;
        public const int ErrorSharingViolation = 32;

        public const uint FsctlLockVolume = 0x00090018;
        public const uint FsctlDismountVolume = 0x00090020;
        public const uint FsctlAllowExtendedDasdIo = 0x00090083;
        public const uint IoctlDiskUpdateProperties = 0x00070140;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeviceIoControl(
            SafeFileHandle hDevice,
            uint dwIoControlCode,
            IntPtr lpInBuffer,
            uint nInBufferSize,
            IntPtr lpOutBuffer,
            uint nOutBufferSize,
            out uint lpBytesReturned,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WriteFile(
            SafeFileHandle hFile,
            byte[] lpBuffer,
            uint nNumberOfBytesToWrite,
            out uint lpNumberOfBytesWritten,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FlushFileBuffers(SafeFileHandle hFile);
    }
}

using System.IO;
using System.Net.Http;
using System.Windows;
using System.Diagnostics;
using System.Windows.Controls;
using System.Windows.Media;
using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Safety;
using HAOSInstaller.Core.Services;
using HAOSInstaller.App.Resources;

namespace HAOSInstaller.App;

public partial class MainWindow : Window
{
    private readonly HttpClient _httpClient = new();
    private readonly IUsbDriveService _usbDriveService = new WindowsUsbDriveService();
    private readonly IImageWriter _imageWriter = new SafeImageWriter(new DiskWriteGuard());
    private readonly HaosInstallerBootImageService _bootImageService = new(new Sha256Verifier());
    private readonly IHaosReleaseService _releaseService;
    private readonly HaosImageCacheService _imageCacheService;
    private readonly ManifestWriter _manifestWriter = new();
    private readonly HaosPayloadStagingService _payloadStagingService;
    private readonly UsbCacheProvisioningService _usbCacheProvisioningService = new();
    private readonly UsbCacheVolumeLocator _usbCacheVolumeLocator = new();
    private readonly UsbDriveLetterHider _usbDriveLetterHider = new();
    private HaosReleaseInfo? _latestRelease;
    private HaosInstallerBootImage? _bootImage;
    private HaosPayloadStageResult? _stagedPayload;

    public MainWindow()
    {
        _releaseService = new GitHubHaosReleaseService(_httpClient);
        _imageCacheService = new HaosImageCacheService(_httpClient, new Sha256Verifier());
        _payloadStagingService = new HaosPayloadStagingService(_manifestWriter);

        InitializeComponent();
        Loaded += async (_, _) =>
        {
            GoToStep(InstallerStep.Welcome);
            await Task.CompletedTask;
        };
    }

    private async void GetStarted_Click(object sender, RoutedEventArgs e)
    {
        GoToStep(InstallerStep.Drive);
        await RefreshDrivesAsync();
    }

    private void BackToWelcome_Click(object sender, RoutedEventArgs e) => GoToStep(InstallerStep.Welcome);

    private void BackToDrive_Click(object sender, RoutedEventArgs e) => GoToStep(InstallerStep.Drive);

    private void BackToConfirm_Click(object sender, RoutedEventArgs e) => GoToStep(InstallerStep.Confirm);

    private async void DriveNext_Click(object sender, RoutedEventArgs e)
    {
        await TryAutoFindBootImageAsync();
        if (_bootImage is null)
        {
            AppendLog($"Blocked: {UiText.ErrorBootImageNotFound}");
            return;
        }

        UpdateConfirmDriveDetails();
        GoToStep(InstallerStep.Confirm);
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        await RefreshDrivesAsync();
    }

    private async Task<HaosPayloadStageResult?> PreparePayloadAsync()
    {
        try
        {
            ReportHaosDownloadProgress(new ImageWriteProgress(UiText.ProgressCheckingLatestHaos, 0));
            AppendLog("Preparing the Home Assistant OS image.");

            _latestRelease ??= await _releaseService.GetLatestGenericX86_64Async(CancellationToken.None);
            ReportHaosDownloadProgress(new ImageWriteProgress(string.Format(UiText.ProgressLatestImageFormat, _latestRelease.Filename), 0));

            var progress = new Progress<ImageWriteProgress>(ReportHaosDownloadProgress);
            var cachedImage = await _imageCacheService.DownloadAndVerifyAsync(
                _latestRelease,
                GetHaosCacheDirectory(),
                progress,
                CancellationToken.None);

            _stagedPayload = await _payloadStagingService.StageAsync(
                cachedImage,
                GetUsbStagingDirectory(),
                progress,
                CancellationToken.None);

            ReportHaosDownloadProgress(new ImageWriteProgress(UiText.ProgressHaosReady, 100));
            AppendLog($"Home Assistant OS image prepared: {_stagedPayload.CacheDirectory}");
            return _stagedPayload;
        }
        catch (Exception ex)
        {
            _stagedPayload = null;
            ReportHaosDownloadProgress(new ImageWriteProgress(string.Format(UiText.ProgressSkippedFormat, ex.Message), 0));
            AppendLog("Home Assistant OS image was not added to the USB. The booted installer will check if online.");
            return null;
        }
    }

    private async Task TryAutoFindBootImageAsync(bool force = false)
    {
        if (!force && _bootImage is not null)
        {
            return;
        }

        await RunUiOperationAsync(async () =>
        {
            var bootImage = await _bootImageService.TryFindLatestAsync(
                GetBootImageSearchDirectories(),
                new Progress<ImageWriteProgress>(ReportProgress),
                CancellationToken.None);

            if (bootImage is null)
            {
                if (force)
                {
                    AppendLog("No bundled HAOS AIO boot image found under /installer-linux.");
                }
                return;
            }

            _bootImage = bootImage;
            AppendBootImageStatus(bootImage);
        });
    }

    private void ConfirmEraseCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        UpdateConfirmWriteButtonState();
    }

    private void UnattendedInstallCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (UnattendedWarningCheckBox is not null)
        {
            UnattendedWarningCheckBox.IsEnabled = UnattendedInstallCheckBox.IsChecked == true;
            if (UnattendedInstallCheckBox.IsChecked != true)
            {
                UnattendedWarningCheckBox.IsChecked = false;
            }
        }

        UpdateConfirmWriteButtonState();
    }

    private void UpdateConfirmWriteButtonState()
    {
        var usbEraseConfirmed = ConfirmEraseCheckBox.IsChecked == true;
        var unattendedConfirmed = UnattendedInstallCheckBox.IsChecked != true || UnattendedWarningCheckBox.IsChecked == true;
        ConfirmWriteButton.IsEnabled = usbEraseConfirmed && unattendedConfirmed;
    }

    private async void ConfirmWriteButton_Click(object sender, RoutedEventArgs e)
    {
        var unattendedInstall = UnattendedInstallCheckBox.IsChecked == true;
        GoToStep(InstallerStep.Write);
        PrepareProgressBar.Value = 0;
        BootWriteProgressBar.Value = 0;
        HaosDownloadProgressBar.Value = 0;
        CopyPayloadProgressBar.Value = 0;
        ResetWriteCards();
        await RunUiOperationAsync(async () =>
        {
            using var hideLoopCts = new CancellationTokenSource();
            var hideLoopTask = HideHaosVolumesWhileWritingAsync(hideLoopCts.Token);
            try
            {
                using var automountGuard = UsbAutomountGuard.DisableNewVolumeAutomount(
                    new Progress<ImageWriteProgress>(ReportBootWriteProgress));

                ReportPrepareProgress(new ImageWriteProgress(UiText.ProgressPrepareInstaller, 0));
                await TryAutoFindBootImageAsync();
                if (_bootImage is null)
                {
                    throw new InvalidOperationException(UiText.ErrorBootImageNotFound);
                }
                ReportPrepareProgress(new ImageWriteProgress(UiText.ProgressInstallerReady, 100));

                var request = BuildWriteRequest(validateOnly: false);
                var payloadTask = PreparePayloadAsync();
                var writeTask = _imageWriter.WriteAsync(request, new Progress<ImageWriteProgress>(ReportBootWriteProgress), CancellationToken.None);

                await writeTask;
                _usbDriveLetterHider.HideHaosVolumes(new Progress<ImageWriteProgress>(_ => { }));
                var stagedPayload = await payloadTask;

                if (stagedPayload is not null)
                {
                    var cacheRoot = await _usbCacheVolumeLocator.WaitForCacheRootAsync(
                        new Progress<ImageWriteProgress>(ReportCopyPayloadProgress),
                        TimeSpan.FromSeconds(90),
                        CancellationToken.None);

                    _usbDriveLetterHider.HideHaosVolumes(new Progress<ImageWriteProgress>(_ => { }));
                    await _usbCacheProvisioningService.WriteInstallerConfigAsync(
                        cacheRoot,
                        unattendedInstall,
                        CancellationToken.None);

                    await _usbCacheProvisioningService.ProvisionAsync(
                        stagedPayload,
                        cacheRoot,
                        new Progress<ImageWriteProgress>(ReportCopyPayloadProgress),
                        CancellationToken.None);

                    _usbDriveLetterHider.HideHaosVolumes(new Progress<ImageWriteProgress>(_ => { }));
                }
                else
                {
                    var cacheRoot = await _usbCacheVolumeLocator.WaitForCacheRootAsync(
                        new Progress<ImageWriteProgress>(ReportCopyPayloadProgress),
                        TimeSpan.FromSeconds(90),
                        CancellationToken.None);

                    await _usbCacheProvisioningService.WriteInstallerConfigAsync(
                        cacheRoot,
                        unattendedInstall,
                        CancellationToken.None);

                    ReportCopyPayloadProgress(new ImageWriteProgress(UiText.ProgressCopyUnavailable, 100));
                    AppendLog("No Home Assistant OS image is available on the USB. The booted installer will check if online.");
                }

                ConfigureFinishText(unattendedInstall, stagedPayload is not null);
                GoToStep(InstallerStep.Finish);
            }
            finally
            {
                hideLoopCts.Cancel();
                await hideLoopTask;
            }
        },
        ex =>
        {
            ShowWriteError(ex.Message);
            AppendLog($"Blocked: {ex.Message}");
        });
    }

    private void StartOver_Click(object sender, RoutedEventArgs e)
    {
        ConfirmEraseCheckBox.IsChecked = false;
        UnattendedInstallCheckBox.IsChecked = false;
        UnattendedWarningCheckBox.IsChecked = false;
        UnattendedWarningCheckBox.IsEnabled = false;
        ConfirmWriteButton.IsEnabled = false;
        PrepareProgressBar.Value = 0;
        BootWriteProgressBar.Value = 0;
        HaosDownloadProgressBar.Value = 0;
        CopyPayloadProgressBar.Value = 0;
        ResetWriteCards();
        GoToStep(InstallerStep.Welcome);
    }

    private void ConfigureFinishText(bool unattendedInstall, bool hasCachedPayload)
    {
        FinishSummaryText.Text = hasCachedPayload
            ? UiText.FinishSummaryWithPayload
            : UiText.FinishSummaryNoPayload;

        FinishNextStepText.Text = unattendedInstall
            ? UiText.FinishNextStepUnattended
            : UiText.FinishNextStepAttended;
    }

    private void BuyMeCoffeeImage_MouseLeftButtonUp(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "https://buymeacoffee.com/xalies",
            UseShellExecute = true
        });
    }

    private void DriveList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        DriveNextButton.IsEnabled = DriveList.SelectedItem is UsbDriveInfo;
    }

    private async Task RefreshDrivesAsync()
    {
        SetDriveScanState(isScanning: true);
        await RunUiOperationAsync(
            async () =>
            {
                var drives = await _usbDriveService.GetRemovableDrivesAsync(CancellationToken.None);
                DriveList.ItemsSource = drives;
                DriveEmptyText.Visibility = drives.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            },
            ex =>
            {
                DriveList.ItemsSource = null;
                DriveEmptyText.Text = string.Format(UiText.ErrorScanUsbFormat, ex.Message);
                DriveEmptyText.Visibility = Visibility.Visible;
                AppendLog($"Blocked: {ex.Message}");
            },
            () => SetDriveScanState(isScanning: false));
    }

    private void SetDriveScanState(bool isScanning)
    {
        DriveScanStatusPanel.Visibility = isScanning ? Visibility.Visible : Visibility.Collapsed;
        RefreshDrivesButton.IsEnabled = !isScanning;
        DriveNextButton.IsEnabled = !isScanning && DriveList.SelectedItem is UsbDriveInfo;
        DriveEmptyText.Visibility = Visibility.Collapsed;

        if (isScanning)
        {
            DriveList.ItemsSource = null;
            DriveList.SelectedItem = null;
        }
    }

    private ImageWriteRequest BuildWriteRequest(bool validateOnly)
    {
        if (_bootImage is null)
        {
            throw new InvalidOperationException(UiText.ErrorBootImageNotFound);
        }

        if (DriveList.SelectedItem is not UsbDriveInfo drive)
        {
            throw new InvalidOperationException(UiText.ErrorSelectUsbDrive);
        }

        return new ImageWriteRequest(
            drive,
            _bootImage.ImagePath,
            DiskWriteMode.PhysicalUsb,
            validateOnly || ConfirmEraseCheckBox.IsChecked == true);
    }

    private void UpdateConfirmDriveDetails()
    {
        if (DriveList.SelectedItem is not UsbDriveInfo drive)
        {
            throw new InvalidOperationException(UiText.ErrorSelectUsbDrive);
        }

        ConfirmDriveModelText.Text = drive.Model ?? UiText.DriveFallbackModel;
        ConfirmDriveSizeText.Text = FormatBytes(drive.SizeBytes);
        ConfirmDrivePathText.Text = drive.DevicePath;
        ConfirmDriveStatusText.Text = drive.IsHaosInstaller
            ? UiText.DriveStatusExistingHaos
            : drive.ShowWindowsLayoutWarning
                ? UiText.DriveStatusWindowsLayout
                : UiText.DriveStatusReady;
    }

    private async Task RunUiOperationAsync(Func<Task> operation)
    {
        await RunUiOperationAsync(operation, ex => AppendLog($"Blocked: {ex.Message}"));
    }

    private async Task RunUiOperationAsync(Func<Task> operation, Action<Exception> onError)
    {
        await RunUiOperationAsync(operation, onError, onFinally: null);
    }

    private async Task RunUiOperationAsync(Func<Task> operation, Action<Exception> onError, Action? onFinally)
    {
        try
        {
            await operation();
        }
        catch (Exception ex)
        {
            onError(ex);
        }
        finally
        {
            onFinally?.Invoke();
        }
    }

    private void ReportProgress(ImageWriteProgress progress)
    {
        AppendLog(progress.Message);
    }

    private void ReportWriteProgress(ImageWriteProgress progress)
    {
        AppendLog(progress.Message);
    }

    private void ReportPrepareProgress(ImageWriteProgress progress) =>
        ReportSegmentProgress(progress, PrepareCard, PrepareBadge, PrepareStatusText, PrepareProgressBar);

    private void ReportBootWriteProgress(ImageWriteProgress progress) =>
        ReportSegmentProgress(progress, BootWriteCard, BootWriteBadge, BootWriteStatusText, BootWriteProgressBar);

    private void ReportHaosDownloadProgress(ImageWriteProgress progress)
    {
        if (progress.Message.StartsWith(UiText.ProgressVerifyingPrefix, StringComparison.OrdinalIgnoreCase))
        {
            ReportSegmentProgress(
                new ImageWriteProgress(UiText.ProgressVerifyingHaos, progress.Percent),
                HaosDownloadCard,
                HaosDownloadBadge,
                HaosDownloadStatusText,
                HaosDownloadProgressBar);
            return;
        }

        var downloadProgress = _latestRelease is not null &&
            !progress.Message.Contains(_latestRelease.Filename, StringComparison.OrdinalIgnoreCase)
            ? new ImageWriteProgress($"{progress.Message} ({_latestRelease.Filename})", progress.Percent)
            : progress;

        ReportSegmentProgress(downloadProgress, HaosDownloadCard, HaosDownloadBadge, HaosDownloadStatusText, HaosDownloadProgressBar);
    }

    private void ReportCopyPayloadProgress(ImageWriteProgress progress) =>
        ReportSegmentProgress(progress, CopyPayloadCard, CopyPayloadBadge, CopyPayloadStatusText, CopyPayloadProgressBar);

    private void ReportSegmentProgress(
        ImageWriteProgress progress,
        Border card,
        TextBlock badge,
        TextBlock statusText,
        ProgressBar progressBar)
    {
        AppendLog(progress.Message);
        SetWriteCardActive(card, badge);
        statusText.Text = progress.Message;
        if (progress.Percent is { } percent)
        {
            var clampedPercent = Math.Max(0, Math.Min(100, percent));
            progressBar.Value = clampedPercent;
            if (clampedPercent >= 100)
            {
                SetWriteCardDone(card, badge);
            }
        }
    }

    private void ResetWriteCards()
    {
        WriteErrorCard.Visibility = Visibility.Collapsed;
        WriteErrorText.Text = string.Empty;

        SetWriteCardWaiting(PrepareCard, PrepareBadge, active: true);
        SetWriteCardWaiting(BootWriteCard, BootWriteBadge, active: false);
        SetWriteCardWaiting(HaosDownloadCard, HaosDownloadBadge, active: false);
        SetWriteCardWaiting(CopyPayloadCard, CopyPayloadBadge, active: false);

        PrepareStatusText.Text = UiText.WritePrepareInitial;
        BootWriteStatusText.Text = UiText.WriteBootInitial;
        HaosDownloadStatusText.Text = UiText.WriteDownloadInitial;
        CopyPayloadStatusText.Text = UiText.WriteCopyInitial;
    }

    private void ShowWriteError(string message)
    {
        WriteErrorCard.Visibility = Visibility.Visible;
        WriteErrorText.Text = message;
        CopyPayloadCard.Opacity = 1.0;
        CopyPayloadCard.BorderBrush = (Brush)FindResource("HADangerBrush");
        CopyPayloadBadge.Text = UiText.WriteBadgeBlocked;
        CopyPayloadBadge.Foreground = (Brush)FindResource("HADangerBrush");
    }

    private void SetWriteCardWaiting(Border card, TextBlock badge, bool active)
    {
        card.Opacity = active ? 1.0 : 0.5;
        card.BorderBrush = (Brush)FindResource("HABorderBrush");
        badge.Text = UiText.WriteBadgeWaiting;
        badge.Foreground = (Brush)FindResource("HATextSecondaryBrush");
    }

    private void SetWriteCardActive(Border card, TextBlock badge)
    {
        card.Opacity = 1.0;
        card.BorderBrush = (Brush)FindResource("HABlueBrush");
        if (!string.Equals(badge.Text, UiText.WriteBadgeDone, StringComparison.Ordinal))
        {
            badge.Text = UiText.WriteBadgeWorking;
        }
        badge.Foreground = (Brush)FindResource("HABlueBrush");
    }

    private void SetWriteCardDone(Border card, TextBlock badge)
    {
        card.Opacity = 1.0;
        card.BorderBrush = (Brush)FindResource("HASuccessBrush");
        badge.Text = UiText.WriteBadgeDone;
        badge.Foreground = (Brush)FindResource("HASuccessBrush");
    }

    private void AppendLog(string message)
    {
        Debug.WriteLine($"[{DateTimeOffset.Now:HH:mm:ss}] {message}");
    }

    private async Task HideHaosVolumesWhileWritingAsync(CancellationToken cancellationToken)
    {
        var silentProgress = new Progress<ImageWriteProgress>(_ => { });
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                _usbDriveLetterHider.HideHaosVolumes(silentProgress);
            }
            catch
            {
                // Best effort only; the write/copy flow should report its own real failures.
            }

            try
            {
                await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        try
        {
            _usbDriveLetterHider.HideHaosVolumes(silentProgress);
        }
        catch
        {
            // Best effort final cleanup.
        }
    }

    private void GoToStep(InstallerStep step)
    {
        WelcomePage.Visibility = step == InstallerStep.Welcome ? Visibility.Visible : Visibility.Collapsed;
        DrivePage.Visibility = step == InstallerStep.Drive ? Visibility.Visible : Visibility.Collapsed;
        ConfirmPage.Visibility = step == InstallerStep.Confirm ? Visibility.Visible : Visibility.Collapsed;
        WritePage.Visibility = step == InstallerStep.Write ? Visibility.Visible : Visibility.Collapsed;
        FinishPage.Visibility = step == InstallerStep.Finish ? Visibility.Visible : Visibility.Collapsed;
        BuyMeCoffeePanel.Visibility = step == InstallerStep.Finish ? Visibility.Visible : Visibility.Collapsed;

        SetStepText(StepWelcomeText, UiText.StepWelcome, step == InstallerStep.Welcome);
        SetStepText(StepDriveText, UiText.StepDrive, step == InstallerStep.Drive);
        SetStepText(StepConfirmText, UiText.StepConfirm, step == InstallerStep.Confirm);
        SetStepText(StepWriteText, UiText.StepWrite, step is InstallerStep.Write or InstallerStep.Finish);
    }

    private static void SetStepText(System.Windows.Controls.TextBlock textBlock, string text, bool active)
    {
        textBlock.Text = text;
        textBlock.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
        textBlock.Foreground = active
            ? System.Windows.Media.Brushes.White
            : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(112, 144, 176));
    }

    private void AppendBootImageStatus(HaosInstallerBootImage bootImage)
    {
        AppendLog(bootImage.ChecksumVerified
            ? $"Using verified HAOS AIO boot image ({bootImage.Format}): {bootImage.ImagePath}"
            : $"Using HAOS AIO boot image without verified checksum ({bootImage.Format}): {bootImage.ImagePath}");
    }

    private static string GetHaosCacheDirectory()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HAOSInstaller", "HaosCache");
    }

    private static string GetUsbStagingDirectory()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HAOSInstaller", "UsbStaging");
    }

    private static string GetUsbCacheRootForRequest(ImageWriteRequest request)
    {
        return Path.Combine(GetUsbStagingDirectory(), "PhysicalUsbCachePreview");
    }

    private static IReadOnlyList<string> GetBootImageSearchDirectories()
    {
        var directories = new List<string>
        {
            Path.Combine(AppContext.BaseDirectory, "Assets", "BootImage"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HAOSInstaller", "BootImages")
        };

        var repoRoot = TryFindRepositoryRoot();
        if (repoRoot is not null)
        {
            directories.Add(Path.Combine(repoRoot, "artifacts", "installer-linux"));
            directories.Add(Path.Combine(repoRoot, "src", "InstallerLinux", "build", "out"));
        }

        return directories;
    }

    private static string GetBundledBootImageDirectory()
    {
        return Path.Combine(AppContext.BaseDirectory, "Assets", "BootImage");
    }

    private static string? TryFindRepositoryRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            if (Directory.Exists(Path.Combine(current.FullName, "src", "InstallerLinux", "build")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        return null;
    }

    private static string FormatBytes(ulong bytes)
    {
        const double gib = 1024d * 1024d * 1024d;
        return bytes == 0 ? UiText.UnknownSize : $"{bytes / gib:0.##} GiB";
    }

    private enum InstallerStep
    {
        Welcome,
        Drive,
        Confirm,
        Write,
        Finish
    }
}

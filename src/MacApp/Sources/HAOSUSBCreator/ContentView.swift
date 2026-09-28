import AppKit
import HAOSUSBCreatorCore
import SwiftUI

/// Layout of the Windows app's `MainWindow.xaml`: dark step sidebar on the left, pages on the right.
struct ContentView: View {
    @EnvironmentObject private var model: CreatorModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(step: model.step)
                .frame(width: 220)
            page
                .padding(EdgeInsets(top: 40, leading: 48, bottom: 32, trailing: 48))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HA.surface)
        }
        .background(CloseButtonLock(locked: model.isWriting))
        .alert(UiText.appTitle, isPresented: alertShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome:
            WelcomePage()
        case .drive:
            DrivePage()
        case .confirm:
            ConfirmPage()
        case .write:
            WritePage()
        case .finish:
            FinishPage()
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } })
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let step: InstallerStep

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let icon = AppImages.installerIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 68, height: 68)
                        .padding(.bottom, 16)
                }
                Text(UiText.brandLine1)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(UiText.brandLine2)
                    .font(.system(size: 13))
                    .foregroundColor(HA.sidebarMuted)
                Rectangle()
                    .fill(HA.sidebarDivider)
                    .frame(height: 1)
                    .padding(.top, 22)
            }
            .padding(EdgeInsets(top: 28, leading: 24, bottom: 28, trailing: 24))

            VStack(alignment: .leading, spacing: 14) {
                stepText(UiText.stepWelcome, active: step == .welcome)
                stepText(UiText.stepDrive, active: step == .drive)
                stepText(UiText.stepConfirm, active: step == .confirm)
                stepText(UiText.stepWrite, active: step == .write || step == .finish)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            if step == .finish {
                CoffeePanel()
                    .padding(EdgeInsets(top: 0, leading: 18, bottom: 22, trailing: 18))
            }
        }
        .frame(maxHeight: .infinity)
        .background(HA.dark)
    }

    private func stepText(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: active ? .semibold : .regular))
            .foregroundColor(active ? .white : HA.sidebarMuted)
    }
}

private struct CoffeePanel: View {
    var body: some View {
        VStack(spacing: 0) {
            Text(UiText.buyMeCoffeeShortText)
                .font(.system(size: 11))
                .foregroundColor(HA.sidebarCoffee)
                .lineLimit(1)
                .padding(.bottom, 7)
            if let image = AppImages.coffeeButton {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 36)
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(UiText.buyMeCoffeeUrl) }
                    .help(UiText.buyMeCoffeeTooltip)
            }
        }
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    @EnvironmentObject private var model: CreatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text(UiText.welcomeHeading).headingStyle(size: 26)
            Text(UiText.welcomeSubheading)
                .subheadingStyle()
                .padding(.top, 8)
                .padding(.bottom, 28)
            VStack(alignment: .leading, spacing: 8) {
                Text(UiText.welcomeWhatWillHappen)
                    .bodyStyle(semibold: true)
                    .padding(.bottom, 4)
                ForEach(UiText.welcomeBullets, id: \.self) { bullet in
                    Text(bullet).bodyStyle()
                }
            }
            // WPF: Height="303" including padding and border.
            .frame(maxWidth: .infinity, minHeight: 275, maxHeight: 275, alignment: .topLeading)
            .card()
            .padding(.bottom, 16)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(UiText.buttonGetStarted) {
                    Task { await model.getStarted() }
                }
                .buttonStyle(HAButtonStyle(kind: .primary))
            }
        }
    }
}

private struct DrivePage: View {
    @EnvironmentObject private var model: CreatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UiText.driveHeading).headingStyle()
            Text(UiText.driveSubheading)
                .subheadingStyle()
                .padding(.bottom, 18)

            HStack {
                if model.isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(width: 86)
                        Text(UiText.driveScanning).captionStyle()
                    }
                }
                Spacer()
                Button(UiText.buttonRefresh) {
                    Task { await model.refreshDrives() }
                }
                .buttonStyle(HAButtonStyle(kind: .secondary))
                .disabled(model.isScanning)
            }
            .padding(.bottom, 10)

            ZStack {
                if let message = model.driveMessage {
                    Text(message)
                        .captionStyle()
                        .multilineTextAlignment(.center)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.drives) { drive in
                            DriveCard(drive: drive, selected: model.selectedDriveID == drive.id)
                                .onTapGesture { model.selectedDriveID = drive.id }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Spacer()
                Button(UiText.buttonBack) { model.step = .welcome }
                    .buttonStyle(HAButtonStyle(kind: .secondary))
                Button(UiText.buttonContinue) { model.continueFromDrive() }
                    .buttonStyle(HAButtonStyle(kind: .primary))
                    .disabled(model.isScanning || model.selectedDrive == nil)
            }
        }
    }
}

private struct DriveCard: View {
    let drive: UsbDrive
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text("\u{1F4BE}")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(HA.surface))
                .padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(drive.model ?? UiText.driveFallbackModel)
                        .bodyStyle(semibold: true)
                        .lineLimit(1)
                    if drive.isLargeDrive {
                        Pill(text: UiText.driveLarge, background: Color(hex: 0xFFF7ED),
                             border: Color(hex: 0xFDBA74), foreground: Color(hex: 0xB45309))
                            .padding(.leading, 10)
                    }
                    if drive.isHaosInstaller {
                        Pill(text: UiText.driveHaosInstaller, background: Color(hex: 0xE8F7FE),
                             border: Color(hex: 0x9ADEFA), foreground: Color(hex: 0x0B79A5))
                            .padding(.leading, 6)
                    }
                    if drive.showWindowsLayoutWarning {
                        Pill(text: UiText.driveWindowsLayout, background: Color(hex: 0xFEF2F2),
                             border: Color(hex: 0xFCA5A5), foreground: Color(hex: 0xB91C1C))
                            .padding(.leading, 6)
                    }
                }
                Text(drive.sizeDisplay + UiText.driveDetailSeparator + drive.devicePath)
                    .captionStyle()
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Text("\u{203A}")
                .font(.system(size: 20))
                .foregroundColor(HA.textSecondary)
                .padding(.leading, 12)
        }
        .card(background: selected ? Color(hex: 0xF3FBFF) : .white,
              border: selected || hovering ? HA.blue : HA.border,
              lineWidth: 1.5, horizontal: 16, vertical: 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ConfirmPage: View {
    @EnvironmentObject private var model: CreatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UiText.confirmHeading).headingStyle()
            Text(UiText.confirmSubheading)
                .subheadingStyle()
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    driveDetails
                        .card()
                        .padding(.bottom, 12)

                    HACheckbox(isOn: $model.eraseConfirmed, text: UiText.confirmEraseText)
                        .card(background: Color(hex: 0xFFF8F0), border: HA.warning, horizontal: 16, vertical: 12)
                        .padding(.top, 4)

                    HStack(alignment: .top, spacing: 12) {
                        sshOptions
                            .frame(maxHeight: .infinity, alignment: .top)
                            .card(horizontal: 16, vertical: 12)
                        legacyOptions
                            .frame(maxHeight: .infinity, alignment: .top)
                            .card(horizontal: 16, vertical: 12)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)

                    unattendedOptions
                        .card(background: Color(hex: 0xFEF2F2), border: HA.danger, horizontal: 16, vertical: 12)
                        .padding(.top, 12)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                Button(UiText.buttonBack) { model.step = .drive }
                    .buttonStyle(HAButtonStyle(kind: .secondary))
                Button(UiText.buttonStartWrite) {
                    Task { await model.startWrite() }
                }
                .buttonStyle(HAButtonStyle(kind: .danger))
                .disabled(!model.canStartWrite)
            }
        }
    }

    private var driveDetails: some View {
        let drive = model.selectedDrive
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 10) {
            GridRow {
                label(UiText.confirmTargetUsb)
                Text(drive?.model ?? UiText.driveFallbackModel).bodyStyle(semibold: true)
            }
            GridRow {
                label(UiText.confirmSize)
                Text(drive?.sizeDisplay ?? "Unknown size").bodyStyle()
            }
            GridRow {
                label(UiText.confirmDevicePath)
                Text(drive?.devicePath ?? "").bodyStyle()
            }
            GridRow {
                label(UiText.confirmStatus)
                Text(model.driveStatusText).bodyStyle()
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .captionStyle()
            .frame(width: 125, alignment: .leading)
    }

    private var sshOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HACheckbox(isOn: $model.sshEnabled, text: UiText.sshAccessTitle, semibold: true)
            if model.sshEnabled {
                Text(UiText.sshAccessWarning)
                    .captionStyle()
                    .padding(.leading, 26)
                    .padding(.top, 8)
                Text(UiText.sshPasswordLabel)
                    .captionStyle()
                    .padding(.leading, 26)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                SecureField("", text: $model.sshPassword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 6)
                    .frame(height: 30)
                    .background(Color.white)
                    .overlay(Rectangle().strokeBorder(Color(hex: 0xABADB3), lineWidth: 1))
                    .padding(.leading, 26)
            }
        }
    }

    private var legacyOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HACheckbox(isOn: $model.legacyBios, text: UiText.legacyBiosTitle, semibold: true)
            if model.legacyBios {
                Text(UiText.legacyBiosWarning)
                    .captionStyle()
                    .padding(.leading, 26)
                    .padding(.top, 8)
            }
        }
    }

    private var unattendedOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HACheckbox(isOn: $model.unattended, text: UiText.unattendedTitle, semibold: true)
            if model.unattended {
                Text(UiText.unattendedWarning)
                    .font(.system(size: 11))
                    .foregroundColor(HA.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
                    .padding(.top, 8)
                HACheckbox(isOn: $model.unattendedConfirmed, text: UiText.unattendedConfirmText)
                    .padding(.leading, 26)
                    .padding(.top, 12)
            }
        }
    }
}

private struct WritePage: View {
    @EnvironmentObject private var model: CreatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UiText.writeHeading).headingStyle()
            Text(UiText.writeSubheading)
                .subheadingStyle()
                .padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 10) {
                    WriteCardView(title: UiText.writePrepareTitle, card: model.card(.prepare), showsBar: false)
                    WriteCardView(title: UiText.writeBootTitle, card: model.card(.boot))
                    WriteCardView(title: UiText.writeDownloadTitle, card: model.card(.download))
                    WriteCardView(title: UiText.writeCopyTitle, card: model.card(.copy))
                    if let error = model.writeError {
                        HStack(alignment: .top, spacing: 12) {
                            Text(UiText.writeErrorIcon)
                                .font(.system(size: 16))
                                .foregroundColor(HA.danger)
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(HA.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .card(background: Color(hex: 0xFEF2F2), border: HA.danger, horizontal: 16, vertical: 12)
                    }
                }
            }

            HStack {
                Spacer()
                Button(UiText.buttonBack) { model.step = .confirm }
                    .buttonStyle(HAButtonStyle(kind: .secondary))
                    .disabled(model.isWriting)
            }
            .padding(.top, 16)
        }
    }
}

private struct WriteCardView: View {
    let title: String
    let card: WriteCard
    var showsBar = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).bodyStyle(semibold: true)
                Spacer()
                Text(badge)
                    .font(.system(size: 11))
                    .foregroundColor(accent)
            }
            .padding(.bottom, showsBar ? 8 : 4)
            if showsBar {
                HAProgressBar(value: card.percent)
                    .padding(.bottom, 6)
            }
            Text(card.status).captionStyle()
        }
        .card(border: border, horizontal: 20, vertical: 16)
        .opacity(card.isActive ? 1 : 0.5)
    }

    private var badge: String {
        switch card.phase {
        case .waiting: return UiText.writeBadgeWaiting
        case .working: return UiText.writeBadgeWorking
        case .done: return UiText.writeBadgeDone
        case .blocked: return UiText.writeBadgeBlocked
        }
    }

    private var accent: Color {
        switch card.phase {
        case .waiting: return HA.textSecondary
        case .working: return HA.blue
        case .done: return HA.success
        case .blocked: return HA.danger
        }
    }

    private var border: Color {
        card.phase == .waiting ? HA.border : accent
    }
}

private struct FinishPage: View {
    @EnvironmentObject private var model: CreatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text(UiText.finishHeading).headingStyle()
            Text(model.finishSummary)
                .subheadingStyle()
                .padding(.top, 8)
                .padding(.bottom, 20)
            Text(model.finishNextStep)
                .bodyStyle()
                .textSelection(.enabled)
                .card()
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(UiText.buttonStartOver) { model.startOver() }
                    .buttonStyle(HAButtonStyle(kind: .primary))
            }
        }
    }
}

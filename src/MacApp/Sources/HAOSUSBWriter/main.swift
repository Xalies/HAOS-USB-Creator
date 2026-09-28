import Foundation
import HAOSUSBCreatorCore

// USB writing part of the macOS app. The app starts it with `--write <request.json>` and reads the
// progress lines printed here. It asks for the administrator password to open the USB device.
let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "--write" else {
    FileHandle.standardError.write(Data("Use the HAOS USB Creator app to write a USB drive.\n".utf8))
    exit(2)
}

let writer = PrivilegedWriter { event in
    FileHandle.standardOutput.write(Data((event.line + "\n").utf8))
}
exit(writer.run(requestPath: arguments[2]))

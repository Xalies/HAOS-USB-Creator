import Foundation
import Security

/// Opens a raw disk device through Apple's `authopen`, which asks for an administrator password
/// and hands the open file descriptor back over a socket.
///
/// A plain `open("/dev/rdiskN")` fails with "Operation not permitted" even as root when the process
/// was started through `osascript ... with administrator privileges`: macOS then cannot tie the
/// process to the app for the "Removable Volumes" privacy permission. `authopen` checks that
/// permission on the app that started the writer instead, so the writer runs unprivileged.
public final class RawDiskAccess {
    public static let prompt = "HAOS AIO USB Creator needs administrator access to write the USB drive."
    public static let cancelledMessage = "Administrator authorization was cancelled."

    private static let authopenPath = "/usr/libexec/authopen"
    private let path: String
    private let authorization: AuthorizationRef

    /// Asks for the administrator password (the standard macOS prompt) to open `path` read/write.
    public init(path: String) throws {
        self.path = path
        var reference: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &reference)
        guard status == errAuthorizationSuccess, let reference else {
            throw CreatorError("Could not start administrator authorization (\(status)).")
        }
        authorization = reference

        let right = "sys.openfile.readwrite.\(path)"
        status = right.withCString { rightName in
            Self.prompt.withCString { promptText in
                kAuthorizationEnvironmentPrompt.withCString { promptKey in
                    var rightItem = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptKey, valueLength: strlen(promptText),
                                                       value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    return withUnsafeMutablePointer(to: &rightItem) { rightPointer in
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(reference, &rights, &environment,
                                                           [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess:
            break
        case errAuthorizationCanceled:
            AuthorizationFree(reference, [])
            throw CreatorError(Self.cancelledMessage)
        default:
            AuthorizationFree(reference, [])
            throw CreatorError("Administrator authorization failed (\(status)).")
        }
    }

    deinit {
        AuthorizationFree(authorization, [.destroyRights])
    }

    /// Returns a read/write descriptor for the device. Throws `RawDiskBusy` while the device is
    /// still in use, so the caller can wait and try again.
    public func open() throws -> Int32 {
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(authorization, &external) == errAuthorizationSuccess else {
            throw CreatorError("Could not pass the administrator authorization to authopen.")
        }

        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw CreatorError("Could not open \(path): \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(sockets[0]) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.authopenPath)
        process.arguments = ["-stdoutpipe", "-extauth", "-o", String(O_RDWR), path]
        let input = Pipe()
        let errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
        process.standardError = errorOutput
        do {
            try process.run()
        } catch {
            Darwin.close(sockets[1])
            throw error
        }
        // Only authopen keeps the other end now, so a failed open ends the read below.
        Darwin.close(sockets[1])
        let form = withUnsafeBytes(of: &external) { Data($0) }
        try? input.fileHandleForWriting.write(contentsOf: form)
        try? input.fileHandleForWriting.close()

        let descriptor = Self.receiveDescriptor(sockets[0])
        process.waitUntilExit()
        let message = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let descriptor {
            return descriptor
        }
        if message.contains(String(cString: strerror(EBUSY))) {
            throw RawDiskBusy()
        }
        // authopen reports e.g. "authopen: couldn't open /dev/rdisk4: Operation not permitted".
        let reason = message.replacingOccurrences(of: "authopen: couldn't open", with: "Could not open")
        throw CreatorError(reason.isEmpty ? "Could not open \(path) (authopen exit code \(process.terminationStatus))." : reason)
    }

    /// Reads one SCM_RIGHTS message from authopen and returns the descriptor it carries.
    private static func receiveDescriptor(_ socket: Int32) -> Int32? {
        var payload: Int32 = 0
        let headerSize = (MemoryLayout<cmsghdr>.size + 3) & ~3
        var control = [UInt8](repeating: 0, count: headerSize + MemoryLayout<Int32>.size)
        return withUnsafeMutableBytes(of: &payload) { payloadBuffer -> Int32? in
            control.withUnsafeMutableBytes { controlBuffer -> Int32? in
                var vector = iovec(iov_base: payloadBuffer.baseAddress, iov_len: payloadBuffer.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer -> Int32? in
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                         msg_control: controlBuffer.baseAddress,
                                         msg_controllen: socklen_t(controlBuffer.count), msg_flags: 0)
                    var received: Int
                    repeat {
                        received = recvmsg(socket, &message, 0)
                    } while received < 0 && errno == EINTR
                    guard received > 0, Int(message.msg_controllen) >= controlBuffer.count else { return nil }
                    let header = controlBuffer.load(as: cmsghdr.self)
                    guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return nil }
                    return controlBuffer.loadUnaligned(fromByteOffset: headerSize, as: Int32.self)
                }
            }
        }
    }
}

/// The raw device is still in use, e.g. while macOS finishes unmounting it.
public struct RawDiskBusy: Error {}

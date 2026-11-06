import Foundation

/// How to reach one Mac from the other, as the Sharing page words it.
public struct SharingDirections: Equatable, Sendable {
    public enum Service: Sendable {
        case fileSharing, remoteLogin
    }

    public let service: Service
    public let heading: String
    public let firstStep: String
    public let secondStep: String
    /// What the page shows on its own line: the address or command, or what's missing.
    public let addressLine: String
    /// What Copy puts on the pasteboard. Empty until there's something to connect to.
    public let address: String
    /// What Open hands to the connection.
    public let openTarget: String
    public let canCopy: Bool
    public let canOpen: Bool

    public var openTitle: String { service == .fileSharing ? "Open in Finder" : "Open in Terminal" }
    public var copyTitle: String { service == .fileSharing ? "Copy Address" : "Copy Command" }
}

extension SharingDirections {
    private static func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Reaching this Mac from inside the guest.
    public static func toHost(
        service: Service, hostAddress: String?, hostUser: String, isPreMetalGuest: Bool, usesWindowsFileSharing: Bool,
        isConnected: Bool
    ) -> SharingDirections {
        let files = service == .fileSharing
        let username = quoted(hostUser)
        var address = ""
        if let hostAddress, !hostAddress.isEmpty {
            address = files ? "smb://\(hostAddress)" : "ssh -l '\(username)' \(hostAddress)"
            // Guests too old to reach this Mac's sshd use the installed client. Installed guests depend on this path.
            if !files, isPreMetalGuest {
                address =
                    "'/Library/Application Support/Virtual Intel Mac/GuestTools/guest-ssh' -l '\(username)' \(hostAddress)"
            }
        }
        let connection = NSURLComponents()
        connection.scheme = files ? "smb" : "ssh"
        connection.host = hostAddress
        if !files { connection.user = hostUser }
        let settings = "System Settings → General → Sharing"
        let firstStep =
            usesWindowsFileSharing && files
            ? "1. On this Mac, go to System Settings → General → Sharing. Click the info button next to File Sharing and "
                + "turn it on. Click Options, turn on SMB sharing, then select your account under Windows File Sharing "
                + "and enter its password."
            : "1. On this Mac, open \(settings) and enable \(files ? "File Sharing" : "Remote Login")."
        return SharingDirections(
            service: service,
            heading: files
                ? "Open this Mac’s files inside the virtual Mac" : "Connect to this Mac from the virtual Mac",
            firstStep: firstStep,
            secondStep: files
                ? "2. In the virtual Mac’s Finder, choose Go → Connect to Server and enter:"
                : "2. In the virtual Mac’s Terminal, run:",
            addressLine: address.isEmpty
                ? "Start the virtual Mac and connect its network to discover this Mac’s address." : address,
            address: address,
            openTarget: address.isEmpty ? "" : connection.url?.absoluteString ?? "",
            canCopy: !address.isEmpty,
            canOpen: isConnected && !address.isEmpty)
    }

    /// Reaching the guest from this Mac. `port` is the local forward, used on a shared network.
    public static func toGuest(
        service: Service, isShared: Bool, port: NSNumber?, guestAddress: String?, guestUsername: String,
        smbForwardURL: String, isPreMetalGuest: Bool, identifier: String, isConnected: Bool, isEnabled: Bool
    ) -> SharingDirections {
        let files = service == .fileSharing
        let guestAddress = guestAddress ?? ""
        let portText = port?.stringValue ?? "(null)"
        var address =
            if isShared {
                files ? smbForwardURL : "ssh -p \(portText) -l '\(guestUsername)' 127.0.0.1"
            } else if guestAddress.isEmpty {
                ""
            } else {
                files ? "smb://\(guestAddress)" : "ssh -l '\(guestUsername)' \(guestAddress)"
            }
        if !files, isPreMetalGuest, !address.isEmpty {
            // Stock 13F34 advertises AES-GCM but its sshd aborts when using it. Keep period crypto options and the
            // known-host identity scoped to this machine, and never weaken the user's global SSH configuration.
            address =
                "ssh -o HostKeyAlgorithms=+ssh-rsa -c aes128-ctr -o HostKeyAlias=vim-\(identifier.lowercased()) "
                + "-p \(isShared ? portText : "22") -l '\(quoted(guestUsername))' "
                + "'\(isShared ? "127.0.0.1" : guestAddress)'"
        }
        let hasAccount = files || !guestUsername.isEmpty
        let connection = NSURLComponents()
        connection.scheme = files ? "smb" : "ssh"
        connection.host = isShared ? "127.0.0.1" : guestAddress
        connection.port = isShared ? port : nil
        if !files { connection.user = guestUsername }
        return SharingDirections(
            service: service,
            heading: files ? "Open the virtual Mac’s files on this Mac" : "Connect to the virtual Mac with SSH",
            firstStep: files
                ? "1. In the virtual Mac, open System Preferences → Sharing and turn on File Sharing. In Options, enable "
                    + "SMB for your account."
                : "1. In the virtual Mac, open System Preferences → Sharing and turn on Remote Login.",
            secondStep: files
                ? "2. On this Mac, connect using the virtual Mac’s account and password:"
                : "2. Run this command in Terminal on this Mac:",
            addressLine: !hasAccount
                ? "Enter your guest account’s short name above."
                : (address.isEmpty ? "Start the virtual Mac and wait for its network address." : address),
            address: address,
            openTarget: files || isPreMetalGuest
                ? address : (address.isEmpty ? "" : connection.url?.absoluteString ?? ""),
            canCopy: !address.isEmpty && hasAccount,
            canOpen: isConnected && (!isShared || isEnabled) && !address.isEmpty && hasAccount)
    }
}

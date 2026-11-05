import Foundation

/// A process that exited in the guest.
public struct GuestProcessResult: Sendable, Equatable {
    /// The final `guest-exec-status` reply, including `exitcode` and `signal` when reported.
    public let status: [String: JSONValue]
    public let standardOutput: Data
    public let standardError: Data

    /// Exit status zero, with no `signal` key at all, whatever its value.
    public var isSuccessful: Bool {
        status["exitcode"]?.number?.intValue == 0 && status["signal"] == nil
    }

    /// Standard output as UTF-8, or nil when it isn't.
    public var output: String? {
        NSString(data: standardOutput, encoding: String.Encoding.utf8.rawValue) as String?
    }
}

/// What `stageFiles` uploaded. Holds sizes rather than proof of installation: nothing is installed by staging.
public struct GuestStagingReceipt: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public let name: String
        public let size: Int
    }

    public let directory: String
    public let files: [File]
}

/// An asynchronous QMP event, as QEMU sent it.
public struct QMPEvent: Sendable, Equatable {
    public let name: String
    /// The whole event object, including `timestamp`, which the Objective-C handler received too.
    public let fields: [String: JSONValue]

    public var data: JSONValue? { fields["data"] }
}

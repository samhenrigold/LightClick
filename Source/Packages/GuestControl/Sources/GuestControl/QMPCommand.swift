import Foundation

/// The QMP commands the app sends, with the argument names QEMU expects.
public struct QMPCommand: Sendable, Equatable {
    public let name: String
    public let arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    // MARK: - Run state

    public static let queryStatus = QMPCommand(name: "query-status")
    public static let cont = QMPCommand(name: "cont")
    public static let systemWakeup = QMPCommand(name: "system_wakeup")

    // MARK: - Diagnostics

    public static let queryCPUsFast = QMPCommand(name: "query-cpus-fast")
    public static let queryPCI = QMPCommand(name: "query-pci")
    public static let queryBlock = QMPCommand(name: "query-block")
    public static let queryNetwork = QMPCommand(name: "x-query-network")
    public static let queryInterruptControllers = QMPCommand(name: "x-query-interrupt-controllers")

    public static func humanMonitorCommand(_ commandLine: String) -> QMPCommand {
        QMPCommand(name: "human-monitor-command", arguments: ["command-line": .string(commandLine)])
    }

    public static func traceEventSetState(name: String, enable: Bool) -> QMPCommand {
        QMPCommand(
            name: "trace-event-set-state",
            arguments: ["name": .string(name), "enable": .number(enable as NSNumber)]
        )
    }

    // MARK: - Input

    /// The connection retries this one command for five seconds while the emulator reports a full keyboard queue.
    public static func inputSendEvent(events: [JSONValue]) -> QMPCommand {
        QMPCommand(name: "input-send-event", arguments: ["events": .array(events)])
    }

    public static func sendKey(keys: [JSONValue], holdTime: Int) -> QMPCommand {
        QMPCommand(name: "send-key", arguments: ["keys": .array(keys), "hold-time": .number(holdTime as NSNumber)])
    }

    // MARK: - Network

    public static func setLink(name: String, up: Bool) -> QMPCommand {
        QMPCommand(name: "set_link", arguments: ["name": .string(name), "up": .number(up as NSNumber)])
    }

    // MARK: - Media

    /// The app both leaves `force` out and sends it, and those differ on the wire.
    public static func eject(id: String, force: Bool? = nil) -> QMPCommand {
        var arguments: [String: JSONValue] = ["id": .string(id)]
        if let force { arguments["force"] = .number(force as NSNumber) }
        return QMPCommand(name: "eject", arguments: arguments)
    }

    /// The app only ever inserts media read-only.
    public static func blockdevChangeMedium(id: String, filename: String, format: String) -> QMPCommand {
        QMPCommand(
            name: "blockdev-change-medium",
            arguments: [
                "id": .string(id), "filename": .string(filename), "format": .string(format),
                "read-only-mode": "read-only"
            ]
        )
    }

    // MARK: - Devices

    public static func deviceAdd(driver: String, id: String, properties: [String: JSONValue] = [:]) -> QMPCommand {
        let arguments = properties.merging(["driver": .string(driver), "id": .string(id)]) { $1 }
        return QMPCommand(name: "device_add", arguments: arguments)
    }

    public static func deviceDel(id: String) -> QMPCommand {
        QMPCommand(name: "device_del", arguments: ["id": .string(id)])
    }

    public static func chardevAddUnixClient(id: String, path: String) -> QMPCommand {
        let address: JSONValue = ["type": "unix", "data": ["path": .string(path)]]
        return QMPCommand(
            name: "chardev-add",
            arguments: ["id": .string(id), "backend": ["type": "socket", "data": ["addr": address, "server": false]]]
        )
    }

    public static func chardevRemove(id: String) -> QMPCommand {
        QMPCommand(name: "chardev-remove", arguments: ["id": .string(id)])
    }

    // MARK: - QOM

    public static func qomList(path: String) -> QMPCommand {
        QMPCommand(name: "qom-list", arguments: ["path": .string(path)])
    }

    public static func qomGet(path: String, property: String) -> QMPCommand {
        QMPCommand(name: "qom-get", arguments: ["path": .string(path), "property": .string(property)])
    }

    public static func qomSet(path: String, property: String, value: JSONValue) -> QMPCommand {
        QMPCommand(name: "qom-set", arguments: ["path": .string(path), "property": .string(property), "value": value])
    }
}

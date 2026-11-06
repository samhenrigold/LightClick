import Foundation
import Synchronization
import Testing

@testable import MachineKit

private func attachPlist(_ entities: [[String: String]]) throws -> String {
    let data = try PropertyListSerialization.data(
        fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
    return String(decoding: data, as: UTF8.self)
}

private let formatted = [
    ["content-hint": "GUID_partition_scheme", "dev-entry": "/dev/disk9"],
    ["content-hint": "Apple_HFS", "dev-entry": "/dev/disk9s1"]
]

/// Plays the disk tools: each step writes what the real one would to its log.
private final class FakeTools: PackageToolRunning {
    struct Refused: Error {}

    let commands = Mutex<[[String]]>([])
    let attachLog: String
    let volumeUUID: String
    let refusing: String?
    let sourceSize: Int
    let resultSize: Int
    let backing: Bool

    init(
        attachLog: String? = nil, volumeUUID: String = UUID().uuidString, refusing: String? = nil,
        sourceSize: Int = 1 << 30, resultSize: Int = 1 << 30, backing: Bool = false
    ) throws {
        self.attachLog = try attachLog ?? ("warning\n" + attachPlist(formatted) + "\nmore warning")
        self.volumeUUID = volumeUUID
        self.refusing = refusing
        self.sourceSize = sourceSize
        self.resultSize = resultSize
        self.backing = backing
    }

    var verbs: [String] { commands.withLock { $0.map { $0[0] } } }

    func run(_ executable: URL, _ arguments: [String], log: URL) throws {
        let verb = arguments[0]
        commands.withLock { $0.append(arguments) }
        if verb == refusing { throw Refused() }
        var output = ""
        switch verb {
        case "attach": output = attachLog
        case "info" where arguments[1] == "-plist":
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["VolumeUUID": volumeUUID], format: .xml, options: 0)
            output = String(decoding: data, as: UTF8.self)
        case "info":
            let result = arguments.last?.hasSuffix("System.qcow2") == true
            var json = #"{"format":"qcow2","virtual-size":\#(result ? resultSize : sourceSize)"#
            if backing && result { json += #","backing-filename":"/x""# }
            output = json + "}"
        case "create":
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: arguments.last!), withIntermediateDirectories: true)
        default: break
        }
        try output.write(to: log, atomically: true, encoding: .utf8)
    }
}

private struct Inputs {
    let root: URL
    var library: URL { root.appendingPathComponent("Library") }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["code", "nvram", "boot", "tool", "disk"] { try Data("x".utf8).write(to: file(name)) }
        try Data("installer".utf8).write(to: file("installer"))
    }
}

@Suite struct MachinePackageBuilderTests {
    private func builder(
        _ tools: FakeTools, research: Bool = false, free: UInt64 = 1 << 50, ports: Bool = true
    ) -> MachinePackageBuilder {
        MachinePackageBuilder(
            tools: tools, researchEnabled: research,
            networkDefaults: { configuration, _, _ in
                ports ? configuration.merging(["NetworkMode": "shared"]) { $1 } : nil
            },
            freeBytes: { _ in free })
    }

    private func create(
        _ builder: MachinePackageBuilder, _ inputs: Inputs, guest: String = "mojave", diskGiB: Int = 64
    ) throws -> URL {
        try builder.createGuest(
            guest, name: "My Mac", diskGiB: diskGiB, library: inputs.library, firmware: inputs.file("code"),
            nvram: inputs.file("nvram"), bootMedia: inputs.file("boot"), installer: inputs.file("installer"),
            qemuImage: inputs.file("tool"))
    }

    private func importing(_ builder: MachinePackageBuilder, _ inputs: Inputs) throws -> URL {
        try builder.importDisk(
            inputs.file("disk"), guest: "mojave", name: "My Mac", library: inputs.library,
            firmware: inputs.file("code"), nvram: inputs.file("nvram"), bootMedia: inputs.file("boot"),
            qemuImage: inputs.file("tool"))
    }

    private func plist(_ url: URL) -> [String: PropertyListValue] {
        GuestInstallationTransaction.record(at: url) ?? [:]
    }

    private func stages(_ inputs: Inputs) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: inputs.library.appendingPathComponent("Machines").path)
            .filter { $0.hasPrefix(".") }
    }

    @Test func aNewPackageIsCompleteWhenItAppears() throws {
        let tools = try FakeTools()
        let inputs = try Inputs()
        let package = try create(builder(tools), inputs)
        #expect(package.lastPathComponent == "My Mac.vintelmac")
        #expect(package.deletingLastPathComponent().lastPathComponent == "Machines")
        #expect(try stages(inputs).isEmpty)
        #expect(tools.verbs == ["create", "attach", "info", "convert", "detach"])

        let configuration = plist(package.appendingPathComponent("Machine.plist"))
        #expect(configuration["Guest"] == "mojave")
        #expect(configuration["DiskGiB"] == 64)
        #expect(configuration["InstallState"] == "installing")
        #expect(configuration["InstallerMediaShared"] == true)
        #expect(configuration["InstallerMediaKind"] == "optical")
        #expect(configuration["BootMedia"] == "Firmware/OpenCore.iso")
        #expect(configuration["FirmwareSource"] == "application")
        #expect(configuration["NetworkMode"] == "shared")

        let owner = plist(package.appendingPathComponent("Installation/Ownership.plist"))
        #expect(owner["MachineIdentifier"] == configuration["Identifier"])
        #expect(owner["Size"] == 9)
        #expect(plist(package.appendingPathComponent("State/Install.plist"))["Phase"] == "awaiting-os-install")
        #expect(
            plist(package.appendingPathComponent("State/InstallationTarget.plist"))["VolumeUUID"]
                == .string(tools.volumeUUID))
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("Firmware/NVRAM.fd").path))
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("Firmware/CODE.fd").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: package.appendingPathComponent("Disks/Formatting.sparsebundle").path))
    }

    @Test func theSeedIsFormattedAtTheRequestedSizeAndConvertedRaw() throws {
        let tools = try FakeTools()
        _ = try create(builder(tools), Inputs(), diskGiB: 100)
        let commands = tools.commands.withLock { $0 }
        #expect(commands[0][1...2] == ["-size", "100g"])
        #expect(commands[3].contains("/dev/rdisk9"))
        #expect(commands[4] == ["detach", "/dev/disk9"])
    }

    @Test func aGPTBootImageIsNamedForWhatItIs() throws {
        let inputs = try Inputs()
        var header = Data(repeating: 0, count: 512)
        header.append(Data("EFI PART".utf8))
        try header.write(to: inputs.file("boot"))
        let package = try create(builder(FakeTools()), inputs)
        let configuration = plist(package.appendingPathComponent("Machine.plist"))
        #expect(configuration["BootMedia"] == "Firmware/EFI.img")
        #expect(configuration["BootMediaKind"] == "efi-disk")
    }

    @Test func tigerResearchCopiesItsFirmwareAndUsesTheVMwareAdapter() throws {
        let package = try create(builder(FakeTools(), research: true), Inputs(), guest: "tiger")
        let configuration = plist(package.appendingPathComponent("Machine.plist"))
        #expect(configuration["FirmwareSource"] == "package")
        #expect(configuration["LegacyDisplayAdapter"] == "vmware")
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("Firmware/CODE.fd").path))
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("Firmware/OpenCore.iso").path))
    }

    @Test(arguments: [(guest: "nope", disk: 64), (guest: "mojave", disk: 39), (guest: "mojave", disk: 2049)])
    func aBadRequestMakesNothing(guest: String, disk: Int) throws {
        let inputs = try Inputs()
        let tools = try FakeTools()
        #expect(throws: MachinePackageIssue.self) { try create(builder(tools), inputs, guest: guest, diskGiB: disk) }
        #expect(tools.verbs.isEmpty)
    }

    @Test func aMissingInputIsNamedBeforeAnythingIsMade() throws {
        let inputs = try Inputs()
        try FileManager.default.removeItem(at: inputs.file("installer"))
        #expect(throws: MachinePackageIssue("A required firmware, installer, or disk tool file is missing.")) {
            try create(builder(FakeTools()), inputs)
        }
    }

    @Test func creatingNeedsRoomForAnInstalledSystemNotTheWholeDisk() throws {
        let enough: UInt64 = 26 << 30
        #expect(throws: Never.self) { try create(builder(FakeTools(), free: enough), Inputs(), diskGiB: 1024) }
        #expect(throws: MachinePackageIssue("The library needs enough free space for the requested disk.")) {
            try create(builder(FakeTools(), free: enough - 1), Inputs(), diskGiB: 1024)
        }
    }

    @Test func anUnrecognizedAttachDetachesByPathAndKeepsTheStage() throws {
        let inputs = try Inputs()
        let tools = try FakeTools(attachLog: "nonsense")
        #expect(throws: MachinePackageIssue.self) { try create(builder(tools), inputs) }
        #expect(tools.verbs == ["create", "attach", "detach"])
        #expect(tools.commands.withLock { $0.last?.last?.hasSuffix("Formatting.sparsebundle") } == true)
        #expect(try stages(inputs).count == 1)
    }

    @Test func aVolumeThatCantBeIdentifiedDetachesTheDevice() throws {
        let tools = try FakeTools(volumeUUID: "not-a-uuid")
        #expect(throws: MachinePackageIssue.self) { try create(builder(tools), Inputs()) }
        #expect(tools.commands.withLock { $0.last } == ["detach", "/dev/disk9"])
    }

    @Test func twoHFSSlicesAreTooManyToTrust() throws {
        let entities = formatted + [["content-hint": "Apple_HFS", "dev-entry": "/dev/disk9s2"]]
        let tools = try FakeTools(attachLog: attachPlist(entities))
        #expect(throws: MachinePackageIssue.self) { try create(builder(tools), Inputs()) }
        #expect(!tools.verbs.contains("convert"))
    }

    @Test func aFailedConversionStillDetaches() throws {
        let tools = try FakeTools(refusing: "convert")
        #expect(throws: FakeTools.Refused.self) { try create(builder(tools), Inputs()) }
        #expect(tools.verbs.last == "detach")
    }

    @Test func noPortsMeansNoPackage() throws {
        let inputs = try Inputs()
        #expect(throws: MachinePackageIssue.self) { try create(builder(FakeTools(), ports: false), inputs) }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: inputs.library.appendingPathComponent("Machines").path
            ).allSatisfy { $0.hasPrefix(".") })
    }

    @Test func anImportIsAnIndependentCopy() throws {
        let tools = try FakeTools()
        let inputs = try Inputs()
        let package = try importing(builder(tools), inputs)
        #expect(tools.verbs == ["info", "convert", "info"])
        let configuration = plist(package.appendingPathComponent("Machine.plist"))
        #expect(configuration["InstallState"] == "imported-prepared")
        #expect(configuration["ImportedFrom"] == .string(inputs.file("disk").path))
        #expect(plist(package.appendingPathComponent("State/Import.plist"))["Phase"] == "complete")
    }

    @Test func anImportNeedsItsWholeSizeAndAMargin() throws {
        let tools = try FakeTools(sourceSize: 10 << 30, resultSize: 10 << 30)
        #expect(throws: MachinePackageIssue("The selected library needs more free space for a safe import.")) {
            try importing(builder(tools, free: 12 << 30 - 1), Inputs())
        }
        #expect(throws: Never.self) { try importing(builder(tools, free: 12 << 30), Inputs()) }
    }

    @Test func aResultWithABackingFileOrAnotherSizeFailsTheCheck() throws {
        let issue = MachinePackageIssue("The imported disk did not pass the independence check.")
        #expect(throws: issue) { try importing(builder(FakeTools(backing: true)), Inputs()) }
        #expect(throws: issue) { try importing(builder(FakeTools(resultSize: 5)), Inputs()) }
    }

    @Test func attachLogsAreReadThroughTheirNoise() throws {
        let image = AttachedImage(log: "warning\n" + (try attachPlist(formatted)) + "\ntrailing")
        #expect(image.validDevice == "/dev/disk9")
        #expect(image.validSlice(of: "/dev/disk9") == "/dev/disk9s1")
        #expect(image.validSlice(of: "/dev/disk1") == nil)
        #expect(AttachedImage(log: "").device == nil)
    }
}

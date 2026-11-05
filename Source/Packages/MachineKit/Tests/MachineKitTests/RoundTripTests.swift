import Foundation
import InstallerKit
import Testing

@testable import MachineKit

@Suite struct RoundTripTests {
    @Test(arguments: ["MavericksMachine", "EveryKeyMachine"])
    func aFileIsRewrittenByteForByte(fixture: String) throws {
        let data = try Fixture.data(fixture)
        #expect(try MachineConfiguration(propertyList: data).propertyList() == data)
    }

    /// The fixtures hold no real at a whole number, which is the one thing Codable can't tell apart.
    @Test(arguments: ["MavericksMachine", "EveryKeyMachine"])
    func codableWritesTheSameFile(fixture: String) throws {
        let data = try Fixture.data(fixture)
        let decoded = try PropertyListDecoder().decode(MachineConfiguration.self, from: data)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        #expect(try encoder.encode(decoded) == data)
    }

    @Test func aFilesOwnFormatSurvivesATypedEdit() throws {
        var configuration = try MachineConfiguration(propertyList: try Fixture.data("EveryKeyMachine"))
        configuration.cpuCount = 2
        let rewritten = try #require(
            PropertyListSerialization.propertyList(from: try configuration.propertyList(), format: nil) as? NSDictionary
        )
        let original = try #require(
            PropertyListSerialization.propertyList(from: try Fixture.data("EveryKeyMachine"), format: nil)
                as? NSMutableDictionary)
        original["CPUCount"] = 2
        #expect(rewritten == original)
        // A Boolean stored as an integer stays one, unless someone sets it.
        #expect(try configuration.propertyList().contains(Data("<integer>1</integer>".utf8)))
    }

    @Test func unknownKeysAreKept() throws {
        let configuration = try MachineConfiguration(propertyList: try Fixture.data("EveryKeyMachine"))
        let future = try #require(configuration.values["FutureKey"]?.dictionary)
        #expect(future["Ratio"]?.number?.doubleValue == 2.5)
        #expect(future["Data"] == .data(Data([1, 2, 3])))
        #expect(future["List"] == [1, "two"])
        #expect(configuration.values["FutureDate"] != nil)
    }

    @Test func aWholeNumberRealStaysARealWhenReadFromAFile() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Scale": 4.0], format: .xml, options: 0)
        #expect(String(decoding: data, as: UTF8.self).contains("<real>4</real>"))
        #expect(try MachineConfiguration(propertyList: data).propertyList() == data)
    }

    @Test func aFileThatIsNotADictionaryIsInvalid() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["one"], format: .xml, options: 0)
        #expect(throws: MachineConfigurationError.invalidConfiguration) { try MachineConfiguration(propertyList: data) }
        #expect(throws: (any Error).self) { try MachineConfiguration(propertyList: Data("nope".utf8)) }
    }

    @Test func everyKeyReadsAsItsType() throws {
        let c = try MachineConfiguration(propertyList: try Fixture.data("EveryKeyMachine"))
        #expect(c.formatVersion == 1)
        #expect(c.identifier == UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        #expect(c.name == "Example Mac")
        #expect(c.guest == .tiger)
        #expect(c.cpuCount == 8)
        #expect(c.memoryMiB == 4096)
        #expect(c.diskGiB == 64)
        #expect(c.disk?.rawValue == "Disks/System.qcow2")
        #expect(c.firmware?.rawValue == "Firmware/CODE.fd")
        #expect(c.nvram?.rawValue == "Firmware/NVRAM.fd")
        #expect(c.bootMedia?.rawValue == "Firmware/OpenCore.iso")
        #expect(c.bootMediaKind == .legacyOpenCoreISO)
        #expect(c.firmwareSource == .package)
        #expect(c.installerMedia == .shared(AbsolutePath(rawValue: "/Volumes/Library/Installers/Tiger.iso")!))
        #expect(c.installerMediaKind == .optical)
        #expect(c.installState == .patching)
        #expect(c.importedFrom == "/Volumes/Images/Original.qcow2")
        #expect(c.networkMode == .bridged)
        #expect(c.bridgeInterface == "en0")
        #expect(c.networkConnected == true)
        #expect(c.macAddress == "02:34:56:78:9a:bc")
        #expect(c.effectiveMACAddress == "02:34:56:78:9A:BC")
        #expect(c.sshEnabled == true)
        #expect(c.sshPort == 2223)
        #expect(c.fileSharingEnabled == false)
        #expect(c.fileSharingPort == 1446)
        #expect(c.audioEnabled == true)
        #expect(c.audioInputDevice == "disabled")
        #expect(c.audioOutputDevice == "default")
        #expect(c.clipboardEnabled == false)
        #expect(c.machineDescription == "$null")
        #expect(c.retinaEnabled == false)
        #expect(c.displayMode == .space)
        #expect(c.displayScalingFilter == .nearest)
        #expect(c.opticalMedia?.rawValue == "/Volumes/Images/First.iso")
        #expect(c.additionalMedia == [nil, AbsolutePath(rawValue: "/Volumes/Images/Second.dmg")])
        #expect(c.legacyDisplayAdapter == .vmware)
        #expect(c.legacyGDBPort == 1234)
        #expect(!c.passthroughOpenGLEnabled)
    }

    /// Every key the app's sources read from a configuration must be modeled.
    @Test func everyKeyTheAppReadsIsModeled() throws {
        let sources = Fixture.sourceRoot.appending(path: "VirtualIntelMac")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { ["m", "h"].contains($0.pathExtension) && $0.lastPathComponent != "VIMGuestProfile.h" }
        let pattern = /(?:configuration|editableConfiguration|config|c)\[@"([A-Z][A-Za-z]+)"\]/
        let modeled = Set(MachineConfiguration.Key.allCases.map(\.rawValue))
        // Not Machine.plist keys: the same variable names hold other property lists in these files.
        let elsewhere: Set = ["Enabled", "Media", "MachineIdentifier", "Phase", "VolumeUUID"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                let key = String(match.1)
                #expect(modeled.contains(key) || elsewhere.contains(key), "\(file.lastPathComponent) reads \(key)")
            }
        }
    }

    @Test func theMavericksShapeIsAValidMachine() throws {
        let configuration = try MachineConfiguration(propertyList: try Fixture.data("MavericksMachine"))
        #expect(configuration.hasValidSettings)
        #expect(configuration.guest == .mavericks)
        #expect(configuration.installState == .installed)
        #expect(configuration.passthroughOpenGLEnabled)
        #expect(configuration.installerMedia == nil)
    }

    @Test func aMalformedValueReadsAsNilAndIsStillWrittenBack() throws {
        var configuration = Fixture.configuration
        configuration.values["InstallState"] = 7
        configuration.values["Guest"] = "plan9"
        #expect(configuration.installState == nil)
        #expect(configuration.guest == nil)
        #expect(configuration.values["InstallState"] == 7)
        let data = try configuration.propertyList()
        #expect(try MachineConfiguration(propertyList: data).values["Guest"] == "plan9")
    }
}

@Suite struct ValueTests {
    /// The Objective-C checks depend on these. If they changed, every evidence check would change with them.
    @Test func equalityIsObjectiveCIsEqual() {
        let yes: PropertyListValue = true
        let one: PropertyListValue = 1
        #expect(yes == one)
        #expect(PropertyListValue(foundationObject: 1.0) == one)
        #expect(PropertyListValue.string("1") != one)
        #expect(PropertyListValue.null != yes)
        // Canonically equivalent strings are different evidence, unlike Swift's ==.
        #expect("\u{E9}" == "e\u{301}")
        #expect(PropertyListValue.string("\u{E9}") != PropertyListValue.string("e\u{301}"))
    }

    @Test func twoMissingValuesNeverMatch() {
        let missing: PropertyListValue? = nil
        #expect(!missing.isEqual(nil))
        #expect(!missing.isEqual("x"))
        let present: PropertyListValue? = "x"
        #expect(!present.isEqual(nil))
        #expect(present.isEqual("x"))
    }

    @Test func jsonNullIsPresentButNeverTrue() {
        let value: PropertyListValue? = PropertyListValue(foundationObject: NSNull())
        #expect(value == .null)
        #expect(!value.isTrue)
        #expect(!value.boolValue)
    }

    @Test func aBooleanStaysDistinctFromAnIntegerWhenWritten() throws {
        let values: [String: PropertyListValue] = ["Bool": true, "Int": 1]
        let data = try MachineConfiguration(values: values).propertyList()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("<true/>"))
        #expect(text.contains("<integer>1</integer>"))
    }

    @Test func installerKitsGuestIsTheOneInUse() {
        #expect(Guest(rawValue: "snowleopard") == .snowLeopard)
        var configuration = MachineConfiguration()
        configuration.guest = .bigSur
        #expect(configuration.values["Guest"] == "bigsur")
    }

    @Test func theImageSlotCountMatchesTheApp() throws {
        let header = try String(
            contentsOf: Fixture.sourceRoot.appending(path: "VirtualIntelMac/VIMImageSlots.h"), encoding: .utf8)
        #expect(header.contains("VIMImageSlotCount = \(MachineConfiguration.imageSlotCount);"))
    }
}

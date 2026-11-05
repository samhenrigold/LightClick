import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let record = CommandLine.arguments.contains("--record")
let scenarios =
    try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "scenarios.json")))
    as! [[String: Any]]
nonisolated let usb3 = ["elcapitan", "sierra", "highsierra", "mojave", "catalina", "bigsur"]
nonisolated let preMetal = [
    "tiger", "leopard", "snowleopard", "lion", "mountainlion", "mavericks", "yosemite", "elcapitan", "sierra",
    "highsierra"
]

// Mirrors how VIMSession.m resolves these values before asking for a plan.
func makeInput(_ s: [String: Any]) -> LaunchInput {
    let config = s["config"] as! [String: Any]
    let argv = s["argv"] as! [String]
    let guest = s["guest"] as! String
    let machine = s["machinePath"] as! String
    func option(_ name: String) -> String? { argv.firstIndex(of: name).map { argv[$0 + 1] } }
    func bool(_ key: String) -> Bool { s[key] as? Bool ?? false }
    let input = LaunchInput()
    input.guest = guest
    input.machineName = s["machineName"] as! String
    input.machinePath = machine
    input.configuration = config
    input.processArguments = ["app"] + argv
    input.inheritedEnvironment = s["inherited"] as! [String: String]
    input.appleSilicon = bool("appleSilicon")
    input.preMetalGuest = preMetal.contains(guest)
    input.openGLResearchGuest = input.preMetalGuest && bool("research")
    input.passthroughOpenGLEnabled = config["PassthroughOpenGLEnabled"] as? Bool ?? false
    input.installerDisplay = bool("installerDisplay")
    input.hasPublishedGuestGraphics = bool("hasGraphics")
    input.bootPolicySignatureOnly = bool("signatureOnly")
    let researchFirmware = input.openGLResearchGuest && config["FirmwareSource"] as? String != "application"
    let override = option("--guest-efi") ?? (researchFirmware ? machine + "/" + (config["BootMedia"] as! String) : nil)
    input.bootMediaOverridden = override != nil
    input.biosPath = "/Fixture/Runtime/pc-bios"
    input.firmwarePath = researchFirmware ? machine + "/" + (config["Firmware"] as! String) : "/Fixture/Runtime/CODE.fd"
    input.nvramPath = machine + "/" + (config["NVRAM"] as! String)
    input.bootMediaPath = override ?? "/Fixture/Runtime/EFI.img"
    input.diskPath = machine + "/" + (config["Disk"] as! String)
    if let installer = config["InstallerMedia"] as? String {
        input.installerPath = config["InstallerMediaShared"] as? Bool == true ? installer : machine + "/" + installer
    }
    input.runtimeDirectory = "/Fixture/run"
    input.qmpPath = "/Fixture/run/control"
    input.helperPath = "/Fixture/Runtime/helper"
    input.donorPath = "/Fixture/Runtime/donor"
    input.llvmPath = "/Fixture/Runtime/libLLVM.dylib"
    input.displaySocketPath = "/Fixture/run/display"
    input.inprocessOpenGLLibrary = s["inprocessLibrary"] as? String
    input.vramServiceIdentifier = "FIXED-UUID"
    input.guestWidth = 1920
    input.guestHeight = 1200
    input.displayMode = s["displayMode"] as! String
    input.backingScaleFactor = s["backingScale"] as! Double
    input.supportsRetinaDisplay = bool("supportsRetina")
    input.legacyDisplayRefreshMS = s["refreshMS"] as! Int
    input.networkMode = s["networkMode"] as? String ?? "shared"
    input.macAddress = "52:54:00:11:22:33"
    input.researchCPUModel = option("--opengl-cpu-model")
    input.systemDiskInterface = option("--system-disk-interface")
    let audioOff = config["AudioEnabled"] as? Bool == false
    input.audioOutputSelection = audioOff ? "disabled" : s["audioOut"] as! String
    input.audioInputSelection = audioOff ? "disabled" : s["audioIn"] as! String
    input.audioOutputRate = 48000
    input.audioInputRate = 44100
    let devices = s["audioDevices"] as! [String: String]
    input.audioOutputDeviceName = devices[input.audioOutputSelection]
    input.audioInputDeviceName = devices[input.audioInputSelection]
    func format(_ path: String) -> String { path.hasSuffix(".dmg") ? "dmg" : "raw" }
    if let optical = config["OpticalMedia"] as? String, !optical.contains("missing") {
        input.opticalPath = optical
        input.opticalFormat = format(optical)
    }
    for (index, path) in (config["AdditionalMedia"] as? [String] ?? []).enumerated()
    where !path.isEmpty && !path.contains("missing") {
        input.additionalImages.append(LaunchImage(slot: index + 1, path: path, format: format(path)))
    }
    input.imageUSBBus = usb3.contains(guest) ? "xhci.0" : "usb.0"
    input.imageUSBBasePort = usb3.contains(guest) ? 1 : 3
    if input.preMetalGuest && config["InstallerMedia"] != nil { input.setupMediaPath = s["setupMedia"] as? String }
    return input
}

let expectedURL = directory.appending(path: "expected.json")
let expected =
    record ? [:] : try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as! [String: [String: Any]]
var recorded: [String: Any] = [:]
var failures = 0
for scenario in scenarios {
    let name = scenario["name"] as! String
    guard let plan = LaunchPlan(input: makeInput(scenario)) else {
        print("FAIL \(name): no plan")
        failures += 1
        continue
    }
    recorded[name] = ["args": plan.arguments, "env": plan.environment]
    if record { continue }
    let args = expected[name]?["args"] as? [String] ?? []
    let env = expected[name]?["env"] as? [String: String] ?? [:]
    if plan.arguments != args {
        let index =
            zip(plan.arguments, args).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(plan.arguments.count, args.count)
        print(
            "FAIL \(name) argument \(index):\n  plan     \(plan.arguments.dropFirst(index).first ?? "<end>")\n  expected \(args.dropFirst(index).first ?? "<end>")"
        )
        failures += 1
    }
    if plan.environment != env {
        let keys = Set(plan.environment.keys).union(env.keys).filter { plan.environment[$0] != env[$0] }.sorted()
        print(
            "FAIL \(name) environment: \(keys.map { "\($0): plan \(plan.environment[$0] ?? "<unset>"), expected \(env[$0] ?? "<unset>")" })"
        )
        failures += 1
    }
}
if record {
    try JSONSerialization.data(
        withJSONObject: recorded, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ).write(to: expectedURL)
    print("RECORDED \(recorded.count) scenarios")
} else if failures > 0 {
    print("FAIL \(failures) of \(scenarios.count) scenarios differ")
    exit(1)
} else {
    print("PASS \(scenarios.count) scenarios")
}

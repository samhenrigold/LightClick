import Foundation
import SeamlessIntegration

// Generates the proxy .app for one guest app from what the guest reported, or removes one.
//
//     SeamlessMakeProxy write APPS.json NAME MACHINE_ID MACHINE_NAME MACHINE_PATH OUT_DIR PROXY_EXECUTABLE SOCKET [ICON]
//     SeamlessMakeProxy remove BUNDLE
let arguments = CommandLine.arguments
do {
    if arguments.count == 3, arguments[1] == "remove" {
        try ProxyBundle.remove(URL(fileURLWithPath: arguments[2]))
    } else if arguments.count >= 10, arguments[1] == "write" {
        let apps = try JSONDecoder().decode([GuestApp].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        guard let app = apps.first(where: { $0.name == arguments[3] }) else {
            print("No app named \(arguments[3]) among \(apps.count)")
            exit(1)
        }
        let bundle = try ProxyBundle(
            app: app, machine: .init(identifier: arguments[4], name: arguments[5], path: arguments[6]), rank: .none
        ).write(
            to: URL(fileURLWithPath: arguments[7]), proxyExecutable: URL(fileURLWithPath: arguments[8]),
            sessionSocket: arguments[9], guestIcon: arguments.count > 10 ? URL(fileURLWithPath: arguments[10]) : nil)
        print(bundle.path)
    } else {
        print("usage: see the source")
        exit(64)
    }
} catch {
    print("Failed: \(error)")
    exit(1)
}

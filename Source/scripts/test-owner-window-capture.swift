// Headless contract checks with production OwnerWindowCapture.swift. Does not call capture or create NSApplication/NSWindow.
import Foundation

@main
private enum OwnerWindowCaptureChecks {
    static func main() throws {
        let nonce = "0E32763A-B341-4D04-8DBC-41BED9551022"
        let request = OwnerWindowCaptureRequest(command: "owner-capture-report 45 \(nonce)\n")
        precondition(request?.guestID == 45 && request?.nonce == nonce)
        for command in ["owner-capture-report 0 \(nonce)", "owner-capture-report -1 \(nonce)",
                        "owner-capture-report 4294967296 \(nonce)", "owner-capture-report 45 ../../other",
                        "owner-capture-report 45", "owner-capture-report 45 \(nonce) extra",
                        "materials-report 45 \(nonce)", "owner-capture-report 45.0 \(nonce)"] {
            precondition(OwnerWindowCaptureRequest(command: command) == nil)
        }
        let report = OwnerWindowCaptureReport(guestID: 45, nonce: nonce, proxyPID: 1234,
                                              hostWindowID: 4567, preflightAvailable: true,
                                              preflightAllowed: false, readCount: 1, width: 1200,
                                              height: 800, failureCategory: "none")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        precondition(object["guestID"] as? Int == 45 && object["nonce"] as? String == nonce)
        precondition(object["proxyPID"] as? Int == 1234 && object["hostWindowID"] as? Int == 4567)
        precondition(object["preflightAllowed"] as? Bool == false && object["readCount"] as? Int == 1)
        precondition(object["width"] as? Int == 1200 && object["height"] as? Int == 800)
        precondition(object["failureCategory"] as? String == "none")
        precondition(object.count == 10) // No pixel payload, caller path or unrelated window list.
        print("PASS owner capture request bounds, nonce identity and metadata-only report schema (no window/capture runtime)")
    }
}

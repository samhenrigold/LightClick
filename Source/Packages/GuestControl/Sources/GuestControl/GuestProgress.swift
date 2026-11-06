import Foundation

private func progressError(_ message: String) -> NSError {
    NSError(domain: "VirtualIntelMac.GuestProgress", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func json(_ reply: [String: Any]?) -> [String: Any]? {
    guard (reply?["exitcode"] as? NSNumber) == 0 else { return nil }
    return (try? JSONSerialization.jsonObject(with: reply?["stdout"] as? Data ?? Data())) as? [String: Any]
}

/// The window the guest's setup tool shows while its files are installed, through the tool itself.
@MainActor @objc(VIMGuestProgress)
public final class GuestProgress: NSObject {
    private let agent: GuestAgentBridge
    private let directory: String
    private let tool: String
    @objc public let receipt: [String: Any]

    /// A saved receipt comes back through the guest and a plist, so its paths are checked before they're run.
    private init?(agent: GuestAgentBridge, receipt: Any?) {
        guard let receipt = receipt as? [String: Any], let directory = receipt["Directory"] as? String,
            let tool = receipt["Tool"] as? String, Self.isValid(directory: directory, tool: tool)
        else { return nil }
        self.agent = agent
        self.directory = directory
        self.tool = tool
        self.receipt = receipt
    }

    nonisolated static func isValid(directory: String, tool: String) -> Bool {
        let pattern = try? NSRegularExpression(pattern: "^/private/var/tmp/VirtualIntelMacUI\\.[A-Za-z0-9]{6}$")
        let matches = pattern?.numberOfMatches(
            in: directory, range: NSRange(location: 0, length: directory.utf16.count))
        let components = (tool as NSString).pathComponents
        return matches == 1
            && (tool.hasPrefix("/private/var/tmp/VirtualIntelMac.")
                || tool.hasPrefix("/private/var/db/VirtualIntelMac."))
            && (tool as NSString).lastPathComponent == "guest-progress" && !components.contains("..")
            && components.count == 6
    }

    @objc(progressWithAgent:receipt:)
    public class func progress(agent: GuestAgentBridge, receipt: Any?) -> GuestProgress? {
        GuestProgress(agent: agent, receipt: receipt)
    }

    @objc(startWithAgent:staging:completion:)
    public class func start(
        agent: GuestAgentBridge, staging directory: String, completion: @escaping (GuestProgress?, NSError?) -> Void
    ) {
        Task { @MainActor in
            let tool = (directory as NSString).appendingPathComponent("guest-progress")
            do {
                let mode = try await agent.run("/bin/chmod", ["0700", tool], timeout: 15)
                guard (mode?["exitcode"] as? NSNumber) == 0 else {
                    throw progressError("Could not prepare the guest setup window.")
                }
            } catch {
                completion(nil, error as NSError)
                return
            }
            let icon = (directory as NSString).appendingPathComponent("SupportIcon.png")
            do {
                let reply = try await agent.run(tool, ["--start", icon], timeout: 60)
                var started = json(reply)
                started?["Tool"] = tool
                if let progress = GuestProgress(agent: agent, receipt: started) {
                    completion(progress, nil)
                } else {
                    let detail = (reply?["stderr"] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    completion(
                        nil,
                        progressError(
                            detail.isEmpty ? "The guest setup window could not open. Nothing was installed." : detail))
                }
            } catch {
                completion(nil, error as NSError)
            }
        }
    }

    @objc(updateMode:fraction:message:completion:)
    public func update(mode: String, fraction: Double, message: String, completion: ((NSError?) -> Void)?) {
        Task { @MainActor in
            do {
                let reply = try await agent.run(
                    tool, ["--update", directory, mode, NSNumber(value: fraction).stringValue, message], timeout: 15)
                completion?(
                    (json(reply)?["Updated"] as? NSNumber) == true
                        ? nil : progressError("The guest setup window did not acknowledge its status."))
            } catch {
                completion?(error as NSError)
            }
        }
    }

    @objc(waitForRestartChoice:)
    public func waitForRestartChoice(_ completion: @escaping (String?, NSError?) -> Void) {
        Task { @MainActor in
            do {
                let choice = json(try await agent.run(tool, ["--wait", directory], timeout: 180))?["Action"] as? String
                if let choice, ["restart", "postpone"].contains(choice) {
                    completion(choice, nil)
                } else {
                    completion(
                        nil,
                        progressError(
                            "The guest restart choice could not be confirmed. Restart this Mac manually when ready."))
                }
            } catch {
                completion(nil, error as NSError)
            }
        }
    }
}

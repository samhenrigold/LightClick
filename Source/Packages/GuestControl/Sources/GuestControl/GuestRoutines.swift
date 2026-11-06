// Short sequences of guest commands, each with its own idea of success. The session decides when one may run and owns its
// busy flag; these decide what the guest's answers mean. Completions run on main.

import Foundation

extension GuestAgentBridge {
    private func exit(_ reply: [String: Any]?) -> NSNumber? { reply?["exitcode"] as? NSNumber }

    func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 0) async throws -> [String: Any]? {
        let reply: GuestReply = try await withCheckedThrowingContinuation { continuation in
            runExecutable(path, arguments: arguments, timeout: timeout) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: GuestReply(values: result))
                }
            }
        }
        return reply.values
    }

    private func connected() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connect { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func staged(_ files: [String: URL]) async throws -> String? {
        let reply: GuestReply = try await withCheckedThrowingContinuation { continuation in
            stageFiles(files, progress: nil) { receipt, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: GuestReply(values: receipt))
                }
            }
        }
        return reply.values?["Directory"] as? String
    }

    private func report(
        _ completion: @escaping (NSError?) -> Void, _ work: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await work()
                completion(nil)
            } catch {
                completion(error as NSError)
            }
        }
    }

    // MARK: - Remote Login

    /// `systemsetup` can print an authorization failure and still exit zero, so this checks the setting afterward.
    @objc(enableRemoteLoginWithCompletion:)
    public func enableRemoteLogin(completion: @escaping (NSError?) -> Void) {
        report(completion) { [self] in
            try await connected()
            let set = try await run("/usr/sbin/systemsetup", ["-setremotelogin", "on"], timeout: 30)
            guard exit(set) == 0 else {
                throw sessionError(
                    "macOS could not enable Remote Login automatically. In the virtual Mac, open System Preferences → "
                        + "Sharing and select Remote Login.")
            }
            let check = try await run("/usr/sbin/systemsetup", ["-getremotelogin"], timeout: 15)
            let text = String(data: check?["stdout"] as? Data ?? Data(), encoding: .utf8) ?? ""
            guard exit(check) == 0, text.contains("Remote Login: On") else {
                throw sessionError(
                    "Remote Login is still off. Enable it in the virtual Mac’s System Preferences → Sharing; macOS may "
                        + "require your approval there.")
            }
        }
    }

    // MARK: - Screen Sharing

    /// Runs `steps`, the last of which checks the service: its exit status says whether it's on.
    @objc(applyScreenSharingSteps:enabling:completion:)
    public func applyScreenSharing(steps: [[String]], enabling: Bool, completion: @escaping (NSError?) -> Void) {
        report(completion) { [self] in
            try await connected()
            var last: [String: Any]?
            for step in steps { last = try await run(step[0], Array(step.dropFirst()), timeout: 30) }
            if (exit(last) == 0) != enabling {
                throw sessionError(
                    enabling
                        ? "Screen Sharing is still off. Turn it on in the virtual Mac’s System Preferences → Sharing."
                        : "Screen Sharing is still on. Turn it off in the virtual Mac’s System Preferences → Sharing.")
            }
        }
    }

    // MARK: - Mavericks File Sharing

    /// Stages and runs the compatibility tool. The completion gets what went wrong, as text for the log.
    @objc(applySMBCompatibilityTool:allocator:completion:)
    public func applySMBCompatibility(tool: URL, allocator: URL, completion: @escaping (String?) -> Void) {
        Task { @MainActor in
            do {
                guard let directory = try await staged(["mavericks-smb-compat": tool, "codesign_allocate": allocator])
                else {
                    completion("staging returned nothing")
                    return
                }
                let program = (directory as NSString).appendingPathComponent("mavericks-smb-compat")
                let allocatorProgram = (directory as NSString).appendingPathComponent("codesign_allocate")
                guard exit(try await run("/bin/chmod", ["0700", program, allocatorProgram])) == 0 else {
                    completion("chmod failed")
                    return
                }
                let reply = try await run(program, [allocatorProgram])
                if exit(reply) == 0 {
                    completion(nil)
                } else {
                    let detail = String(data: reply?["stderr"] as? Data ?? Data(), encoding: .utf8) ?? ""
                    let field = { (key: String) in reply?[key].map { "\($0)" } ?? "(null)" }
                    completion("exit \(field("exitcode")), signal \(field("signal")): \(detail)")
                }
            } catch {
                completion((error as NSError).localizedDescription)
            }
        }
    }

    // MARK: - Guest helpers

    /// Sets up a helper installed with the guest's graphics support, giving it its configuration on stdin. The completion
    /// gets the step that failed, or nil.
    @objc(provisionInstalledHelperWithConfiguration:completion:)
    public func provisionInstalledHelper(configuration: Data, completion: @escaping (String?) -> Void) {
        runExecutable(
            "/Library/Application Support/Virtual Intel Mac/GuestTools/guest-clipboard",
            arguments: ["--provision-stdin"], standardInput: configuration, timeout: 0
        ) { [self] result, error in
            completion(
                Self.helperFailure("installed GUI helper setup", code: exit(result), failed: error != nil))
        }
    }

    /// Stages a helper and its private configuration, and has it set itself up. The completion gets the step that failed,
    /// or nil. `stillWanted` is asked once the transfer is done, since it can outlast the helper's bridge.
    @objc(provisionHelper:configuration:named:stillWanted:completion:)
    public func provisionHelper(
        _ helper: URL, configuration: URL, named name: String, stillWanted: @escaping () -> Bool,
        completion: @escaping (String?) -> Void
    ) {
        Task { @MainActor in
            var step = "transfer"
            do {
                guard let directory = try await staged(["guest-clipboard": helper, name: configuration]), stillWanted()
                else {
                    completion(step)
                    return
                }
                step = "executable preparation"
                let program = (directory as NSString).appendingPathComponent("guest-clipboard")
                guard exit(try await run("/bin/chmod", ["0700", program], timeout: 10)) == 0 else {
                    completion(step)
                    return
                }
                step = "private configuration preparation"
                // guest-file-open follows the agent's umask, not the source file's mode. Tighten the private
                // configuration before its native validator reads it. The staging directory is root-only.
                let settings = (directory as NSString).appendingPathComponent(name)
                guard exit(try await run("/bin/chmod", ["0600", settings], timeout: 10)) == 0 else {
                    completion(step)
                    return
                }
                step = "GUI helper setup"
                let result = try await run(program, ["--provision", settings], timeout: 30)
                completion(Self.helperFailure(step, code: exit(result), failed: false))
            } catch {
                completion(step)
            }
        }
    }

    /// The step's name with its exit status if it reported one, or nil if it succeeded.
    static func helperFailure(_ step: String, code: NSNumber?, failed: Bool) -> String? {
        if code == 0 && !failed { return nil }
        return code.map { "\(step) (exit \($0))" } ?? step
    }

    // MARK: - Setup media

    /// Whether the mounted setup disc is the one this machine made, going by its receipt, after a good graphics check.
    public static func setupDiscMayRetire(owner: [String: Any]?, machineIdentifier: Any?, report: [String: Any]?)
        -> Bool
    {
        guard let owner, let report, report["PixelChecksPassed"] as? NSNumber == true as NSNumber else { return false }
        return same(owner["MachineIdentifier"], machineIdentifier) && same(owner["VolumeUUID"], report["VolumeUUID"])
    }

    private static func same(_ first: Any?, _ second: Any?) -> Bool {
        guard let first = first as? NSObject, let second = second as? NSObject else { return false }
        return first.isEqual(second)
    }

    /// Ejects the dedicated configuration disc once setup has passed. The user's CD/DVD drive, including any repair disc,
    /// is never touched. The guest must eject first, and only an image it can eject cleanly is removed. Calls `ejected`
    /// if the emulator removed it.
    @objc(retireSetupDiscOwnedBy:machineIdentifier:report:control:ejected:)
    public func retireSetupDisc(
        owner: [String: Any]?, machineIdentifier: Any?, report: [String: Any]?, control: QMPConnectionBridge,
        ejected: @escaping () -> Void
    ) {
        retireSetupDisc(
            owner: owner, machineIdentifier: machineIdentifier, report: report, commands: control, ejected: ejected)
    }

    func retireSetupDisc(
        owner: [String: Any]?, machineIdentifier: Any?, report: [String: Any]?, commands: any ControlCommands,
        ejected: @escaping () -> Void
    ) {
        guard Self.setupDiscMayRetire(owner: owner, machineIdentifier: machineIdentifier, report: report) else {
            return
        }
        let identity = owner ?? [:]
        Task { @MainActor in
            do {
                // XML is native to every period guest, and Snow's plutil predates JSON conversion.
                let reply = try await run(
                    "/usr/bin/plutil", ["-convert", "xml1", "-o", "-", "/Volumes/VIM Setup/VirtualIntelMac.plist"])
                let policy = (reply?["stdout"] as? Data).flatMap {
                    (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
                }
                guard exit(reply) == 0, let policy,
                    Self.same(policy["MachineIdentifier"], identity["MachineIdentifier"]),
                    Self.same(policy["VolumeUUID"], identity["VolumeUUID"])
                else { return }
                guard exit(try await run("/usr/sbin/diskutil", ["eject", "/Volumes/VIM Setup"])) == 0 else { return }
                try await commands.run("eject", ["id": "opengl-setup-device"])
                ejected()
            } catch {
                // Never force a mounted image, and an uncertain answer leaves it.
            }
        }
    }

    /// Whether `diskutil info -plist` describes our own installer volume at `volume`. A physical USB volume with the same
    /// name must never be mistaken for the emulator's media.
    public static func isEmulatedVolume(_ information: [String: Any]?, at volume: String) -> Bool {
        information?["MountPoint"] as? String == volume
            && (information?["MediaName"] as? String)?.hasPrefix("QEMU ") == true
    }

    /// Ejects whichever of `volumes` are the emulator's, one at a time, while `shouldContinue` holds. Never forces or
    /// retries an uncertain eject: stopped-VM cleanup remains what releases the owned image.
    @objc(ejectEmulatedVolumes:while:)
    public func ejectEmulatedVolumes(_ volumes: [String], while shouldContinue: @escaping () -> Bool) {
        Task { @MainActor in
            for volume in volumes {
                guard shouldContinue() else { return }
                let reply = try? await run("/usr/sbin/diskutil", ["info", "-plist", volume], timeout: 15)
                let information = (reply?["stdout"] as? Data).flatMap {
                    (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
                }
                if exit(reply) == 0, Self.isEmulatedVolume(information, at: volume) {
                    _ = try? await run("/usr/sbin/diskutil", ["eject", volume], timeout: 30)
                }
            }
        }
    }
}

/// A guest answer on its way through a continuation, on the main actor at both ends.
private struct GuestReply: @unchecked Sendable {
    let values: [String: Any]?
}

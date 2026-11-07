import AppKit
import GuestControl
import MachineKit

/// What a session does when its emulator reports an event or exits. MachineKit decides what each one means.
extension VIMSession {
    @objc func handleLifecycleEvent(_ event: [String: Any]) {
        let qmp = QMPEvent(event: event)
        switch qmp.kind {
        case .deviceDeleted:
            (usbDevicesObject as? USBDevices)?.deviceWasDeleted(qmp.device)
            (imageDrivesObject as? ImageDrives)?.deviceDeleted(qmp.device)
        case .reset:
            guestIPAddresses = nil
            displayToolDirectory = nil
            displayView?.displaySleeping = true
            displayView?.displaySleeping = false
        case .suspend, .shutdown:
            if qmp.expectsGuestReboot { noteGuestRebootExpected() }
            displayView?.displaySleeping = true
            statePanel?.isHidden = true
            if qmp.kind == .suspend {
                lastRunState = "suspended"
                status?.stringValue = "Sleeping"
            }
        case .wakeup:
            lastRunState = "running"
            displayView?.displaySleeping = false
            statePanel?.isHidden = true
            status?.stringValue = "Running"
        case .graphicsLost:
            offerRestartAfterGraphicsLoss()
        case .trayOpened:
            forgetImages((imageDrivesObject as? ImageDrives)?.trayOpened(onDevice: qmp.device) ?? [:])
        case .other:
            break
        }
        if let json = try? JSONSerialization.data(withJSONObject: event) {
            logMessage("Lifecycle: \(String(decoding: json, as: UTF8.self))")
        }
    }

    private func forgetImages(_ removed: [NSNumber: String]) {
        guard let machine else { return }
        let settings = VIMImageClearedSelections(machine.editableConfiguration, removed) ?? [:]
        guard !settings.isEmpty else { return }
        do {
            try machine.saveSettings(settings)
        } catch {
            VIMPresentError(error, window)
        }
        NotificationCenter.default.post(name: Notification.Name("VIMLibraryChanged"), object: nil)
    }

    /// The emulator has exited. Its last events are read first, since they say whether this was a reboot.
    @objc(handleExitOfTask:) func handleExit(of task: Process) {
        guard let control = controlConnection as? QMPConnectionBridge else { return finishExit(of: task) }
        control.drainLifecycleEventsAfterExit {
            MainActor.assumeIsolated { self.finishExit(of: task) }
        }
    }

    private func finishExit(of task: Process) {
        let state = currentSessionState() as! GuestSessionStateBridge
        let plan = state.exitPlan(
            exited: task.terminationReason == .exit, terminationStatus: task.terminationStatus,
            recentGuestReboots: recentGuestReboots)
        status?.stringValue = plan.statusText
        displayView?.displaySleeping = true
        stateLabel?.stringValue = plan.stateText
        statePanel?.isHidden = false
        stateAction?.isHidden = false
        // For the session that replaces this one to carry on with: see continueFromSession.
        recentGuestReboots = plan.guestReboot ? plan.recentGuestReboots : nil
        let waitingURL = plan.relaunch ? pendingHostConnectionURL : nil
        let waitingCompletion = plan.relaunch ? pendingHostConnectionCompletion : nil
        if plan.relaunch {
            pendingHostConnectionURL = nil
            pendingHostConnectionCompletion = nil
        }
        shutdownButton?.isEnabled = false
        cleanUp()
        if plan.showStoppedScreen { showStoppedScreen() }
        if plan.rebootLoop {
            VIMPresentError(
                NSError(
                    domain: "VirtualIntelMac.Session", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "This Mac restarted repeatedly and was stopped. Open Session Details to check its boot log, then try starting it again."
                    ]), window)
        }
        if plan.closeWindow { window?.close() }
        if !plan.relaunch && VIMCreatingGuestFromArguments() {
            // The window would wait for a click on Start. Cleanup above finished an install that was verified.
            if machine?.configuration["InstallState"] as? String == "installed" { exit(0) }
            VIMFailCreateGuest("\(plan.statusText) before the installation finished.")
        }
        // A successful open publishes its own library notification once the replacement owns the session lock. Background
        // maintenance mustn't be invited into the gap between cleanup and that.
        guard plan.relaunch else {
            NotificationCenter.default.post(name: Notification.Name("VIMLibraryChanged"), object: nil)
            return
        }
        relaunch(waitingFor: waitingURL, completion: waitingCompletion)
    }

    /// The new session chooses its own safe display hardware. A valid setup or privacy restart must also work before
    /// graphics are published, so requiring acceleration here would strand a bootable machine.
    private func relaunch(waitingFor url: URL?, completion: ((Error?) -> Void)?) {
        guard let current = machine else { return }
        let previousWindow = window
        let previousFrame = previousWindow?.frame ?? .zero
        pendingHostConnectionURL = url
        pendingHostConnectionCompletion = completion
        do {
            let fresh = try VIMMachine.load(current.url)
            try VIMSession.open(fresh)
            let replacement = VIMSession.session(for: fresh)
            replacement?.window?.setFrame(previousFrame, display: true)
            if replacement?.window !== previousWindow { previousWindow?.close() }
        } catch {
            guestStatus.stringValue = error.localizedDescription
            VIMFailCreateGuest(error.localizedDescription)
            NotificationCenter.default.post(name: Notification.Name("VIMLibraryChanged"), object: nil)
            pendingHostConnectionURL = nil
            pendingHostConnectionCompletion = nil
            completion?(error)
        }
    }
}

import Foundation
import Testing

@testable import MachineKit

@MainActor
private final class FakeUSB: USBDeviceHost, USBConnectionPrompts {
    struct Failure: Error, Equatable { var step: String }

    var isRunning = true
    var storageResult = USBStorage(isProtected: false, hasMountedVolumes: false)
    var failing: Set<String> = []
    var stopsAt: String?
    var steps: [String] = []
    var pendingAtSteps: [String: Bool] = [:]
    var choice = USBUnmountChoice.unmount
    var confirmsForce = true
    var offersForce = true
    var presented: [String] = []
    weak var attachments: USBAttachments?

    private func step(_ name: String) throws {
        steps.append(name)
        pendingAtSteps[name] = attachments?.isPending
        if stopsAt == name { isRunning = false }
        if failing.contains(name) { throw Failure(step: name) }
    }

    func storage() throws -> USBStorage {
        try step("storage")
        return storageResult
    }
    func requestStorageAccess() async throws { try step("access") }
    func releaseDisks(force: Bool) async throws { try step(force ? "force" : "release") }
    func prepareCapture() async throws { try step("prepare") }
    func capture() async throws { try step("capture") }
    func disconnect() async throws { try step("disconnect") }

    func confirmUnmount(of name: String) async -> USBUnmountChoice {
        steps.append("ask")
        pendingAtSteps["ask"] = attachments?.isPending
        return choice
    }
    func confirmForceUnmount(of name: String) async -> Bool {
        steps.append("ask force")
        return confirmsForce
    }
    func offerForceUnmountAfterFailure(of name: String) async -> Bool {
        steps.append("offer force")
        pendingAtSteps["offer force"] = attachments?.isPending
        return offersForce
    }
    func present(_ error: any Error) {
        pendingAtSteps["present"] = attachments?.isPending
        presented.append((error as? Failure)?.step ?? error.localizedDescription)
    }
}

@MainActor
@Suite struct USBAttachmentsTests {
    private func make() -> (USBAttachments, FakeUSB) {
        let attachments = USBAttachments()
        let usb = FakeUSB()
        usb.attachments = attachments
        return (attachments, usb)
    }

    private func toggle(_ attachments: USBAttachments, _ usb: FakeUSB) async {
        await attachments.toggle(identifier: "usb1", name: "Stick", host: usb, prompts: usb)
    }

    @Test func anUnmountedDeviceConnectsWithoutAsking() async {
        let (attachments, usb) = make()
        await toggle(attachments, usb)
        #expect(usb.steps == ["storage", "access", "prepare", "capture"])
        #expect(attachments.attached == ["usb1": "Stick"])
        #expect(!attachments.isPending)
        #expect(usb.pendingAtSteps["capture"] == true)
    }

    @Test func nothingHappensWhileStopped() async {
        let (attachments, usb) = make()
        usb.isRunning = false
        await toggle(attachments, usb)
        #expect(usb.steps.isEmpty)
        #expect(attachments.attached == nil)
    }

    @Test func aMountedDeviceAsksFirstAndReleasesAfterAccess() async {
        let (attachments, usb) = make()
        usb.storageResult.hasMountedVolumes = true
        await toggle(attachments, usb)
        #expect(usb.steps == ["storage", "ask", "access", "release", "prepare", "capture"])
        #expect(usb.pendingAtSteps["ask"] == false)
    }

    @Test func cancellingLeavesTheDeviceAlone() async {
        let (attachments, usb) = make()
        usb.storageResult.hasMountedVolumes = true
        usb.choice = .cancel
        await toggle(attachments, usb)
        #expect(usb.steps == ["storage", "ask"])
        #expect(usb.presented.isEmpty)
    }

    @Test func forcingAsksTwice() async {
        let (attachments, usb) = make()
        usb.storageResult.hasMountedVolumes = true
        usb.choice = .forceUnmount
        await toggle(attachments, usb)
        #expect(usb.steps == ["storage", "ask", "ask force", "access", "force", "prepare", "capture"])

        let (second, declined) = make()
        declined.storageResult.hasMountedVolumes = true
        declined.choice = .forceUnmount
        declined.confirmsForce = false
        await toggle(second, declined)
        #expect(declined.steps == ["storage", "ask", "ask force"])
    }

    @Test func aFailedUnmountOffersForceWithNothingPending() async {
        let (attachments, usb) = make()
        usb.storageResult.hasMountedVolumes = true
        usb.failing = ["release"]
        await toggle(attachments, usb)
        #expect(usb.steps == ["storage", "ask", "access", "release", "offer force", "force", "prepare", "capture"])
        #expect(usb.pendingAtSteps["offer force"] == false)
        #expect(usb.pendingAtSteps["force"] == true)
        #expect(attachments.attached == ["usb1": "Stick"])
    }

    @Test func decliningForceEndsQuietly() async {
        let (attachments, usb) = make()
        usb.storageResult.hasMountedVolumes = true
        usb.failing = ["release"]
        usb.offersForce = false
        await toggle(attachments, usb)
        #expect(usb.steps.last == "offer force")
        #expect(usb.presented.isEmpty)
        #expect(!attachments.isPending)
    }

    @Test func aFailedForceIsFinal() async {
        let (attachments, usb) = make()
        usb.storageResult.hasMountedVolumes = true
        usb.choice = .forceUnmount
        usb.failing = ["force"]
        await toggle(attachments, usb)
        #expect(usb.steps.last == "force")
        #expect(usb.presented == ["force"])
        #expect(usb.pendingAtSteps["present"] == false)
    }

    @Test func aProtectedDeviceIsRefused() async {
        let (attachments, usb) = make()
        usb.storageResult = USBStorage(isProtected: true, hasMountedVolumes: true)
        await toggle(attachments, usb)
        #expect(usb.steps == ["storage"])
        #expect(usb.presented.first?.hasPrefix("This device contains Light Click") == true)
    }

    @Test(arguments: ["access", "prepare", "capture"])
    func aFailedStepIsShownAndAttachesNothing(step: String) async {
        let (attachments, usb) = make()
        usb.failing = [step]
        await toggle(attachments, usb)
        #expect(usb.steps.last == step)
        #expect(usb.presented == [step])
        #expect(attachments.attached?["usb1"] == nil)
        #expect(!attachments.isPending)
    }

    @Test(arguments: ["access", "prepare"])
    func stoppingMidwayEndsQuietly(step: String) async {
        let (attachments, usb) = make()
        usb.stopsAt = step
        await toggle(attachments, usb)
        #expect(usb.steps.last == step)
        #expect(usb.presented.isEmpty)
        #expect(attachments.attached?["usb1"] == nil)
    }

    @Test func choosingAnAttachedDeviceDisconnectsIt() async {
        let (attachments, usb) = make()
        await toggle(attachments, usb)
        usb.steps = []
        await toggle(attachments, usb)
        #expect(usb.steps == ["disconnect"])
        #expect(attachments.attached == [:])
    }

    @Test func aFailedDisconnectKeepsTheDevice() async {
        let (attachments, usb) = make()
        await toggle(attachments, usb)
        usb.failing = ["disconnect"]
        await toggle(attachments, usb)
        #expect(attachments.attached == ["usb1": "Stick"])
        #expect(usb.presented == ["disconnect"])
    }

    @Test func aResetDropsWhatAnOperationWouldRecord() async throws {
        let (attachments, usb) = make()
        await toggle(attachments, usb)
        attachments.reset()
        #expect(attachments.attached == nil)
        try await attachments.disconnect(identifier: "usb1", host: usb)
        #expect(attachments.attached == nil)
    }

    @Test func anAutomatedConnectNeedsConfirmationAndNeverForces() async throws {
        let (attachments, usb) = make()
        usb.storageResult.hasMountedVolumes = true
        await #expect(throws: USBConnectionError.unmountNotConfirmed) {
            try await attachments.connect(identifier: "usb1", name: "Stick", confirmedUnmount: false, host: usb)
        }
        #expect(usb.steps == ["storage"])

        usb.steps = []
        usb.failing = ["release"]
        await #expect(throws: FakeUSB.Failure(step: "release")) {
            try await attachments.connect(identifier: "usb1", name: "Stick", confirmedUnmount: true, host: usb)
        }
        #expect(usb.steps == ["storage", "access", "release"])

        usb.steps = []
        usb.failing = []
        try await attachments.connect(identifier: "usb1", name: "Stick", confirmedUnmount: true, host: usb)
        #expect(usb.steps == ["storage", "access", "release", "prepare", "capture"])
        #expect(attachments.attached == ["usb1": "Stick"])
    }

    @Test func anAutomatedConnectSaysWhenTheMachineStopped() async {
        let (attachments, usb) = make()
        usb.stopsAt = "access"
        await #expect(throws: USBConnectionError.stopped) {
            try await attachments.connect(identifier: "usb1", name: "Stick", confirmedUnmount: false, host: usb)
        }
    }
}

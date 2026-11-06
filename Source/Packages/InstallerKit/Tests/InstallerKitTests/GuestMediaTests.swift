import Foundation
import Testing

@testable import InstallerKit

/// The per-guest lists VIMInstallerAssembly.m used to spell out, kept here literally so a change has to be deliberate.
@Suite struct GuestMediaTests {
    @Test func applicationNames() {
        let names: [Guest: String] = [
            .tiger: "Install Mac OS X.app", .leopard: "Install Mac OS X.app", .snowLeopard: "Install Mac OS X.app",
            .lion: "Install Mac OS X Lion.app", .mountainLion: "Install OS X Mountain Lion.app",
            .mavericks: "Install OS X Mavericks.app", .yosemite: "Install OS X Yosemite.app",
            .elCapitan: "Install OS X El Capitan.app", .sierra: "Install macOS Sierra.app",
            .highSierra: "Install macOS High Sierra.app", .mojave: "Install macOS Mojave.app",
            .catalina: "Install macOS Catalina.app", .bigSur: "Install macOS Big Sur.app"
        ]
        #expect(names.count == Guest.allCases.count)
        for (guest, name) in names { #expect(guest.installerApplicationName == name) }
    }

    @Test func onlySierraNamesItsPackageDifferently() {
        #expect(Guest.sierra.diskImagePackageName == "InstallOS.pkg")
        for guest in [Guest.lion, .mountainLion, .yosemite, .elCapitan] {
            #expect(guest.diskImagePackageName == "InstallMacOSX.pkg")
        }
    }

    @Test func guestsAssembledFromADiskImageAreExactlyThoseWithAPackageName() {
        for guest in Guest.allCases {
            #expect((guest.diskImagePackageName != nil) == (guest.recipe == .installerDMG), "\(guest)")
        }
    }

    @Test func restoreDiscLayoutMatchesTheTrait() {
        for guest in Guest.allCases {
            let isDisc = if case .restoreDisc = guest.mediaLayout { true } else { false }
            #expect(isDisc == guest.traits.contains(.restoreDVD), "\(guest)")
            #expect(isDisc == (guest.recipe == .restoreDVD), "\(guest)")
        }
    }

    @Test func classicGuests() {
        let classic: Set<Guest> = [
            .tiger, .leopard, .snowLeopard, .lion, .mountainLion, .mavericks, .yosemite, .elCapitan, .sierra,
            .highSierra
        ]
        #expect(Set(Guest.allCases.filter(\.mediaLayout.bootsCDISInstaller)) == classic)
    }

    /// Tiger is classic but has no bootstrap.
    @Test func bootstrappedGuestsAreClassicWithoutTiger() {
        let bootstrapped: Set<Guest> = [
            .leopard, .snowLeopard, .lion, .mountainLion, .mavericks, .yosemite, .elCapitan, .sierra, .highSierra
        ]
        #expect(Set(Guest.allCases.filter(\.recoveryAutomation.usesBootstrap)) == bootstrapped)
    }

    @Test func nativeAndSerialGuests() {
        #expect(
            Set(Guest.allCases.filter(\.recoveryAutomation.usesNativeInstaller)) == [
                .yosemite, .elCapitan, .sierra, .highSierra
            ])
        #expect(Set(Guest.allCases.filter { $0.recoveryAutomation == .serialAgent }) == [.mojave, .catalina])
    }

    @Test func onlyHighSierraCarriesInstallerImages() {
        #expect(Guest.allCases.filter { $0.mediaLayout == .installerImages } == [.highSierra])
    }

    @Test func onlyBigSurIsAHybridImage() {
        #expect(Guest.allCases.filter { $0.mediaLayout == .hybridImage } == [.bigSur])
        #expect(GuestMediaPlanBridge.plan(guest: "bigsur")?.usesRecoveryMedia == false)
        #expect(Guest.allCases.filter { $0.mediaLayout.workingCapacity == nil } == [.bigSur])
    }

    @Test func workingCapacities() {
        #expect(Guest.leopard.mediaLayout.workingCapacity == "10g")
        #expect(Guest.lion.mediaLayout.workingCapacity == "8g")
        #expect(Guest.highSierra.mediaLayout.workingCapacity == "8g")
        #expect(Guest.mojave.mediaLayout.workingCapacity == "16g")
    }

    /// Yosemite and later keep BaseSystem at the volume root, as a nested one gives "Undefined error: 0".
    @Test func baseSystemLocations() {
        #expect(Guest.mavericks.recoveryAutomation.baseSystemDirectory == "System/Installation")
        #expect(Guest.yosemite.recoveryAutomation.baseSystemDirectory == "")
        #expect(Guest.highSierra.recoveryAutomation.baseSystemDirectory == "")
    }

    @Test func scratchRequirementsInGiB() {
        #expect(ScratchRequirement.assembly == 16 * 1024 * 1024 * 1024)
        #expect(ScratchRequirement.recoveryMedia == 24 * 1024 * 1024 * 1024)
        #expect(ScratchRequirement.hybridMedia == 32 * 1024 * 1024 * 1024)
    }

    @Test func routesCoverEveryGuest() throws {
        let routes: [String: AssemblyRoute] = [
            "tiger": .restoreDisc, "leopard": .restoreDisc, "snowleopard": .restoreDisc, "lion": .classicDiskImage,
            "mountainlion": .classicDiskImage, "mavericks": .recoveryESD, "yosemite": .classicDiskImage,
            "elcapitan": .classicDiskImage, "sierra": .classicDiskImage, "highsierra": .splitPackages,
            "mojave": .splitPackages, "catalina": .splitPackages, "bigsur": .assistantPackage
        ]
        #expect(routes.count == Guest.allCases.count)
        for (guest, route) in routes {
            #expect(try #require(GuestMediaPlanBridge.plan(guest: guest)).route == route, "\(guest)")
        }
    }

    @Test(arguments: [nil, "", "Tiger", "windows", "../tiger"]) func anUnknownGuestHasNoPlan(_ guest: String?) {
        #expect(GuestMediaPlanBridge.plan(guest: guest) == nil)
    }
}

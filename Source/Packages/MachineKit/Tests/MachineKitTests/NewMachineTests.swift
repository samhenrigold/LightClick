import Foundation
import InstallerKit
import Testing

@testable import MachineKit

@Suite struct NewMachineFormTests {
    private let host = HostCapacity(physicalMemoryBytes: 32 << 30, processorCount: 10)

    private func form(name: String = "Lion", cores: String = "4", memory: String = "4", disk: String = "64")
        -> NewMachineForm
    {
        NewMachineForm(name: name, cores: cores, memory: memory, disk: disk)
    }

    private func issue(in form: NewMachineForm, host: HostCapacity? = nil) -> CreationIssue? {
        do {
            _ = try form.validated(for: host ?? self.host)
            return nil
        } catch {
            return error
        }
    }

    @Test func onlyAnotherGuestStartsTheConfigurationPageOver() {
        #expect(NewMachineDefaults.pageFill(pageGuest: nil, jobGuest: nil, guest: .lion) == .defaults)
        #expect(NewMachineDefaults.pageFill(pageGuest: .lion, jobGuest: nil, guest: .lion) == .keep)
        #expect(NewMachineDefaults.pageFill(pageGuest: .lion, jobGuest: nil, guest: .mojave) == .defaults)
        #expect(NewMachineDefaults.pageFill(pageGuest: .tiger, jobGuest: .lion, guest: .mojave) == .defaults)
    }

    @Test func comingBackToASavedJobsGuestBringsTheJobBack() {
        #expect(NewMachineDefaults.pageFill(pageGuest: .mojave, jobGuest: .lion, guest: .lion) == .job)
        #expect(
            NewMachineDefaults.pageFill(pageGuest: nil, jobGuest: .lion, guest: .lion) == .job, "A reopened window.")
        #expect(NewMachineDefaults.pageFill(pageGuest: .lion, jobGuest: .lion, guest: .lion) == .keep)
    }

    @Test func hostLimitsLeaveMemoryAndCapAt64() {
        #expect(host.maximumCores == 10)
        #expect(host.maximumMemoryGiB == 31)
        let big = HostCapacity(physicalMemoryBytes: 256 << 30, processorCount: 128)
        #expect(big.maximumCores == 64)
        #expect(big.maximumMemoryGiB == 64)
        #expect(HostCapacity(physicalMemoryBytes: 1 << 30, processorCount: 1).maximumMemoryGiB == 1)
    }

    @Test(arguments: [("4", 4), (" 4 ", 4), ("+4", 4), ("4\n", 4)])
    func wholeNumbersReadAsNSScannerDid(text: String, value: Int) {
        #expect(NewMachineForm.wholeNumber(text, in: 1...64) == value)
    }

    @Test(arguments: ["", "4.5", "4x", "x", "-1", "0", "65", "99999999999999999999999"])
    func anythingElseIsNotAWholeNumberInRange(text: String) {
        #expect(NewMachineForm.wholeNumber(text, in: 1...64) == nil)
    }

    @Test func aValidFormGivesTheTrimmedMachine() throws {
        let machine = try form(name: "  My Mac\n", cores: "2", memory: "8", disk: "2048").validated(for: host)
        #expect(machine == NewMachineSpecification(name: "My Mac", cores: 2, memoryGiB: 8, diskGiB: 2048))
    }

    @Test func eachFieldHasItsMessage() {
        #expect(
            issue(in: form(cores: "0"))
                == CreationIssue(
                    title: "Enter a valid number of cores", detail: "You can assign between 1 and 10 cores to Lion."))
        #expect(
            issue(in: form(memory: "32"))
                == CreationIssue(
                    title: "Enter a valid amount of memory",
                    detail: "You can assign between 1 and 31 GB of memory to Lion. Leave memory available for macOS "
                        + "and graphics processing."))
        #expect(
            issue(in: form(disk: "39"))
                == CreationIssue(
                    title: "Enter a valid storage size",
                    detail: "You can assign between 40 and 2048 GB of storage to Lion."))
        #expect(
            issue(in: form(name: " \n"))
                == CreationIssue(
                    title: "Enter a name for your Mac",
                    detail: "Give this virtual Mac a name so you can find it in your library."))
    }

    @Test func numbersAreCheckedBeforeTheName() {
        #expect(
            issue(in: form(name: "", cores: "x"))?.detail
                == "You can assign between 1 and 10 cores to this virtual Mac.")
        #expect(issue(in: form(name: "", disk: "x"))?.title == "Enter a valid storage size")
    }

    @Test func aOneGibibyteHostCannotGiveItAll() {
        let issue = issue(
            in: form(cores: "1", memory: "1"), host: HostCapacity(physicalMemoryBytes: 1 << 30, processorCount: 1))
        #expect(issue?.title == "Your Mac couldn’t be set up")
        #expect(issue?.detail.hasPrefix("Leave memory available for this Mac.") == true)
    }

    @Test func defaultsFollowTheHostAndVolume() {
        let defaults = NewMachineDefaults(guest: .snowLeopard, host: host, volumeBytes: 256 << 30, freeBytes: 96 << 30)
        #expect(defaults.name == "Snow Leopard")
        #expect(defaults.cores == 4)
        #expect(defaults.memoryGiB == 4)
        #expect(defaults.diskGiB == 128)
        let small = HostCapacity(physicalMemoryBytes: 4 << 30, processorCount: 2)
        #expect(NewMachineDefaults(guest: .lion, host: small, volumeBytes: nil, freeBytes: nil).cores == 2)
        #expect(NewMachineDefaults(guest: .lion, host: small, volumeBytes: nil, freeBytes: nil).memoryGiB == 3)
        #expect(NewMachineDefaults(guest: .lion, host: small, volumeBytes: nil, freeBytes: nil).diskGiB == 64)
        #expect(NewMachineDefaults(guest: .lion, host: host, volumeBytes: 1 << 40, freeBytes: 95 << 30).diskGiB == 64)
    }

    @Test func aGeneratedNameFollowsTheGuestAndATypedOneStays() {
        #expect(NewMachineDefaults.name("", afterSwitchingTo: .lion) == "Lion")
        #expect(NewMachineDefaults.name("Big Sur", afterSwitchingTo: .lion) == "Lion")
        #expect(NewMachineDefaults.name("macOS Mojave", afterSwitchingTo: .tiger) == "Tiger")
        #expect(NewMachineDefaults.name("Work Mac", afterSwitchingTo: .lion) == "Work Mac")
    }
}

@Suite struct CreationJobTests {
    private func job(_ guest: Guest = .mojave) -> CreationJob {
        CreationJob(identifier: "4A2C6B9E-8F4E-4A70-B1C9-111111111111", library: "/Library Root", guest: guest)
    }

    /// The exact shape VIMCreationJob has always had, including integers and real Booleans.
    @Test func itKeepsThePreferencesShape() throws {
        var job = job()
        job.apply(NewMachineSpecification(name: "Mojave", cores: 4, memoryGiB: 8, diskGiB: 64))
        job.automaticSetup = AutomaticSetupProfile(
            username: "sam", fileSharing: true, remoteLogin: false, automaticLogin: true,
            credentialIdentifier: job.identifier)
        job.sourceInstaller = "/a.app"
        job.preparedInstaller = "/a.app"
        job.media = "/m.dmg"
        job.machine = "/Mojave.vintelmac"
        job.phase = .failed
        job.progress = 0.25
        let list = job.propertyList as NSDictionary
        let expected: NSDictionary = [
            "Identifier": job.identifier, "Library": "/Library Root", "Guest": "mojave", "Name": "Mojave", "CPU": 4,
            "Memory": 8, "Disk": 64, "SourceInstaller": "/a.app", "PreparedInstaller": "/a.app", "Media": "/m.dmg",
            "Machine": "/Mojave.vintelmac", "Phase": "failed", "Progress": 0.25,
            "AutomaticSetup": [
                "FormatVersion": 1, "Enabled": true, "Username": "sam", "FileSharing": true, "RemoteLogin": false,
                "AutomaticLogin": true, "CredentialIdentifier": job.identifier
            ] as NSDictionary
        ]
        #expect(list == expected)
        let setup = try #require(list["AutomaticSetup"] as? NSDictionary)
        #expect(setup["Enabled"] as? NSNumber === kCFBooleanTrue)
        for key in ["FileSharing", "RemoteLogin", "AutomaticLogin"] {
            #expect(CFGetTypeID(setup[key] as CFTypeRef) == CFNumberGetTypeID(), "\(key) is saved as an integer")
        }
        #expect((setup["RemoteLogin"] as? NSNumber)?.intValue == 0)
        #expect(CFNumberIsFloatType(list["CPU"] as! CFNumber) == false)
        #expect(PropertyListSerialization.propertyList(job.propertyList, isValidFor: .binary))
    }

    @Test func aFreshJobWritesOnlyWhatItKnows() {
        #expect(Set(job().propertyList.keys) == ["Identifier", "Library", "Guest"])
    }

    @Test func itRoundTrips() throws {
        var job = job(.tiger)
        job.cores = 2
        job.phase = .stopping
        job.automaticSetup = AutomaticSetupProfile(
            username: "sam", fileSharing: false, remoteLogin: true, automaticLogin: false, credentialIdentifier: "id")
        let back = try #require(CreationJob(propertyList: job.propertyList))
        #expect(back.propertyList as NSDictionary == job.propertyList as NSDictionary)
    }

    @Test func anOldProfileStaysWithoutAutomaticLogin() throws {
        let saved: [String: Any] = [
            "Library": "/L", "Guest": "lion", "Identifier": "x",
            "AutomaticSetup": ["FormatVersion": 1, "Enabled": true, "Username": "a", "FileSharing": 1, "RemoteLogin": 0]
        ]
        let job = try #require(CreationJob(propertyList: saved))
        #expect(job.automaticSetup?.automaticLogin == nil)
        #expect(job.automaticSetup?.propertyList["AutomaticLogin"] == nil)
    }

    @Test func untrustedPreferencesCannotMakeAJob() {
        #expect(CreationJob(propertyList: ["Guest": "lion"]) == nil)
        #expect(CreationJob(propertyList: ["Library": "/L"]) == nil)
        #expect(CreationJob(propertyList: ["Library": 1, "Guest": "lion"]) == nil)
        #expect(CreationJob(propertyList: ["Library": "/L", "Guest": "beos"]) == nil)
        let odd = CreationJob(propertyList: [
            "Library": "/L", "Guest": "lion", "CPU": "four", "Phase": "dancing", "AutomaticSetup": 1
        ])
        #expect(odd?.cores == nil && odd?.phase == nil && odd?.automaticSetup == nil)
        #expect(odd?.identifier.isEmpty == false)
    }

    @Test func theStoreKeepsEachSlotApart() throws {
        let suite = "NewMachineTests-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = CreationJobStore(preferences: preferences)
        store.save(job(.lion), to: .installerDownload)
        #expect(store.load(.creation) == nil)
        #expect(preferences.dictionary(forKey: "VIMInstallerDownloadJob")?["Guest"] as? String == "lion")
        store.save(job(.tiger), to: .creation)
        #expect(store.load(.creation)?.guest == .tiger)
        store.remove(.creation)
        #expect(store.load(.creation) == nil)
        #expect(store.load(.installerDownload)?.guest == .lion)
    }

    @Test(arguments: [
        (CreationPhase.downloading, true, "Pause", true), (.preparing, true, "Pause", true),
        (.creating, true, "Pause", false), (.stopping, true, "Pause", false), (.paused, false, "Resume", true),
        (.failed, false, "Try Again", true), (.downloaded, false, "Resume", true)
    ])
    func phasesDecideTheControls(phase: CreationPhase, busy: Bool, title: String, controllable: Bool) {
        #expect(phase.isBusy == busy)
        #expect(phase.pauseButtonTitle == title)
        #expect(phase.allowsPauseAndCancel == controllable)
    }

    @Test func theChosenInstallerGoesWhereItsKindBelongs() {
        var modern = job(.mojave)
        modern.media = "/old.dmg"
        modern.useInstaller(URL(fileURLWithPath: "/Install.APP"))
        #expect(modern.sourceInstaller == "/Install.APP" && modern.media == nil)
        modern.useInstaller(URL(fileURLWithPath: "/ready.dmg"))
        #expect(modern.media == "/ready.dmg" && modern.sourceInstaller == nil)
        var classic = job(.tiger)
        classic.useInstaller(URL(fileURLWithPath: "/Tiger.dmg"))
        #expect(classic.sourceInstaller == "/Tiger.dmg" && classic.media == nil)
        classic.useInstaller(URL(fileURLWithPath: "/Tiger.iso"))
        #expect(classic.media == "/Tiger.iso" && classic.sourceInstaller == nil)
    }

    @Test func spaceDependsOnGuestAndWhatsReady() {
        #expect(job(.mojave).requiredFreeBytes == 44 << 30)
        #expect(job(.bigSur).requiredFreeBytes == 64 << 30)
        var ready = job(.mojave)
        ready.media = "/m"
        #expect(ready.requiredFreeBytes == 22 << 30)
        var readyBigSur = job(.bigSur)
        readyBigSur.media = "/m"
        #expect(readyBigSur.requiredFreeBytes == 28 << 30)
        #expect(job(.mojave).spaceIssue(freeBytes: 44 << 30) == nil)
        let issue = job(.mojave).spaceIssue(freeBytes: (44 << 30) - 1)
        #expect(issue?.title == "Your Mac couldn’t be set up")
        #expect(issue?.detail.hasPrefix("Your library drive needs at least ") == true)
        #expect(issue?.detail.hasSuffix(" available for this disk and installer preparation.") == true)
        var created = job(.mojave)
        created.machine = "/M"
        #expect(created.spaceIssue(freeBytes: 0) == nil)
    }

    @Test func theNextStepIsTheFurthestThingStillTrue() {
        var job = job()
        #expect(job.nextStep { _ in true } == .download)
        job.sourceInstaller = "/a.app"
        #expect(job.nextStep { _ in true } == .prepareMedia(installer: URL(fileURLWithPath: "/a.app")))
        job.media = "/m.dmg"
        #expect(job.nextStep { _ in false } == .prepareMedia(installer: URL(fileURLWithPath: "/a.app")))
        #expect(job.nextStep { _ in true } == .createMachine(media: URL(fileURLWithPath: "/m.dmg")))
        job.machine = "/M.vintelmac"
        #expect(job.nextStep { _ in false } == .openMachine(URL(fileURLWithPath: "/M.vintelmac")))
    }

    @Test func machineSettingsConvertMemory() {
        var job = job()
        job.memoryGiB = 8
        job.cores = 2
        #expect(job.machineSettings as NSDictionary == ["CPUCount": 2, "MemoryMiB": 8192] as NSDictionary)
    }
}

@Suite struct InstallerDownloadTallyTests {
    private static func file(_ role: InstallerFile.Role) throws -> InstallerFile {
        try #require(Self.catalog.file(for: .mojave, role: role))
    }

    /// Mojave has one of each of the three roles a split-legacy download weighs.
    private static let catalog: InstallerCatalog = {
        let installers = Guest.allCases.map { guest -> [String: Any] in
            let files: [[String: Any]] =
                switch guest.recipe {
                case .splitLegacy, .assistantPackage:
                    guest == .mojave
                        ? ["assistant", "recovery", "esd"].map {
                            ["Role": $0, "URL": "https://swcdn.apple.com/content/downloads/\($0).pkg"]
                        }
                        : guest.recipe.roles.map {
                            ["Role": $0.rawValue, "URL": "https://swcdn.apple.com/content/downloads/\(guest)\($0).pkg"]
                        }
                case .restoreDVD: [["Role": "diskimage", "URL": "https://archive.org/download/\(guest)/x.dmg"]]
                case .installerDMG:
                    [["Role": "diskimage", "URL": "https://updates.cdn-apple.com/\(guest)/InstallOS.dmg"]]
                case .recoveryESD:
                    [
                        [
                            "Role": "esd", "URL": "http://oscdn.apple.com/content/downloads/InstallESD.dmg",
                            "SHA256": String(repeating: "a", count: 64)
                        ]
                    ]
                }
            return [
                "Guest": guest.rawValue, "Name": guest.name, "Version": guest.version,
                "Assembly": guest.recipe.rawValue, "Files": files
            ]
        }
        let plist: [String: Any] = ["FormatVersion": 1, "Revision": 1, "Installers": installers]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return try! InstallerCatalog(data: data)
    }()

    private func tally() throws -> InstallerDownloadTally {
        try InstallerDownloadTally(files: [.assistant, .recovery, .esd].map(Self.file))
    }

    @Test func theRateAveragesAndRestarts() {
        var rate = TransferRate()
        rate.record(received: 100, at: 10)
        #expect(rate.bytesPerSecond == 0)
        rate.record(received: 200, at: 10.25)
        #expect(rate.bytesPerSecond == 0)
        rate.record(received: 1100, at: 11)
        #expect(rate.bytesPerSecond == 1000)
        rate.record(received: 3100, at: 12)
        #expect(abs(rate.bytesPerSecond - (0.7 * 1000 + 0.3 * 2000)) < 0.0001)
        rate.record(received: 0, at: 13)
        #expect(rate.bytesPerSecond == 0)
    }

    /// The fixture and wording from the original previews' assertion.
    @Test func theDetailReadsWithFixedDecimals() throws {
        var tally = try tally()
        #expect(tally.detail == "0.00 GB downloaded (Calculating speed…) - Estimating time remaining…")
        let urls = try [InstallerFile.Role.assistant, .recovery, .esd].map { try Self.file($0).url }
        tally.setLength(5_400_000_000, of: urls[2])
        tally.record(received: 200_000_000, total: 200_000_000, of: urls[0], at: 1)
        tally.record(received: 800_000_000, total: 800_000_000, of: urls[1], at: 1)
        tally.record(received: 136_000_000, total: 5_400_000_000, of: urls[2], at: 2)
        tally.record(received: 200_000_000, total: 5_400_000_000, of: urls[2], at: 3)
        #expect(tally.detail == "1.20 GB of 6.40 GB (64.00 MB/s) - 2 minutes remaining")
    }

    @Test func theRemainingTimeHasItsUnits() throws {
        let url = try Self.file(.esd).url
        func remaining(total: Int64, received: Int64, perSecond: Int64) throws -> String {
            var tally = InstallerDownloadTally(files: [try Self.file(.esd)])
            tally.record(received: 0, total: total, of: url, at: 1)
            tally.record(received: perSecond, total: total, of: url, at: 2)
            tally.record(received: received, total: total, of: url, at: 2.25)
            return try #require(tally.detail.components(separatedBy: " - ").last)
        }
        #expect(try remaining(total: 1000, received: 900, perSecond: 100) == "1 minute remaining")
        #expect(try remaining(total: 120_000, received: 100, perSecond: 100) == "20 minutes remaining")
        #expect(try remaining(total: 360_100, received: 100, perSecond: 100) == "1 hour remaining")
        #expect(try remaining(total: 366_100, received: 100, perSecond: 100) == "1 hour 1 minute remaining")
        #expect(try remaining(total: 1_500_100, received: 100, perSecond: 100) == "4 hours 10 minutes remaining")
        #expect(try remaining(total: 1000, received: 1000, perSecond: 100) == "Download complete")
    }

    @Test func movingToTheNextFileDoesNotRewindTheBar() throws {
        var tally = try tally()
        #expect(tally.overallFraction(ofCurrentFile: 0) == 0)
        tally.finishCurrentFile(size: nil)
        let endOfRecovery: Double = {
            var copy = tally
            let value = copy.overallFraction(ofCurrentFile: 1)
            copy.finishCurrentFile(size: nil)
            #expect(abs(value - copy.overallFraction(ofCurrentFile: 0)) < 0.000001)
            return value
        }()
        #expect(abs(endOfRecovery - 0.7 * 0.13) < 0.000001)
        tally.finishCurrentFile(size: nil)
        #expect(abs(tally.overallFraction(ofCurrentFile: 1) - 0.7) < 0.000001)
        tally.finishCurrentFile(size: 10)
        #expect(tally.currentFile == nil)
        #expect(abs(tally.overallFraction(ofCurrentFile: 0) - 0.7) < 0.000001)
    }

    @Test func aFinishedFileCountsItsRealSize() throws {
        var tally = InstallerDownloadTally(files: [try Self.file(.esd)])
        tally.finishCurrentFile(size: 2_000_000_000)
        #expect(tally.detail == "2.00 GB of 2.00 GB (Calculating speed…) - Download complete")
    }

    @Test func theBarOnlyMovesForwardAndWithinBounds() {
        var progress = SetupProgress(fraction: 0.34)
        progress.advance(to: 0.2)
        #expect(progress.fraction == 0.34)
        progress.advance(to: 2)
        #expect(progress.fraction == 1)
        var preparing = SetupProgress()
        preparing.advance(toPreparation: 0.5)
        #expect(abs(preparing.fraction - 0.85) < 0.000001)
        #expect(!preparing.needsSaving(over: 0.847))
        #expect(preparing.needsSaving(over: 0.84))
        #expect(preparing.needsSaving(over: nil))
    }

    @Test func aDownloadDirectoryIsTheSHA256OfItsURL() {
        let directory = LibraryLayout.downloadDirectory(
            for: URL(string: "https://example.com/a.dmg")!, library: URL(fileURLWithPath: "/Lib"))
        // shasum -a 256 of the URL's absolute string, lowercase, as the Objective-C spelled it.
        #expect(directory.deletingLastPathComponent().path == "/Lib/Downloads")
        #expect(directory.lastPathComponent == "9b0719a7a9ead41e4527e8918688010b15e01a4682ff84764e050484fc95130c")
    }

    @Test func aJournalLengthCountsOnlyForItsOwnTransfer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(string: "https://example.com/a.dmg")!
        #expect(InstallerLength.recorded(inDirectory: directory, source: source) == nil)
        func write(_ journal: NSDictionary) throws {
            try journal.write(to: directory.appendingPathComponent("Download.plist"))
        }
        try write(["SourceURL": source.absoluteString, "Length": 42])
        #expect(InstallerLength.recorded(inDirectory: directory, source: source) == 42)
        try write(["SourceURL": "https://example.com/b.dmg", "Length": 42])
        #expect(InstallerLength.recorded(inDirectory: directory, source: source) == nil)
        try write(["SourceURL": source.absoluteString, "Length": -1])
        #expect(InstallerLength.recorded(inDirectory: directory, source: source) == nil)
        try write(["SourceURL": source.absoluteString, "Length": "42"])
        #expect(InstallerLength.recorded(inDirectory: directory, source: source) == nil)
    }

    @Test func aProbedLengthMustBePlausible() {
        #expect(InstallerLength.probed(statusCode: 200, expectedContentLength: 5) == 5)
        #expect(InstallerLength.probed(statusCode: 200, expectedContentLength: 100 << 30) == 100 << 30)
        #expect(InstallerLength.probed(statusCode: 200, expectedContentLength: (100 << 30) + 1) == nil)
        #expect(InstallerLength.probed(statusCode: 200, expectedContentLength: -1) == nil)
        #expect(InstallerLength.probed(statusCode: 206, expectedContentLength: 5) == nil)
    }
}

@Suite struct SetupCopyTests {
    private func job(_ guest: Guest, source: String? = nil, automatic: Bool = false) -> CreationJob {
        var job = CreationJob(library: "/L", guest: guest)
        job.sourceInstaller = source
        if automatic {
            job.automaticSetup = AutomaticSetupProfile(
                username: "a", fileSharing: true, remoteLogin: true, automaticLogin: true, credentialIdentifier: "x")
        }
        return job
    }

    @Test func titlesNameTheSystem() {
        #expect(SetupCopy.progressTitle(.bigSur, usingExistingInstaller: false) == "Downloading\nmacOS Big Sur")
        #expect(
            SetupCopy.progressTitle(.snowLeopard, usingExistingInstaller: true) == "Preparing\nMac OS X Snow Leopard")
        #expect(SetupCopy.progressTitle(.mavericks, usingExistingInstaller: false) == "Downloading\nOS X Mavericks")
        #expect(SetupCopy.downloading(.mountainLion) == "Downloading OS X…")
    }

    @Test func theIntroDependsOnSourceAndAutomation() {
        #expect(
            SetupCopy.progressIntro(job(.mojave, automatic: true))
                == "We’ll download macOS from Apple and prepare its installer. Your virtual Mac will install and set "
                + "itself up automatically. Installation may take up to 2 hours.")
        #expect(
            SetupCopy.progressIntro(job(.tiger))
                == "We’ll download Mac OS X Tiger from the Internet Archive and prepare its installer. When the "
                + "installer opens, follow the onscreen instructions and install on Macintosh HD. Installation may "
                + "take up to 2 hours.")
        #expect(
            SetupCopy.progressIntro(job(.lion, source: "/a.app"))
                == "We’ll prepare your Mac OS X installer. When Mac OS X Utilities appears, choose Reinstall Mac OS X "
                + "and install on Macintosh HD. Installation may take up to 2 hours.")
    }

    @Test func thePreparationFailureHasFallbacks() {
        #expect(
            SetupCopy.preparationFailure(description: nil, recoverySuggestion: nil)
                == CreationIssue(
                    title: "The installer couldn’t be prepared",
                    detail: "Preparation could not finish.\n\nYour downloads are saved. Try again to resume setup."))
        #expect(
            SetupCopy.preparationFailure(description: "Bad.", recoverySuggestion: "Retry.").detail == "Bad.\n\nRetry.")
    }

    @Test func minutesAreRoundedUp() {
        #expect(SetupCopy.preparationRemaining(seconds: 0) == "About 1 minute remaining")
        #expect(SetupCopy.preparationRemaining(seconds: 61) == "About 2 minutes remaining")
    }

    @Test func theArchiveFailureNamesTheFile() {
        #expect(
            SetupCopy.archiveFailureTitle(.leopard) == "Unable to Download Mac OS X Leopard from the Internet Archive")
        let detail = SetupCopy.archiveFailureDetail(.leopard, filename: "L.dmg")
        #expect(detail.contains("Download L.dmg using a connection"))
        #expect(detail.contains("\n\nYou can also install Mac OS X Lion 10.7 or later instead,"))
    }
}

@Suite struct GuestChoicesTests {
    @Test func arrowsWalkTheTwoColumns() {
        let count = Guest.allCases.count + 1
        #expect(count == 14)
        #expect(GuestGrid.index(moving: .down, from: 0, count: count) == 1)
        #expect(GuestGrid.index(moving: .down, from: 13, count: count) == 13)
        #expect(GuestGrid.index(moving: .up, from: 0, count: count) == 0)
        #expect(GuestGrid.index(moving: .up, from: 7, count: count) == 6)
        #expect(GuestGrid.index(moving: .right, from: 6, count: count) == 13)
        #expect(GuestGrid.index(moving: .right, from: 7, count: count) == 7)
        #expect(GuestGrid.index(moving: .left, from: 13, count: count) == 6)
        #expect(GuestGrid.index(moving: .left, from: 6, count: count) == 6)
    }

    @Test func theRowTitlesAreTheSystemNames() {
        #expect(
            Guest.allCases.map(\.systemName) == [
                "Mac OS X Tiger 10.4", "Mac OS X Leopard 10.5", "Mac OS X Snow Leopard 10.6", "Mac OS X Lion 10.7",
                "OS X Mountain Lion 10.8", "OS X Mavericks 10.9", "OS X Yosemite 10.10", "OS X El Capitan 10.11",
                "macOS Sierra 10.12", "macOS High Sierra 10.13", "macOS Mojave 10.14", "macOS Catalina 10.15",
                "macOS Big Sur 11"
            ])
    }

    @Test func recommendationsFollowTheHost() {
        let silicon = NewerSystemsRecommendation(appleSilicon: true)
        #expect(silicon.apps.map(\.name) == ["VirtualBuddy", "UTM", "Virtual Mac on iPad"])
        #expect(silicon.closing == ", then run Intel-based apps using Rosetta.")
        #expect((0..<3).map(silicon.separator) == ["", ", ", ", or "])
        let intel = NewerSystemsRecommendation(appleSilicon: false)
        #expect(intel.apps.map(\.name) == ["Parallels Desktop 26"])
        #expect(intel.closing == ".")
        #expect(intel.separator(before: 0) == "")
    }

    @Test func createGuestArgumentsPairUp() {
        let arguments = CreateGuestArguments(arguments: [
            "app", "--create-guest", "lion", "--name", "L", "--cpu", "2", "--memory-gb", "3", "--disk-gb", "40",
            "--account-name", "sam", "--account-password", "p", "--trailing"
        ])
        #expect(arguments.guest == .lion)
        #expect(arguments.name == "L")
        #expect(arguments.cores == "2" && arguments.memory == "3" && arguments.disk == "40")
        #expect(arguments.accountName == "sam" && arguments.accountPassword == "p")
        #expect(CreateGuestArguments(arguments: ["app"]).guest == nil)
        #expect(CreateGuestArguments(arguments: ["app", "--create-guest", "beos"]).guest == nil)
        #expect(CreateGuestArguments.unknownGuestMessage.hasPrefix("Unknown guest. Use one of: tiger, leopard, "))
        #expect(CreateGuestArguments.unknownGuestMessage.hasSuffix(", bigsur."))
    }

    @Test func packagedResourcesPreferTheGuestsFirmwareAndTheCommonBootImage() {
        let runtime = URL(fileURLWithPath: "/R")
        let both = CreationResources(runtime: runtime, guest: .mojave) { _ in true }
        #expect(both.firmware.path == "/R/Firmware/mojave/CODE.fd")
        #expect(both.nvram.path == "/R/Firmware/mojave/VARS.fd")
        #expect(both.bootMedia.path == "/R/Firmware/Common/EFI.img")
        #expect(both.qemuImage.path == "/R/bin/qemu-img")
        let neither = CreationResources(runtime: runtime, guest: .mojave) { _ in false }
        #expect(neither.firmware.path == "/R/Firmware/Common/CODE.fd")
        #expect(neither.bootMedia.path == "/R/Firmware/mojave/EFI.img")
        #expect(both.missingFile { _ in true } == nil)
        #expect(both.missingFile { !$0.hasSuffix("VARS.fd") } == "VARS.fd")
        #expect(both.missingFile { _ in false } == "CODE.fd")
    }

    @Test func developmentResourcesComeFromTheSourceTree() {
        let resources = CreationResources(developmentSourceRoot: URL(fileURLWithPath: "/S"), guest: .tiger)
        #expect(resources.firmware.path == "/S/Build/DevelopmentFirmware/tiger/CODE.fd")
        #expect(resources.nvram.path == "/S/Build/DevelopmentFirmware/tiger/VARS.fd")
        #expect(resources.bootMedia.path == "/S/Build/DevelopmentFirmware/tiger/EFI.img")
        #expect(resources.qemuImage.path == "/S/Build/qemu/build-arm64-pvg/qemu-img")
    }
}

@Suite struct PreparationScratchTests {
    private let root: URL
    private var library: URL { root }
    private var installers: URL { root.appendingPathComponent("Installers") }
    private let manager = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root.appendingPathComponent("Machines"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Installers"), withIntermediateDirectories: true)
    }

    private func attempt(containing file: String = "scratch") throws -> URL {
        let attempt = installers.appendingPathComponent(UUID().uuidString)
        let path = attempt.appendingPathComponent(file)
        try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: path)
        return attempt
    }

    private func remove(jobMedia: String? = nil, jobInstaller: String? = nil) {
        PreparationScratch.removeAbandoned(
            root: installers, library: library, jobMedia: jobMedia, jobInstaller: jobInstaller)
    }

    private func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

    private func machine(_ configuration: NSDictionary?) throws {
        let package = root.appendingPathComponent("Machines/\(UUID().uuidString).vintelmac")
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        try configuration?.write(to: package.appendingPathComponent("Machine.plist"))
    }

    @Test func anUnusedAttemptGoes() throws {
        defer { try? manager.removeItem(at: root) }
        let unused = try attempt()
        remove()
        #expect(!exists(unused))
    }

    @Test func completedProductsAndOtherNamesStay() throws {
        defer { try? manager.removeItem(at: root) }
        let media = try attempt(containing: "Media/Media.plist")
        let assembly = try attempt(containing: "Assembly/Assembly.plist")
        let other = installers.appendingPathComponent("Keep Me")
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        remove()
        #expect(exists(media) && exists(assembly) && exists(other))
    }

    @Test func whatTheJobOrAMachineUsesStays() throws {
        defer { try? manager.removeItem(at: root) }
        let jobMedia = try attempt(containing: "Media/m.dmg")
        let jobInstaller = try attempt(containing: "Assembly/a.app")
        let machineMedia = try attempt(containing: "Media/n.dmg")
        try machine(["InstallerMedia": machineMedia.appendingPathComponent("Media/n.dmg").path])
        let unused = try attempt()
        remove(
            jobMedia: jobMedia.appendingPathComponent("Media/m.dmg").path,
            jobInstaller: jobInstaller.appendingPathComponent("Assembly/a.app").path)
        #expect(exists(jobMedia) && exists(jobInstaller) && exists(machineMedia))
        #expect(!exists(unused))
    }

    @Test func anUnreadableMachineKeepsEverything() throws {
        defer { try? manager.removeItem(at: root) }
        try machine(nil)
        let unused = try attempt()
        remove()
        #expect(exists(unused))
    }

    @Test func anOfflineLibraryKeepsEverything() throws {
        defer { try? manager.removeItem(at: root) }
        try manager.removeItem(at: root.appendingPathComponent("Machines"))
        let unused = try attempt()
        remove()
        #expect(exists(unused))
    }

    @Test func retiringAnAssemblyDemandsItsExactPlace() throws {
        defer { try? manager.removeItem(at: root) }
        let attempt = try attempt(containing: "Assembly/Install.app/Contents")
        let app = attempt.appendingPathComponent("Assembly/Install.app").path
        #expect(!PreparationScratch.retireAssembly(preparedInstaller: app, root: root))
        #expect(PreparationScratch.retireAssembly(preparedInstaller: app, root: installers))
        #expect(!exists(attempt.appendingPathComponent("Assembly")))
        #expect(exists(attempt))
    }

    @Test func aFileOrAStrangerIsNotRetired() throws {
        defer { try? manager.removeItem(at: root) }
        let disc = try attempt(containing: "Assembly/Restore.dmg")
        #expect(
            !PreparationScratch.retireAssembly(
                preparedInstaller: disc.appendingPathComponent("Assembly/Restore.dmg").path, root: installers))
        let wrong = try attempt(containing: "Elsewhere/Install.app/Contents")
        #expect(
            !PreparationScratch.retireAssembly(
                preparedInstaller: wrong.appendingPathComponent("Elsewhere/Install.app").path, root: installers))
        #expect(exists(disc.appendingPathComponent("Assembly/Restore.dmg")))
    }

    @Test func oneLockAtATime() throws {
        defer { try? manager.removeItem(at: root) }
        var first = try #require(PreparationLock(root: installers))
        #expect(PreparationLock(root: installers) == nil)
        first.release()
        var second = try #require(PreparationLock(root: installers))
        second.release()
    }

    @Test func aMissingFolderIsNoLock() throws {
        defer { try? manager.removeItem(at: root) }
        #expect(PreparationLock(root: root.appendingPathComponent("Nope")) == nil)
    }
}

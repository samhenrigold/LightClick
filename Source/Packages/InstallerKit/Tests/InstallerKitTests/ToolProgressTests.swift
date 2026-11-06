import Foundation
import Testing

@testable import InstallerKit

@Suite struct ToolProgressTests {
    /// Existing preferences hold these keys, so a change forgets people's measured durations.
    @Test func timingKeysKeepTheirSpelling() {
        #expect(
            ToolProgress.timingKey(
                guest: "lion", stage: "Reading…", invocation: .detach(mountPoint: "/m"))
                == "VIMPreparationDuration-lion-Reading…-hdiutil-detach")
        #expect(
            ToolProgress.timingKey(guest: "", stage: "", invocation: .copy("/a", to: "/b", timeout: 1))
                == "VIMPreparationDuration---ditto---norsrc")
    }

    @Test func theKeyIgnoresTheLaunchOnlyArgument() {
        let convert = ToolInvocation.convertToBlocks("/w", output: "/o")
        #expect(ToolProgress.timingKey(guest: "g", stage: "s", invocation: convert).hasSuffix("-hdiutil-convert"))
    }

    @Test func reportedFractionsOnlyRise() {
        #expect(ToolProgress.reportedFraction(in: "PERCENT:12.5\nPERCENT:50\n", after: -1) == 0.5)
        #expect(ToolProgress.reportedFraction(in: "PERCENT:10\n", after: 0.5) == 0.5)
        #expect(ToolProgress.reportedFraction(in: "PERCENT:200\n", after: -1) == 1)
        #expect(ToolProgress.reportedFraction(in: "noise\n", after: -1) == -1)
        #expect(ToolProgress.reportedFraction(in: "PERCENT:-1.000000\n", after: -1) == -0.01)
    }

    @Test func aToolsReportDecidesUntilItsNearlyDone() {
        #expect(ToolProgress.fraction(reported: 0.5, elapsed: 999, estimate: 1) == 0.5)
        #expect(ToolProgress.fraction(reported: 1, elapsed: 0, estimate: 1) == 0.99)
        #expect(ToolProgress.fraction(reported: 0, elapsed: 999, estimate: 1) == 0)
    }

    @Test func anEstimateNeverClaimsCompletion() {
        #expect(ToolProgress.fraction(reported: -1, elapsed: 5, estimate: 10) == 0.5)
        let atNinety = ToolProgress.fraction(reported: -1, elapsed: 9, estimate: 10)
        #expect(abs(atNinety - 0.9) < 0.0001)
        #expect(ToolProgress.fraction(reported: -0.01, elapsed: 1_000_000, estimate: 10) <= 0.98)
        #expect(ToolProgress.fraction(reported: -1, elapsed: 20, estimate: 10) < 0.98)
    }

    @Test func remainingTimePrefersTheToolsRate() {
        #expect(ToolProgress.secondsRemaining(reported: 0.5, elapsed: 10, estimate: 99) == 10)
        #expect(ToolProgress.secondsRemaining(reported: 0.005, elapsed: 10, estimate: 30) == 20)
        #expect(ToolProgress.secondsRemaining(reported: 0.5, elapsed: 0.5, estimate: 30) == 29.5)
        #expect(ToolProgress.secondsRemaining(reported: -1, elapsed: 40, estimate: 30) == 1)
    }

    @Test func aDurationIsLearnedAsARunningAverage() {
        #expect(ToolProgress.learnedDuration(previous: 0, measured: 10) == 10)
        #expect(abs(ToolProgress.learnedDuration(previous: 10, measured: 20) - 14) < 0.0001)
    }

    @Test func aToolFailureCarriesItsStatusAndLog() {
        let error = AssemblyFailure.toolFailed(status: 7, log: "/job/01-hdiutil.log")
        #expect(error.domain == "VirtualIntelMac.InstallerAssembly")
        #expect(error.code == 7)
        #expect(error.localizedDescription == "The OS installer couldn’t be prepared.")
        #expect(
            error.localizedRecoverySuggestion
                == "Your downloads are saved. Try again to resume setup. If it fails again, check that your library’s "
                + "drive is connected and has enough free space.")
        #expect(error.userInfo["PreparationLog"] as? String == "/job/01-hdiutil.log")
    }
}

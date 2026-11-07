import Testing

@testable import SeamlessIntegration

@Suite struct WindowSurfaceOriginTests {
    private let sidebar = GuestMaterial(material: 5, active: true, x: 0, y: 0, width: 100, height: 200)

    @Test func anOriginBeforeTheFirstWindowSurvivesUntilSurfaceCreation() {
        var pending = PendingWindowMetadata()
        pending.receiveOrigin(x: 64, y: 252, for: 43)
        // Window creation can consume the capture origin even when no second origin message arrives.
        let metadata = pending.take(43)
        #expect(metadata?.surfaceOrigin?.x == 64)
        #expect(metadata?.surfaceOrigin?.y == 252)
        #expect(metadata?.materials == nil)
        #expect(pending.take(43) == nil)
    }

    @Test func theLatestOriginWinsIncludingZero() {
        var pending = PendingWindowMetadata()
        pending.receiveOrigin(x: -64, y: 252, for: 43)
        pending.receiveOrigin(x: 0, y: 0, for: 43)
        let metadata = pending.take(43)
        #expect(metadata?.surfaceOrigin?.x == 0)
        #expect(metadata?.surfaceOrigin?.y == 0)
    }

    @Test func originAndMaterialUpdatesPreserveEachOther() {
        var pending = PendingWindowMetadata()
        pending.receiveOrigin(x: 64, y: 252, for: 43)
        pending.receive([sidebar], for: 43)
        pending.receiveOrigin(x: 65, y: 253, for: 43)
        pending.receive([], for: 43)
        let metadata = pending.take(43)
        #expect(metadata?.surfaceOrigin?.x == 65)
        #expect(metadata?.surfaceOrigin?.y == 253)
        #expect(metadata?.materials == [])
    }

    @Test func originsAndMaterialsShareTheWindowLimit() {
        var pending = PendingWindowMetadata()
        for id in 0..<PendingWindowMetadata.maximumWindows {
            if id.isMultiple(of: 2) {
                pending.receiveOrigin(x: 64, y: 252, for: UInt32(id))
            } else {
                pending.receive([sidebar], for: UInt32(id))
            }
        }
        pending.receiveOrigin(x: 1, y: 2, for: UInt32.max)
        pending.receive([sidebar], for: UInt32.max)
        #expect(pending.take(UInt32.max) == nil)
        // Adding another field to an existing ID does not require a second slot.
        pending.receiveOrigin(x: 3, y: 4, for: 1)
        let existing = pending.take(1)
        #expect(existing?.materials == [sidebar])
        #expect(existing?.surfaceOrigin?.x == 3)
        pending.receiveOrigin(x: 1, y: 2, for: UInt32.max)
        #expect(pending.take(UInt32.max)?.surfaceOrigin?.y == 2)
    }

    @Test func removalAndSessionResetDiscardOriginsAlongsideMaterials() {
        var pending = PendingWindowMetadata()
        pending.receiveOrigin(x: 64, y: 252, for: 43)
        pending.receive([sidebar], for: 43)
        pending.remove(43)
        #expect(pending.take(43) == nil)
        pending.receiveOrigin(x: 0, y: 0, for: 43)
        pending.receive([sidebar], for: 43)
        pending.reset()
        #expect(pending.take(43) == nil)
    }
}

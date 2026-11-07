import Testing

@testable import SeamlessIntegration

@Suite struct WindowMaterialsTests {
    private let sidebar = GuestMaterial(material: 5, active: true, x: 0, y: 0, width: 100, height: 200)
    private let titlebar = GuestMaterial(material: 25, active: false, x: 0, y: 0, width: 400, height: 22)

    @Test func firstMaterialRowsSurviveUntilTheyAreConsumed() {
        var pending = PendingWindowMetadata()
        pending.receive([sidebar], for: 777)
        // No window/surface exists when the message arrives. Window creation must still be able to take it once.
        let surfaceMaterials = pending.take(777)?.materials
        #expect(surfaceMaterials == [sidebar])
        #expect(pending.take(777) == nil)
    }

    @Test func aNewerPreWindowUpdateReplacesTheOlderOne() {
        var pending = PendingWindowMetadata()
        pending.receive([sidebar], for: 777)
        pending.receive([titlebar], for: 777)
        #expect(pending.take(777)?.materials == [titlebar])
    }

    @Test func anEmptyUpdateClearsMaterialsOnAReusedSuccessorSurface() {
        var pending = PendingWindowMetadata()
        pending.receive([sidebar], for: 778)
        pending.receive([], for: 778)
        var reusedSurfaceMaterials = [titlebar]
        if let received = pending.take(778)?.materials { reusedSurfaceMaterials = received }
        #expect(reusedSurfaceMaterials.isEmpty)
    }

    @Test func aGoneWindowCannotPassItsMaterialsToAReusedID() {
        var pending = PendingWindowMetadata()
        pending.receive([sidebar], for: 777)
        pending.remove(777)
        #expect(pending.take(777) == nil)
        pending.receive([titlebar], for: 777)
        #expect(pending.take(777)?.materials == [titlebar])
    }

    @Test func aStoppedGuestCannotLeakRowsIntoTheNextConnection() {
        var pending = PendingWindowMetadata()
        pending.receive([sidebar], for: 777)
        pending.reset()
        #expect(pending.take(777) == nil)
    }

    @Test func unknownWindowFloodsAreBoundedWithoutLosingAnExistingUpdate() {
        var pending = PendingWindowMetadata()
        for id in 0..<PendingWindowMetadata.maximumWindows { pending.receive([sidebar], for: UInt32(id)) }
        pending.receive([titlebar], for: UInt32.max)
        #expect(pending.take(UInt32.max) == nil)
        pending.receive([titlebar], for: 0)
        #expect(pending.take(0)?.materials == [titlebar])
        // Consuming a surface frees capacity for a genuinely new window.
        pending.receive([sidebar], for: UInt32.max)
        #expect(pending.take(UInt32.max)?.materials == [sidebar])
    }

    @Test func eachPendingWindowAlsoHasABoundedRowCount() {
        var pending = PendingWindowMetadata()
        pending.receive(Array(repeating: sidebar, count: 1000), for: 777)
        #expect(pending.take(777)?.materials?.count == PendingWindowMetadata.maximumRows)
    }
}

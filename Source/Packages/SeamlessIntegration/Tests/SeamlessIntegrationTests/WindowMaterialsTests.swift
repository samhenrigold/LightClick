import Testing

@testable import SeamlessIntegration

@Suite struct WindowMaterialsTests {
    private let sidebar = GuestMaterial(material: 5, active: true, x: 0, y: 0, width: 100, height: 200)
    private let titlebar = GuestMaterial(material: 25, active: false, x: 0, y: 0, width: 400, height: 22)

    @Test func firstMaterialRowsSurviveUntilTheyAreConsumed() {
        var pending = PendingWindowMaterials()
        pending.receive([sidebar], for: 777)
        // No window/surface exists when the message arrives. Window creation must still be able to take it once.
        let surfaceMaterials = pending.take(777)
        #expect(surfaceMaterials == [sidebar])
        #expect(pending.take(777) == nil)
    }

    @Test func aNewerPreWindowUpdateReplacesTheOlderOne() {
        var pending = PendingWindowMaterials()
        pending.receive([sidebar], for: 777)
        pending.receive([titlebar], for: 777)
        #expect(pending.take(777) == [titlebar])
    }

    @Test func anEmptyUpdateClearsMaterialsOnAReusedSuccessorSurface() {
        var pending = PendingWindowMaterials()
        pending.receive([sidebar], for: 778)
        pending.receive([], for: 778)
        var reusedSurfaceMaterials = [titlebar]
        if let received = pending.take(778) { reusedSurfaceMaterials = received }
        #expect(reusedSurfaceMaterials.isEmpty)
    }

    @Test func aGoneWindowCannotPassItsMaterialsToAReusedID() {
        var pending = PendingWindowMaterials()
        pending.receive([sidebar], for: 777)
        pending.remove(777)
        #expect(pending.take(777) == nil)
        pending.receive([titlebar], for: 777)
        #expect(pending.take(777) == [titlebar])
    }

    @Test func aStoppedGuestCannotLeakRowsIntoTheNextConnection() {
        var pending = PendingWindowMaterials()
        pending.receive([sidebar], for: 777)
        pending.reset()
        #expect(pending.take(777) == nil)
    }

    @Test func unknownWindowFloodsAreBoundedWithoutLosingAnExistingUpdate() {
        var pending = PendingWindowMaterials()
        for id in 0..<PendingWindowMaterials.maximumWindows { pending.receive([sidebar], for: UInt32(id)) }
        pending.receive([titlebar], for: UInt32.max)
        #expect(pending.take(UInt32.max) == nil)
        pending.receive([titlebar], for: 0)
        #expect(pending.take(0) == [titlebar])
        // Consuming a surface frees capacity for a genuinely new window.
        pending.receive([sidebar], for: UInt32.max)
        #expect(pending.take(UInt32.max) == [sidebar])
    }

    @Test func eachPendingWindowAlsoHasABoundedRowCount() {
        var pending = PendingWindowMaterials()
        pending.receive(Array(repeating: sidebar, count: 1000), for: 777)
        #expect(pending.take(777)?.count == PendingWindowMaterials.maximumRows)
    }
}

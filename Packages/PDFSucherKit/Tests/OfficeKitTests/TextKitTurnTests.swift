import Foundation
@testable import OfficeKit
import Testing

/// 1.5.1: a display path laying out a document (`.load`) lets go of the TextKit lock for waiting draws, the index layout
/// for any display path; draws never do.
@Suite("TextKit turns", .serialized)
struct TextKitTurnTests {
    @Test func loadStepsAsideOnlyForWaitingDraws() {
        // Other OfficeKit tests use TextKit meanwhile: only what a waiting draw must cause is checked.
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread {
            TextKitWordDocument.withTextKit(.layout) { holding.signal(); release.wait() }
        }.start()
        holding.wait()
        let drew = DispatchSemaphore(value: 0)
        Thread { TextKitWordDocument.withTextKit(.display) {}; drew.signal() }.start()
        Thread.sleep(forTimeInterval: 0.1)                      // the draw now waits at the lock
        #expect(TextKitWordDocument.yields(.load))
        #expect(TextKitWordDocument.yields(.layout))
        #expect(!TextKitWordDocument.yields(.display))
        release.signal()
        drew.wait()
    }
}

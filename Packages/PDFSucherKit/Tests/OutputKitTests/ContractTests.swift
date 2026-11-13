import Testing
import Foundation
import OutputKit // deliberately not @testable: proves the public inits (R6) are visible cross-module

@Suite("OutputKit public contract")
struct OutputKitContractTests {
    @Test func pageRefIsHashableByValue() {
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let refs: Set = [PageRef(url: url, pageIndex: 0), PageRef(url: url, pageIndex: 0), PageRef(url: url, pageIndex: 1)]
        #expect(refs.count == 2)
    }
}

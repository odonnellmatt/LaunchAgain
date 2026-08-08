import XCTest
@testable import MALCore

/// The numbering rule is the one promise the product cannot break: a number belongs to
/// an instance permanently, deleting #2 leaves #3 as #3, and the next instance is #4.
/// These tests exist to make that rule impossible to regress by accident.
final class NumberingTests: XCTestCase {

    func testAllocationStartsAtOneOnAnEmptyApp() {
        let (numbers, next) = NumberAllocator.allocate(count: 3, from: 1)
        XCTAssertEqual(numbers, [1, 2, 3])
        XCTAssertEqual(next, 4)
    }

    /// The rule the user asked for: a number freed by a deletion is handed out again
    /// rather than skipped, so the set of numbers stays tight.
    func testTheLowestFreeNumberIsUsedFirst() {
        let (numbers, _) = NumberAllocator.allocate(count: 1, from: 4, existing: [1, 3])
        XCTAssertEqual(numbers, [2], "deleting #2 should make #2 available again")
    }

    func testGapsAreFilledInOrderBeforeExtendingTheRange() {
        let (numbers, next) = NumberAllocator.allocate(count: 4, from: 6, existing: [1, 3, 5])
        XCTAssertEqual(numbers, [2, 4, 6, 7])
        XCTAssertEqual(next, 8)
    }

    func testAllocationNeverCollidesWithAnExistingNumber() {
        let existing = [1, 2, 3]
        let (numbers, _) = NumberAllocator.allocate(count: 2, from: 1, existing: existing)
        XCTAssertEqual(numbers, [4, 5])
        XCTAssertTrue(Set(numbers).isDisjoint(with: Set(existing)))
    }

    func testCounterIsNeverBelowOne() {
        let (numbers, next) = NumberAllocator.allocate(count: 1, from: 0)
        XCTAssertEqual(numbers, [1])
        XCTAssertEqual(next, 2)

        let (negative, negativeNext) = NumberAllocator.allocate(count: 1, from: -5)
        XCTAssertEqual(negative, [1])
        XCTAssertEqual(negativeNext, 2)
    }

    func testNegativeAndZeroExistingNumbersAreIgnored() {
        let (numbers, _) = NumberAllocator.allocate(count: 2, from: 1, existing: [0, -3, 1])
        XCTAssertEqual(numbers, [2, 3])
    }

    func testAllocatingZeroYieldsNothing() {
        let (numbers, next) = NumberAllocator.allocate(count: 0, from: 4)
        XCTAssertTrue(numbers.isEmpty)
        XCTAssertEqual(next, 4)
    }

    /// A counter restored from an older backup must never hand out a number that an
    /// existing instance already holds.
    func testReconciledCounterRepairsAStaleCounter() {
        XCTAssertEqual(NumberAllocator.reconciledCounter(storedCounter: 1, existingNumbers: [1, 2, 5]), 6)
        XCTAssertEqual(NumberAllocator.reconciledCounter(storedCounter: 9, existingNumbers: [1, 2]), 9)
        XCTAssertEqual(NumberAllocator.reconciledCounter(storedCounter: 0, existingNumbers: []), 1)
    }

    func testRenumberPlanIsOneToNAndOmitsUnchangedEntries() {
        // 1, 3, 4 → 1, 2, 3: only the last two move.
        let plan = NumberAllocator.renumberPlan(existingNumbers: [1, 3, 4])
        XCTAssertEqual(plan, [3: 2, 4: 3])
    }

    func testRenumberPlanIsEmptyWhenAlreadySequential() {
        XCTAssertTrue(NumberAllocator.renumberPlan(existingNumbers: [1, 2, 3]).isEmpty)
        XCTAssertTrue(NumberAllocator.renumberPlan(existingNumbers: []).isEmpty)
    }

    func testValidateRejectsDuplicatesAndNonPositiveNumbers() {
        XCTAssertNoThrow(try NumberAllocator.validate(numbers: [1, 2, 3]))
        XCTAssertThrowsError(try NumberAllocator.validate(numbers: [1, 1]))
        XCTAssertThrowsError(try NumberAllocator.validate(numbers: [0]))
        XCTAssertThrowsError(try NumberAllocator.validate(numbers: [-2]))
    }
}

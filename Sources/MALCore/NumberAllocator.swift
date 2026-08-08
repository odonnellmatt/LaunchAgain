import Foundation

/// Instance numbering.
///
/// The rule, stated once and enforced in exactly one place:
///
///  · An existing instance's number never changes. Deleting #2 leaves #3 as #3, always.
///  · A new instance takes the **lowest number not currently in use**. Delete #2 and the
///    next instance you create is #2, not #4.
///
/// The second half of that is a deliberate change from the original design, which never
/// reused a number. In practice the gaps were the problem: someone with instances 1 and 3
/// and no 2 is looking at a mistake, not at a history. Reuse keeps the set of numbers
/// tight and matches what the badges are for — telling two running apps apart today, not
/// recording what once existed.
///
/// The only operation permitted to change an *existing* number is `renumber`, which the
/// user must invoke explicitly and which rebuilds bundles and icons as one transaction.
public enum NumberAllocator {

    /// Allocates `count` numbers, filling the lowest gaps first.
    ///
    /// `counter` is kept as a high-water mark so a registry restored from an old backup
    /// still moves forward rather than colliding with something it has forgotten about;
    /// `existing` is what decides which numbers are actually free.
    public static func allocate(count: Int,
                                from counter: Int,
                                existing: [Int] = []) -> (numbers: [Int], nextCounter: Int) {
        precondition(count >= 0, "count must be non-negative")
        var used = Set(existing.filter { $0 > 0 })
        var numbers: [Int] = []
        var candidate = 1
        while numbers.count < count {
            if !used.contains(candidate) {
                numbers.append(candidate)
                used.insert(candidate)
            }
            candidate += 1
        }
        let highest = used.max() ?? 0
        return (numbers, max(max(counter, 1), highest + 1))
    }

    /// Repairs a counter loaded from disk so it can never hand out a number that is
    /// already in use — e.g. after a registry was hand-edited or restored from a backup.
    public static func reconciledCounter(storedCounter: Int, existingNumbers: [Int]) -> Int {
        let highest = existingNumbers.max() ?? 0
        return max(max(storedCounter, 1), highest + 1)
    }

    /// Validates that a set of numbers is usable: all positive, no duplicates.
    public static func validate(numbers: [Int]) throws {
        for n in numbers where n < 1 {
            throw MALError.duplicateInstanceNumber(n)
        }
        var seen = Set<Int>()
        for n in numbers {
            if !seen.insert(n).inserted {
                throw MALError.duplicateInstanceNumber(n)
            }
        }
    }

    /// Produces a 1...n mapping for an explicit user-requested renumber, preserving the
    /// current ascending order of existing numbers.
    ///
    /// Returns `[oldNumber: newNumber]`, omitting entries that do not change.
    public static func renumberPlan(existingNumbers: [Int], startingAt start: Int = 1) -> [Int: Int] {
        var plan: [Int: Int] = [:]
        for (offset, old) in existingNumbers.sorted().enumerated() {
            let new = start + offset
            if new != old { plan[old] = new }
        }
        return plan
    }
}

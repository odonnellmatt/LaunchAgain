import XCTest
@testable import MALCore

/// The invariant `Registry` states and, until this suite existed, did not hold:
///
///   a number is issued at most once per app, no matter how many processes are running.
///
/// A `DispatchQueue` orders writers inside one process and orders nothing at all between
/// two. These tests use separate `Registry` instances over one store — which is exactly
/// what a GUI and a CLI are — and, where the platform allows it, real child processes.
final class RegistryConcurrencyTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private let appKey = "com.example.concurrent"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-concurrency-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
        let seed = try Registry(paths: paths)
        try seed.upsertApp(appKey: appKey,
                           displayName: "Concurrent",
                           sourcePath: "/Applications/Concurrent.app",
                           sourceVersion: "1.0")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func instance(number: Int, name: String) -> Instance {
        let id = UUID()
        return Instance(id: id,
                        number: number,
                        name: name,
                        bundlePath: paths.bundlesDir.appendingPathComponent("\(name).app").path,
                        dataPath: paths.instanceDataDir(id).path)
    }

    private func committedNumbers() throws -> [Int] {
        try Registry(paths: paths).allInstances.map(\.instance.number).sorted()
    }

    // MARK: Independent writers must not collide

    /// Each writer is its own `Registry` on its own queue — the GUI/CLI shape. Run over
    /// several rounds, because a race that only shows up sometimes is still a bug.
    func testConcurrentRegistriesNeverIssueTheSameNumberTwice() throws {
        let writers = 8
        let rounds = 6

        for round in 0..<rounds {
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            let lock = NSLock()
            var issued: [Int] = []
            var failures: [String] = []

            for writer in 0..<writers {
                DispatchQueue.global().async(group: group) {
                    // A fresh Registry per writer: no shared queue, no shared memory.
                    guard let registry = try? Registry(paths: self.paths) else {
                        lock.lock(); failures.append("writer \(writer) could not open"); lock.unlock()
                        return
                    }
                    start.wait()
                    do {
                        let numbers = try registry.reserveNumbers(appKey: self.appKey, count: 1)
                        let number = try XCTUnwrap(numbers.first)
                        try registry.addInstance(
                            self.instance(number: number, name: "r\(round)w\(writer)"),
                            toApp: self.appKey)
                        lock.lock(); issued.append(number); lock.unlock()
                    } catch {
                        lock.lock(); failures.append("writer \(writer): \(error)"); lock.unlock()
                    }
                    // Hold the Registry until the work is done, so its reservations stay
                    // held for the whole "build" the way a real create does.
                    withExtendedLifetime(registry) {}
                }
            }
            for _ in 0..<writers { start.signal() }
            group.wait()

            XCTAssertTrue(failures.isEmpty, "round \(round): \(failures)")
            XCTAssertEqual(issued.count, writers, "round \(round): a writer was lost")
            XCTAssertEqual(Set(issued).count, issued.count,
                           "round \(round): a number was issued twice — \(issued.sorted())")

            let committed = try committedNumbers()
            XCTAssertEqual(committed.count, writers * (round + 1),
                           "round \(round): an instance was lost from the registry")
            XCTAssertEqual(Set(committed).count, committed.count,
                           "round \(round): duplicate numbers persisted — \(committed)")
        }

        // Six rounds of eight writers, all distinct, contiguous from 1.
        let all = try committedNumbers()
        XCTAssertEqual(all, Array(1...(writers * rounds)))
    }

    /// A number drawn but not yet committed must be invisible to allocation in another
    /// process. This is the build window: `create` reserves, spends seconds cloning, then
    /// commits. Without a durable reservation the second writer picks the same number.
    func testANumberHeldAcrossABuildWindowIsNotReissued() throws {
        let building = try Registry(paths: paths)
        let reserved = try building.reserveNumbers(appKey: appKey, count: 1)
        XCTAssertEqual(reserved, [1])

        // A different Registry, as a different process would be. Nothing is committed
        // yet, so only the reservation can stop it choosing 1 again.
        let other = try Registry(paths: paths)
        let second = try other.reserveNumbers(appKey: appKey, count: 1)
        XCTAssertEqual(second, [2], "a number still being built must not be reissued")

        withExtendedLifetime(building) {}
        withExtendedLifetime(other) {}
    }

    /// Multi-instance creates must not interleave into the same numbers either.
    func testConcurrentMultiNumberReservationsAreDisjoint() throws {
        let group = DispatchGroup()
        let lock = NSLock()
        var drawn: [[Int]] = []
        var registries: [Registry] = []

        for _ in 0..<5 {
            DispatchQueue.global().async(group: group) {
                guard let registry = try? Registry(paths: self.paths),
                      let numbers = try? registry.reserveNumbers(appKey: self.appKey, count: 3)
                else { return }
                lock.lock()
                drawn.append(numbers)
                registries.append(registry)
                lock.unlock()
            }
        }
        group.wait()

        XCTAssertEqual(drawn.count, 5)
        let flat = drawn.flatMap { $0 }
        XCTAssertEqual(flat.count, 15)
        XCTAssertEqual(Set(flat).count, 15, "reservations overlapped: \(drawn)")
        withExtendedLifetime(registries) {}
    }

    // MARK: A losing racer leaves nothing behind

    /// `addInstance` is the last gate. A writer that loses there must not leave a
    /// registry row, and the number it was holding must go back into circulation rather
    /// than becoming a permanent hole.
    func testALosingWriterLeavesNoRegistryRowAndReturnsItsNumber() throws {
        let winner = try Registry(paths: paths)
        let number = try XCTUnwrap(winner.reserveNumbers(appKey: appKey, count: 1).first)
        try winner.addInstance(instance(number: number, name: "winner"), toApp: appKey)

        // A second writer that somehow arrives at the same number is refused outright.
        let loser = try Registry(paths: paths)
        XCTAssertThrowsError(
            try loser.addInstance(instance(number: number, name: "loser"), toApp: appKey)
        ) { error in
            guard case .duplicateInstanceNumber = error as? MALError else {
                return XCTFail("expected duplicateInstanceNumber, got \(error)")
            }
        }

        let committed = try committedNumbers()
        XCTAssertEqual(committed, [number], "the loser must leave no row behind")

        // And a failed build gives its number back.
        let failing = try Registry(paths: paths)
        let drawn = try XCTUnwrap(failing.reserveNumbers(appKey: appKey, count: 1).first)
        failing.releaseReservedNumbers([drawn], appKey: appKey)
        let reused = try XCTUnwrap(
            try Registry(paths: paths).reserveNumbers(appKey: appKey, count: 1).first)
        XCTAssertEqual(reused, drawn,
                       "a released number must be reused, not left as a permanent hole")
    }

    // MARK: Stale state must not block anyone

    /// A reservation file whose process died holds no lock. It must be reaped rather
    /// than burning its number forever.
    func testAnAbandonedReservationDoesNotBlockALaterProcess() throws {
        // Written by hand, with nobody holding it: exactly what a SIGKILL leaves.
        let orphan = paths.numberReservationsDir
            .appendingPathComponent("\(String(format: "%016llx-", fnv1a(appKey)))1.reservation")
        try FileManager.default.createDirectory(at: paths.numberReservationsDir,
                                                withIntermediateDirectories: true)
        try Data("pid=999999 abandoned\n".utf8).write(to: orphan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        let registry = try Registry(paths: paths)
        let numbers = try registry.reserveNumbers(appKey: appKey, count: 1)
        XCTAssertEqual(numbers, [1],
                       "an abandoned reservation must be reaped, not treated as live")
        withExtendedLifetime(registry) {}
    }

    /// A stale lock file must not wedge the registry either.
    func testAnExistingLockFileDoesNotBlockTheRegistry() throws {
        let lockFile = paths.registryFile.appendingPathExtension("lock")
        try Data().write(to: lockFile)

        let registry = try Registry(paths: paths)
        let number = try XCTUnwrap(registry.reserveNumbers(appKey: appKey, count: 1).first)
        try registry.addInstance(instance(number: number, name: "after-stale-lock"),
                                 toApp: appKey)
        XCTAssertEqual(try committedNumbers(), [1])
    }

    /// A reservation released by its owner is immediately available again.
    func testReleasingAReservationFreesItsNumberForAnotherRegistry() throws {
        let first = try Registry(paths: paths)
        let drawn = try XCTUnwrap(first.reserveNumbers(appKey: appKey, count: 1).first)

        let blocked = try Registry(paths: paths)
        XCTAssertNotEqual(try blocked.reserveNumbers(appKey: appKey, count: 1).first, drawn)

        first.releaseReservedNumbers([drawn], appKey: appKey)
        withExtendedLifetime(blocked) {}

        let after = try Registry(paths: paths)
        XCTAssertEqual(try after.reserveNumbers(appKey: appKey, count: 1).first, drawn)
        withExtendedLifetime(after) {}
    }

    // MARK: Concurrent mutation must not lose writes

    /// Two registries removing and adding at once must not erase each other's work, which
    /// is what an unlocked read-modify-write of the whole document does.
    func testConcurrentAddsFromSeparateRegistriesAreAllPersisted() throws {
        let group = DispatchGroup()
        var registries: [Registry] = []
        let lock = NSLock()

        for i in 0..<10 {
            DispatchQueue.global().async(group: group) {
                guard let registry = try? Registry(paths: self.paths) else { return }
                lock.lock(); registries.append(registry); lock.unlock()
                guard let number = try? registry.reserveNumbers(appKey: self.appKey, count: 1).first
                else { return }
                try? registry.addInstance(self.instance(number: number, name: "add\(i)"),
                                          toApp: self.appKey)
            }
        }
        group.wait()

        let committed = try committedNumbers()
        XCTAssertEqual(committed.count, 10, "a concurrent write was lost: \(committed)")
        XCTAssertEqual(committed, Array(1...10))
        withExtendedLifetime(registries) {}
    }

    // MARK: Startup recovery is a write like any other

    /// Both recovery paths — corrupt-file recovery and `.bak` recovery — persist a
    /// rebuilt document. They used to do it outside `withRegistryLock`, which made them
    /// the only writes in the file that could land on top of another process's.
    ///
    /// The probe is the lock itself: hold an exclusive `flock` on `registry.json.lock`
    /// from a second file descriptor and the recovery must not complete until it is
    /// released. `flock` is per open file description, so this genuinely models a
    /// different process even though it runs here.
    private func assertRecoveryWaitsForTheRegistryLock(
        prepare: () throws -> Void,
        recover: @escaping () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try prepare()

        let lockPath = paths.registryFile.appendingPathExtension("lock").path
        let holder = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(holder, 0, "could not open the registry lock", file: file, line: line)
        XCTAssertEqual(flock(holder, LOCK_EX), 0, "could not take the registry lock", file: file, line: line)

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recover()
            finished.signal()
        }

        // While the lock is held the recovery must be blocked. A generous window: this
        // asserts "it waited", and a false pass would need the whole recovery to take
        // longer than this on an unloaded machine.
        XCTAssertEqual(finished.wait(timeout: .now() + 0.75), .timedOut,
                       "recovery persisted while another holder had the registry lock",
                       file: file, line: line)

        _ = flock(holder, LOCK_UN)
        close(holder)

        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success,
                       "recovery never completed after the registry lock was released",
                       file: file, line: line)
    }

    func testCorruptRecoveryPersistsUnderTheRegistryLock() throws {
        try assertRecoveryWaitsForTheRegistryLock {
            try Data("not json".utf8).write(to: paths.registryFile)
            try Data("not json either".utf8)
                .write(to: paths.registryFile.appendingPathExtension("bak"))
        } recover: {
            let recovered = try? Registry(paths: self.paths, recoverCorrupt: true)
            XCTAssertEqual(recovered?.recoveredFromCorruption, true)
            withExtendedLifetime(recovered) {}
        }
    }

    func testBackupRecoveryPersistsUnderTheRegistryLock() throws {
        try assertRecoveryWaitsForTheRegistryLock {
            let good = try Data(contentsOf: paths.registryFile)
            try good.write(to: paths.registryFile.appendingPathExtension("bak"))
            try Data("truncated".utf8).write(to: paths.registryFile)
        } recover: {
            let recovered = try? Registry(paths: self.paths)
            XCTAssertEqual(recovered?.recoveredFromBackup, true)
            withExtendedLifetime(recovered) {}
        }
    }

    /// Mirrors the private hash in `Registry` so this suite can name a reservation file.
    private func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(s.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

import AppKit
import XCTest
@testable import BridgeCore
final class AutoPublishMonitorTests:XCTestCase {
    @MainActor func testTimerAndLifecycleChecksWithoutAWindow()async throws {
        let wake=NotificationCenter(),activation=NotificationCenter()
        var checks=0
        let monitor=AutoPublishMonitor(interval:0.05,wakeCenter:wake,activationCenter:activation){checks+=1}
        // No SwiftUI view or application window is created by this test.
        try await Task.sleep(nanoseconds:250_000_000)
        XCTAssertGreaterThanOrEqual(checks,2)
        monitor.stop()
        try await Task.sleep(nanoseconds:100_000_000)
        let stopped=checks
        wake.post(name:NSWorkspace.didWakeNotification,object:nil)
        activation.post(name:NSApplication.didBecomeActiveNotification,object:nil)
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(checks,stopped)
        var resumed=0
        let lifecycle=AutoPublishMonitor(interval:3600,wakeCenter:wake,activationCenter:activation){resumed+=1}
        try await Task.sleep(nanoseconds:50_000_000)
        let initial=resumed
        wake.post(name:NSWorkspace.didWakeNotification,object:nil)
        activation.post(name:NSApplication.didBecomeActiveNotification,object:nil)
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(resumed,initial+2)
        lifecycle.stop()
        var cancelled=0
        let immediate=AutoPublishMonitor(interval:3600,wakeCenter:wake,activationCenter:activation){cancelled+=1}
        immediate.stop()
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(cancelled,0)
    }
}

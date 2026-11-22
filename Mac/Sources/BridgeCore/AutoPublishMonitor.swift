import AppKit
import Combine

/// Owned by the application model, so closing a window does not remove polling.
@MainActor public final class AutoPublishMonitor {
    private var subscriptions=Set<AnyCancellable>()
    private var initialCheck:Task<Void,Never>?
    public init(interval:TimeInterval=60,
                wakeCenter:NotificationCenter=NSWorkspace.shared.notificationCenter,
                activationCenter:NotificationCenter=NotificationCenter.default,
                onCheck:@escaping @MainActor ()->Void) {
        Timer.publish(every:interval,on:.main,in:.common).autoconnect()
            .sink{_ in onCheck()}.store(in:&subscriptions)
        wakeCenter.publisher(for:NSWorkspace.didWakeNotification).receive(on:RunLoop.main)
            .sink{_ in onCheck()}.store(in:&subscriptions)
        activationCenter.publisher(for:NSApplication.didBecomeActiveNotification).receive(on:RunLoop.main)
            .sink{_ in onCheck()}.store(in:&subscriptions)
        initialCheck=Task {guard !Task.isCancelled else{return};onCheck()}
    }
    public func stop() {initialCheck?.cancel();initialCheck=nil;subscriptions.removeAll()}
}

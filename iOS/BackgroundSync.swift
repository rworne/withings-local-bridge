import BackgroundTasks
import UIKit

@MainActor enum BackgroundSync {
    static var identifier:String {(Bundle.main.bundleIdentifier ?? "local.withingshealthbridge.iOS")+".sync"}
    static func register(model:SyncModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier:identifier,using:nil) {task in
            Task {@MainActor in
                guard let task=task as? BGProcessingTask else{task.setTaskCompleted(success:false);return}
                let run=BackgroundRun(task:task)
                let work=Task {@MainActor in
                    let success=await model.runBackgroundSync()
                    run.finish(success:success && !Task.isCancelled)
                }
                task.expirationHandler={
                    work.cancel()
                    Task {@MainActor in run.finish(success:false)}
                }
            }
        }
    }
    static func cancel() {BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier)}
    static func schedule()throws {
        cancel()
        let request=BGProcessingTaskRequest(identifier:identifier)
        request.earliestBeginDate=Date(timeIntervalSinceNow:3600)
        request.requiresNetworkConnectivity=true
        request.requiresExternalPower=false
        try BGTaskScheduler.shared.submit(request)
    }
}
@MainActor private final class BackgroundRun {
    let task:BGTask
    private var finished=false
    init(task:BGTask){self.task=task}
    func finish(success:Bool) {
        guard !finished else{return};finished=true
        task.expirationHandler=nil
        task.setTaskCompleted(success:success)
    }
}

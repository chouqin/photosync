import Foundation
import BackgroundTasks

/// iOS 后台任务管理器
/// 
/// 功能：当 App 被系统调度到后台时，检查新照片并上传
/// 
/// 限制说明：
/// - iOS 不保证精确的执行时间，系统根据电量、网络、使用习惯等因素调度
/// - 通常每 15-30 分钟执行一次（iOS 13+）
/// - 实时同步不可能，这是 iOS 的设计限制
/// - 最可靠的同步时机仍是用户打开 App 时
class BackgroundTaskManager {
    
    static let shared = BackgroundTaskManager()
    static let uploadTaskIdentifier = "com.photosync.backgroundupload"
    
    private init() {}
    
    /// 注册后台任务（必须在 App 启动时调用）
    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.uploadTaskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundUpload(task: task as! BGProcessingTask)
        }
        print("后台任务已注册: \(Self.uploadTaskIdentifier)")
    }
    
    /// 提交后台上传任务
    func scheduleUploadTask() {
        let request = BGProcessingTaskRequest(identifier: Self.uploadTaskIdentifier)
        request.requiresNetworkConnectivity = true  // 需要网络
        request.requiresExternalPower = false       // 不需要外接电源
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("后台上传任务已提交")
        } catch {
            print("提交后台任务失败: \(error)")
        }
    }
    
    /// 取消已提交的后台任务
    func cancelUploadTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.uploadTaskIdentifier)
    }
    
    /// 处理后台上传
    private func handleBackgroundUpload(task: BGProcessingTask) {
        // 设置超时处理
        let queue = DispatchQueue(label: "com.photosync.bgupload")
        
        task.expirationHandler = {
            print("后台任务即将超时")
            task.setTaskCompleted(success: false)
        }
        
        queue.async {
            // 检查是否需要上传
            guard PhotoLibrarySyncManager.shared.isAutoUploadEnabled else {
                task.setTaskCompleted(success: true)
                return
            }
            
            // 检查相册权限
            guard PHPhotoLibrary.authorizationStatus() == .authorized else {
                task.setTaskCompleted(success: false)
                return
            }
            
            // 执行上传
            Task {
                await PhotoLibrarySyncManager.shared.scanAndUploadNewPhotos()
                
                // 设置下一次任务
                await MainActor.run {
                    self.scheduleUploadTask()
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }
}

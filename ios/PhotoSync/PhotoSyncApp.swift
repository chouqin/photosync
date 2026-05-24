import SwiftUI

@main
struct PhotoSyncApp: App {
    @State private var isLoggedIn = KeychainHelper.shared.getToken() != nil
    
    init() {
        // 注册后台任务（必须在 App 启动时调用）
        BackgroundTaskManager.shared.registerTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if isLoggedIn {
                    PhotoGridView()
                        .transition(.opacity)
                } else {
                    LoginView(isLoggedIn: $isLoggedIn)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: isLoggedIn)
        }
    }
}

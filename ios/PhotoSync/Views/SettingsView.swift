import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var syncManager = PhotoLibrarySyncManager.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject var viewModel: PhotoViewModel
    
    @State private var showFullScanConfirmation = false
    @State private var showSaveAllConfirmation = false
    @State private var showWiFiAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - 全量扫描
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "cloud.arrow.up.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue.gradient)
                        
                        Text("全量扫描")
                            .font(.title2.bold())
                        
                        Text("扫描本地所有照片，上传服务端没有的照片。适用于 iCloud 恢复后的老照片同步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button {
                            if networkMonitor.isWiFi {
                                showFullScanConfirmation = true
                            } else {
                                alertMessage = "全量扫描需要连接 WiFi"
                                showWiFiAlert = true
                            }
                        } label: {
                            HStack {
                                if syncManager.isSyncing {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Label("开始全量扫描", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.gradient)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(syncManager.isSyncing)
                        
                        if syncManager.isSyncing {
                            Text("正在扫描和上传...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                
                // MARK: - 同步设置
                Section("同步设置") {
                    Toggle(isOn: Binding(
                        get: { syncManager.isAutoUploadEnabled },
                        set: { newValue in
                            if newValue {
                                syncManager.startAutoUpload()
                            } else {
                                syncManager.stopAutoUpload()
                            }
                        }
                    )) {
                        Label("自动同步新照片", systemImage: "arrow.triangle.2.circlepath")
                    }
                    
                    Text("开启后，App 会在 WiFi 环境下自动上传新拍摄的照片到服务端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // MARK: - 网络状态
                Section("网络状态") {
                    HStack {
                        Label("当前网络", systemImage: networkMonitor.isWiFi ? "wifi" : "cellularbars")
                        Spacer()
                        Text(networkMonitor.isWiFi ? "WiFi" : "蜂窝数据")
                            .foregroundColor(networkMonitor.isWiFi ? .green : .orange)
                            .fontWeight(.medium)
                    }
                    
                    if !networkMonitor.isWiFi {
                        Text("当前使用蜂窝数据，上传和下载功能已暂停。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                
                // MARK: - 统计信息
                Section("统计信息") {
                    HStack {
                        Label("上次同步", systemImage: "clock")
                        Spacer()
                        Text(syncManager.lastSyncDateFormatted)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    HStack {
                        Label("服务端照片", systemImage: "photo.stack")
                        Spacer()
                        Text("\(syncManager.knownRemoteCount) 张")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Label("本设备已上传", systemImage: "arrow.up.circle")
                        Spacer()
                        Text("\(syncManager.lastSyncedAssetCount) 张")
                            .foregroundStyle(.secondary)
                    }
                }
                
                // MARK: - 下载
                Section("下载") {
                    Button {
                        if networkMonitor.isWiFi {
                            showSaveAllConfirmation = true
                        } else {
                            alertMessage = "批量下载需要连接 WiFi"
                            showWiFiAlert = true
                        }
                    } label: {
                        Label("全部保存到相册", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(viewModel.photos.isEmpty || syncManager.isSyncing)
                    
                    Text("将服务端所有照片下载到系统相册。照片较多时可能需要较长时间。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // MARK: - 缓存
                Section("缓存") {
                    Button {
                        Task {
                            await syncManager.refreshRemoteChecksums()
                        }
                    } label: {
                        HStack {
                            Label("刷新服务端缓存", systemImage: "arrow.clockwise")
                            Spacer()
                            if syncManager.isRefreshingChecksums {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncManager.isRefreshingChecksums || syncManager.isSyncing)
                    
                    Text("从服务端拉取所有照片的 checksum，用于快速去重。建议换手机或重装 App 后执行一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // MARK: - 登出
                Section {
                    Button(role: .destructive) {
                        viewModel.logout()
                        dismiss()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("确认全量扫描", isPresented: $showFullScanConfirmation) {
                Button("开始", role: .none) {
                    Task {
                        await syncManager.scanAllPhotos()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这将扫描本地所有照片并上传服务端尚未存在的照片，可能需要较长时间。建议连接充电器并保持在 App 内。")
            }
            .alert("确认下载全部", isPresented: $showSaveAllConfirmation) {
                Button("下载", role: .none) {
                    Task {
                        do {
                            try await syncManager.syncRemotePhotosToLocal(photos: viewModel.photos)
                        } catch {
                            print("批量保存失败: \(error)")
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将 \(viewModel.photos.count) 张照片保存到系统相册，建议连接充电器。")
            }
            .alert("需要 WiFi", isPresented: $showWiFiAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: PhotoViewModel())
}

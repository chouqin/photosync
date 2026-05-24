import SwiftUI
import PhotosUI

struct PhotoGridView: View {
    @StateObject private var viewModel = PhotoViewModel()
    @StateObject private var syncManager = PhotoLibrarySyncManager.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var selectedPhoto: Photo?
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var uploadProgress = 0.0
    @State private var showSettings = false
    @State private var showWiFiAlert = false
    @State private var wifiAlertMessage = ""
    
    let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.photos) { photo in
                        PhotoThumbnailCell(photo: photo, viewModel: viewModel)
                            .aspectRatio(1, contentMode: .fill)
                            .onTapGesture {
                                selectedPhoto = photo
                            }
                            .contextMenu {
                                Button {
                                    saveSinglePhoto(photo)
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                }
                            }
                    }
                }
                .padding(2)
            }
            .navigationTitle("照片")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 50,
                        matching: .images
                    ) {
                        Image(systemName: "photo.badge.plus")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .onChange(of: selectedItems) { newItems in
                if !newItems.isEmpty {
                    uploadPhotos(items: newItems)
                }
            }
            .refreshable {
                await viewModel.loadPhotos()
            }
            .sheet(item: $selectedPhoto) { photo in
                PhotoDetailView(photo: photo)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .overlay {
                if isUploading || syncManager.isSyncing {
                    UploadProgressView(
                        progress: isUploading ? uploadProgress : 0.5,
                        message: isUploading ? "上传中..." : "同步新照片..."
                    )
                }
            }
            .alert("需要 WiFi", isPresented: $showWiFiAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(wifiAlertMessage)
            }
        }
        .task {
            // 启动时自动同步（如果有后台权限）
            await viewModel.loadPhotos()
            if syncManager.isAutoUploadEnabled {
                syncManager.scanAndUploadNewPhotos()
            }
        }
    }
    
    private func uploadPhotos(items: [PhotosPickerItem]) {
        guard networkMonitor.isWiFi else {
            wifiAlertMessage = "上传照片需要连接 WiFi，当前使用的是蜂窝数据。"
            showWiFiAlert = true
            selectedItems = []
            return
        }
        
        isUploading = true
        uploadProgress = 0
        
        Task {
            let total = Double(items.count)
            var completed = 0.0
            
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let filename = item.itemIdentifier ?? "photo_\(UUID().uuidString).jpg"
                    _ = try? await APIClient.shared.uploadPhoto(
                        imageData: data,
                        filename: filename,
                        deviceId: UIDevice.current.name
                    )
                }
                completed += 1
                await MainActor.run {
                    uploadProgress = completed / total
                }
            }
            
            await MainActor.run {
                isUploading = false
                selectedItems = []
            }
            await viewModel.loadPhotos()
        }
    }
    
    private func saveSinglePhoto(_ photo: Photo) {
        Task {
            do {
                try await PhotoLibrarySyncManager.shared.saveToPhotoLibrary(photo: photo)
                await MainActor.run {
                    // 可以在这里显示一个 Toast
                }
            } catch {
                print("保存失败: \(error)")
            }
        }
    }
}

struct PhotoThumbnailCell: View {
    let photo: Photo
    @ObservedObject var viewModel: PhotoViewModel
    
    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = viewModel.thumbnailCache[photo.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.5)
                        )
                        .task {
                            await viewModel.loadThumbnail(for: photo)
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

struct UploadProgressView: View {
    let progress: Double
    let message: String
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
                
                Text("\(message) \(Int(progress * 100))%")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }
}

#Preview {
    PhotoGridView()
}

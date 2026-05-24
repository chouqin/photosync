import SwiftUI

struct PhotoDetailView: View {
    let photo: Photo
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showSaveSuccess = false
    @State private var showWiFiAlert = false
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit
                        .pinchToZoom()
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("加载原图中...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("加载失败")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(photo.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                
                if let image = image {
                    ToolbarItem(placement: .navigationBarLeading) {
                        HStack(spacing: 16) {
                            // 保存到相册按钮
                            Button {
                                saveToLibrary()
                            } label: {
                                if isSaving {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                }
                            }
                            .disabled(isSaving)
                            
                            // 分享按钮
                            ShareLink(item: Image(uiImage: image), preview: SharePreview(photo.filename, image: Image(uiImage: image))) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
        .task {
            await loadOriginal()
        }
        .alert("需要 WiFi", isPresented: $showWiFiAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("下载原图需要连接 WiFi，当前使用的是蜂窝数据。")
        }
        .alert("已保存", isPresented: $showSaveSuccess) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("照片已保存到系统相册")
        }
    }
    
    private func loadOriginal() async {
        isLoading = true
        do {
            let img = try await APIClient.shared.loadOriginal(photoId: photo.id)
            await MainActor.run {
                self.image = img
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
    
    private func saveToLibrary() {
        guard networkMonitor.isWiFi else {
            showWiFiAlert = true
            return
        }
        
        isSaving = true
        Task {
            do {
                try await PhotoLibrarySyncManager.shared.saveToPhotoLibrary(photo: photo)
                await MainActor.run {
                    isSaving = false
                    showSaveSuccess = true
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                }
                print("保存失败: \(error)")
            }
        }
    }
}

// Pinch to zoom modifier
struct PinchToZoom: ViewModifier {
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = lastScale * value
                    }
                    .onEnded { _ in
                        withAnimation(.spring()) {
                            if scale < 1.0 {
                                scale = 1.0
                            }
                            lastScale = scale
                        }
                    }
            )
    }
}

extension View {
    func pinchToZoom() -> some View {
        modifier(PinchToZoom())
    }
}

#Preview {
    PhotoDetailView(photo: Photo(
        id: "test",
        filename: "test.jpg",
        fileSize: 1000,
        width: 100,
        height: 100,
        mimeType: "image/jpeg",
        checksum: nil,
        deviceId: nil,
        createdAt: "",
        takenAt: nil
    ))
}

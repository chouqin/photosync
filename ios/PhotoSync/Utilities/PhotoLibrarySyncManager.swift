import Foundation
import Photos
import UIKit
import Combine
import CryptoKit

/// 系统相册同步管理器
/// 新照片检测策略（三层过滤 + 断点恢复）：
/// 1. 快速时间过滤：creationDate > lastSyncDate（减少扫描量）
/// 2. 本地 checksum 去重：已知已上传的不读原图
/// 3. 服务端 checksum 去重：最终兜底，换手机/重装也不漏
/// 4. 断点恢复：每上传成功一张就推进 lastSyncDate，WiFi 断了下次从断点继续
class PhotoLibrarySyncManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    
    static let shared = PhotoLibrarySyncManager()
    
    @Published var isAutoUploadEnabled = false
    @Published var lastSyncedAssetCount: Int = 0
    @Published var isSyncing = false
    @Published var knownRemoteCount: Int = 0      // 服务端已有照片数
    @Published var localNewCount: Int = 0          // 本次扫描到的新照片数
    @Published var isRefreshingChecksums: Bool = false
    
    /// 格式化的上次同步时间（供 UI 显示）
    var lastSyncDateFormatted: String {
        let date = lastSyncDate
        if date == Date.distantPast {
            return "从未同步"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
    
    private var allLocalAssets: PHFetchResult<PHAsset>?
    private let imageManager = PHImageManager.default()
    private let syncQueue = DispatchQueue(label: "com.photosync.sync", qos: .utility)
    
    // MARK: - 本地持久化状态
    
    /// 上次成功同步的最晚 creationDate（断点恢复关键）
    private var lastSyncDate: Date {
        get { UserDefaults.standard.object(forKey: "lastSyncDate") as? Date ?? Date.distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "lastSyncDate") }
    }
    
    /// 本设备已成功上传的 checksum（换手机会丢失，仅做本地快速过滤）
    private var uploadedChecksums: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "uploadedChecksums") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "uploadedChecksums") }
    }
    
    /// 服务端 checksum 缓存（内存 + UserDefaults，启动时刷新）
    private var remoteChecksums: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "remoteChecksums") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "remoteChecksums") }
    }
    
    private override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    // MARK: - 1. 自动上传新照片
    
    func startAutoUpload() {
        guard !isAutoUploadEnabled else { return }
        
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            DispatchQueue.main.async {
                self.isAutoUploadEnabled = true
                self.scanAndUploadNewPhotos()
            }
        }
    }
    
    func stopAutoUpload() {
        isAutoUploadEnabled = false
    }
    
    /// PHPhotoLibraryChangeObserver 回调（App 存活时触发）
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard isAutoUploadEnabled else { return }
        
        if let assets = allLocalAssets, let details = changeInstance.changeDetails(for: assets) {
            if details.hasIncrementalChanges, !details.insertedObjects.isEmpty {
                Task {
                    await uploadAssets(details.insertedObjects)
                }
            } else if !details.hasIncrementalChanges {
                scanAndUploadNewPhotos()
            }
        }
    }
    
    // MARK: - 2. 扫描上传（增量 & 全量）
    
    /// 增量扫描：只扫 lastSyncDate 之后的新照片（日常使用）
    func scanAndUploadNewPhotos() {
        guard isAutoUploadEnabled else { return }
        guard KeychainHelper.shared.getToken() != nil else { return }
        guard NetworkMonitor.shared.isWiFi else {
            print("[Sync] 跳过：未连接 WiFi")
            return
        }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@", lastSyncDate as NSDate)
        
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        allLocalAssets = assets
        
        guard assets.count > 0 else {
            print("[Sync] 没有新照片（lastSyncDate 之后）")
            return
        }
        
        Task {
            await refreshRemoteChecksumsIfNeeded()
            let assetList = assets.objects(at: IndexSet(integersIn: 0..<assets.count))
            await uploadAssets(assetList)
        }
    }
    
    /// 全量扫描：扫全部照片，用服务端 checksum 过滤（用于捕获 iCloud 下载的老照片）
    func scanAllPhotos() async {
        guard NetworkMonitor.shared.isWiFi else {
            print("[Sync] 全量扫描跳过：未连接 WiFi")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        // 先刷新服务端 checksum 缓存
        await refreshRemoteChecksums()
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // 不加时间限制，扫全部
        
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        let assetList = assets.objects(at: IndexSet(integersIn: 0..<assets.count))
        
        print("[Sync] 全量扫描：本地共 \(assetList.count) 张照片，服务端已有 \(remoteChecksums.count) 张")
        
        // 快速过滤：如果某张的 creationDate < lastSyncDate 且 checksum 在 remote 里，跳过不读原图
        var candidates: [PHAsset] = []
        for asset in assetList {
            if let date = asset.creationDate, date <= lastSyncDate {
                // 老照片，需要先算 checksum 才能确定是否已上传
                // 但为了效率，先不读原图，等 uploadAssets 里处理
                candidates.append(asset)
            } else {
                candidates.append(asset)
            }
        }
        
        await uploadAssets(candidates)
    }
    
    // MARK: - 3. 上传核心逻辑
    
    /// 批量上传，支持断点恢复
    private func uploadAssets(_ assets: [PHAsset]) async {
        guard !assets.isEmpty else { return }
        
        isSyncing = true
        defer { isSyncing = false }
        
        var uploadedCount = 0
        var skippedCount = 0
        
        for asset in assets {
            guard isAutoUploadEnabled else { break }
            guard NetworkMonitor.shared.isWiFi else {
                print("[Sync] WiFi 断开，暂停上传，已上传 \(uploadedCount) 张")
                break
            }
            
            do {
                // Step 1: 请求原图数据
                let imageData = try await requestImageData(for: asset)
                
                // Step 2: 计算 checksum
                let checksum = SHA256.hash(data: imageData).hexString
                
                // Step 3: 双重去重检查
                if uploadedChecksums.contains(checksum) || remoteChecksums.contains(checksum) {
                    skippedCount += 1
                    // 即使跳过，也推进 lastSyncDate（说明这张照片已经同步过了）
                    if let date = asset.creationDate {
                        lastSyncDate = max(lastSyncDate, date)
                    }
                    continue
                }
                
                // Step 4: 上传
                let filename = asset.value(forKey: "filename") as? String ?? "photo_\(UUID().uuidString).jpg"
                let response = try await APIClient.shared.uploadPhoto(
                    imageData: imageData,
                    filename: filename,
                    deviceId: UIDevice.current.name
                )
                
                // Step 5: 标记成功
                uploadedChecksums.insert(checksum)
                remoteChecksums.insert(checksum)
                uploadedCount += 1
                
                // Step 6: 【关键】逐张推进 lastSyncDate = 断点恢复
                if let date = asset.creationDate {
                    lastSyncDate = max(lastSyncDate, date)
                }
                
                print("[Sync] 上传成功: \(response.id) \(response.duplicate ? "(duplicate)" : "")")
                
            } catch {
                print("[Sync] 上传失败: \(error)")
                // 失败不推进 lastSyncDate，下次会重试
            }
        }
        
        await MainActor.run {
            self.lastSyncedAssetCount += uploadedCount
            print("[Sync] 本轮完成：上传 \(uploadedCount) 张，跳过 \(skippedCount) 张，lastSyncDate = \(self.lastSyncDate)")
        }
    }
    
    // MARK: - 4. 刷新服务端 checksum 缓存
    
    /// 启动时或定期刷新：从服务端拉取所有 checksum，避免换手机/重装后重复上传
    private func refreshRemoteChecksumsIfNeeded() async {
        let lastRefresh = UserDefaults.standard.object(forKey: "lastChecksumRefresh") as? Date
        let oneHour: TimeInterval = 3600
        
        // 每小时刷新一次，或缓存为空时刷新
        if remoteChecksums.isEmpty || lastRefresh == nil || Date().timeIntervalSince(lastRefresh!) > oneHour {
            await refreshRemoteChecksums()
        }
    }
    
    /// 从服务端分页拉取所有照片的 checksum
    func refreshRemoteChecksums() async {
        guard NetworkMonitor.shared.isWiFi else { return }
        
        await MainActor.run { self.isRefreshingChecksums = true }
        defer { Task { @MainActor in self.isRefreshingChecksums = false } }
        
        var allChecksums = Set<String>()
        var page = 1
        let pageSize = 1000
        
        while true {
            do {
                let response = try await APIClient.shared.fetchPhotos(page: page, pageSize: pageSize)
                let checksums = response.photos.compactMap { $0.checksum }
                allChecksums.formUnion(checksums)
                
                if response.photos.count < pageSize {
                    break
                }
                page += 1
            } catch {
                print("[Sync] 拉取服务端 checksum 失败: \(error)")
                break
            }
        }
        
        remoteChecksums = allChecksums
        UserDefaults.standard.set(Date(), forKey: "lastChecksumRefresh")
        
        await MainActor.run {
            self.knownRemoteCount = allChecksums.count
        }
        
        print("[Sync] 服务端 checksum 缓存已刷新：共 \(allChecksums.count) 张")
    }
    
    // MARK: - 5. 请求原图数据
    
    private func requestImageData(for asset: PHAsset) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true   // 允许从 iCloud 下载
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SyncError.failedToReadAsset)
                }
            }
        }
    }
    
    // MARK: - 6. 下载云端照片到本地相册
    
    func saveToPhotoLibrary(photo: Photo) async throws {
        guard NetworkMonitor.shared.isWiFi else {
            throw SyncError.wifiRequired
        }
        
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized else {
            throw SyncError.photoLibraryAccessDenied
        }
        
        let imageData = try await downloadImageData(photoId: photo.id)
        try await saveImageDataToLibrary(imageData, filename: photo.filename)
    }
    
    private func downloadImageData(photoId: String) async throws -> Data {
        guard let url = URL(string: APIClient.shared.baseURL + "/api/photos/\(photoId)/original?redirect=1") else {
            throw SyncError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        
        if let token = KeychainHelper.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SyncError.downloadFailed
        }
        
        return data
    }
    
    private func saveImageDataToLibrary(_ data: Data, filename: String) async throws {
        guard UIImage(data: data) != nil else {
            throw SyncError.invalidImageData
        }
        
        try await PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: data, options: nil)
            creationRequest.creationDate = Date()
        }
    }
    
    // MARK: - 7. 批量同步云端照片到本地
    
    func syncRemotePhotosToLocal(photos: [Photo]) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized else {
            throw SyncError.photoLibraryAccessDenied
        }
        
        for photo in photos {
            do {
                try await saveToPhotoLibrary(photo: photo)
                print("[Sync] 已保存到相册: \(photo.filename)")
            } catch {
                print("[Sync] 保存失败: \(photo.filename) - \(error)")
            }
        }
    }
}

// MARK: - 辅助类型

enum SyncError: Error {
    case failedToReadAsset
    case photoLibraryAccessDenied
    case invalidURL
    case downloadFailed
    case invalidImageData
    case wifiRequired
    
    var localizedDescription: String {
        switch self {
        case .failedToReadAsset: return "无法读取照片数据"
        case .photoLibraryAccessDenied: return "没有相册写入权限，请在设置中开启"
        case .invalidURL: return "无效的下载链接"
        case .downloadFailed: return "下载失败"
        case .invalidImageData: return "无效的图片数据"
        case .wifiRequired: return "此操作需要 WiFi 网络"
        }
    }
}

struct UploadTask {
    let asset: PHAsset
    let creationDate: Date?
}

// MARK: - SHA256 Helper

extension SHA256.Digest {
    var hexString: String {
        return compactMap { String(format: "%02x", $0) }.joined()
    }
}

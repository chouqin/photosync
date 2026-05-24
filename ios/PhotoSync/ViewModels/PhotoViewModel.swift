import SwiftUI
import Combine

class PhotoViewModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var thumbnailCache: [String: UIImage] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var loadedThumbnails = Set<String>()
    
    func loadPhotos() async {
        await MainActor.run { isLoading = true }
        
        do {
            let response = try await APIClient.shared.fetchPhotos()
            await MainActor.run {
                self.photos = response.items
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    func loadThumbnail(for photo: Photo) async {
        guard !loadedThumbnails.contains(photo.id) else { return }
        loadedThumbnails.insert(photo.id)
        
        do {
            let image = try await APIClient.shared.loadThumbnail(photoId: photo.id, size: 256)
            await MainActor.run {
                self.thumbnailCache[photo.id] = image
            }
        } catch {
            print("Failed to load thumbnail for \(photo.id): \(error)")
        }
    }
    
    func logout() {
        KeychainHelper.shared.deleteToken()
        photos = []
        thumbnailCache = [:]
        loadedThumbnails.removeAll()
    }
    
    var isLoggedIn: Bool {
        return KeychainHelper.shared.getToken() != nil
    }
}

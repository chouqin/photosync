import Foundation

struct Photo: Identifiable, Codable {
    let id: String
    let filename: String
    let fileSize: Int
    let width: Int?
    let height: Int?
    let mimeType: String?
    let checksum: String?
    let deviceId: String?
    let createdAt: String
    let takenAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id, filename, width, height, mimeType, checksum, deviceId, createdAt, takenAt
        case fileSize = "file_size"
    }
}

struct PhotoListResponse: Codable {
    let items: [Photo]
    let page: Int
    let pageSize: Int
    let total: Int
    
    enum CodingKeys: String, CodingKey {
        case items, page, total
        case pageSize = "page_size"
    }
}

struct UploadResponse: Codable {
    let id: String
    let duplicate: Bool
    let photo: Photo?
}

struct AuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}

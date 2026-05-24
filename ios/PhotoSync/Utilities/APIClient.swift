import Foundation
import UIKit

class APIClient {
    static let shared = APIClient()
    
    /// 从 Config.plist 读取服务器地址，若不存在则使用默认值
    var baseURL: String {
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
           let url = dict["baseURL"] as? String, !url.isEmpty {
            return url
        }
        #if DEBUG
        return "http://localhost:8000"
        #else
        return "https://your-domain.com"
        #endif
    }
    
    private var token: String? {
        return KeychainHelper.shared.getToken()
    }
    
    private func makeRequest(path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> (Data, URLResponse) {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        
        if let contentType = contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        if let body = body {
            request.httpBody = body
        }
        
        return try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Auth
    
    func login(password: String) async throws -> AuthResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "username": "family",
            "password": password
        ])
        
        let (data, response) = try await makeRequest(
            path: "/api/auth/token",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.unauthorized
        }
        
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }
    
    // MARK: - Photos
    
    func fetchPhotos(page: Int = 1, pageSize: Int = 50) async throws -> PhotoListResponse {
        let (data, response) = try await makeRequest(
            path: "/api/photos?page=\(page)&page_size=\(pageSize)"
        )
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.requestFailed
        }
        
        return try JSONDecoder().decode(PhotoListResponse.self, from: data)
    }
    
    func uploadPhoto(imageData: Data, filename: String, deviceId: String = "iPhone") async throws -> UploadResponse {
        let boundary = UUID().uuidString
        var body = Data()
        
        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Device ID field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"device_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(deviceId)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        guard let url = URL(string: baseURL + "/api/photos/upload") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.requestFailed
        }
        
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }
    
    func loadThumbnail(photoId: String, size: Int = 256) async throws -> UIImage {
        let (data, response) = try await makeRequest(
            path: "/api/photos/\(photoId)/thumbnail?size=\(size)"
        )
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.requestFailed
        }
        
        guard let image = UIImage(data: data) else {
            throw APIError.invalidImage
        }
        
        return image
    }
    
    func loadOriginal(photoId: String) async throws -> UIImage {
        // The API returns 302 redirect to SAS URL, follow redirects automatically
        guard let url = URL(string: baseURL + "/api/photos/\(photoId)/original?redirect=1") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.requestFailed
        }
        
        guard let image = UIImage(data: data) else {
            throw APIError.invalidImage
        }
        
        return image
    }
}

enum APIError: Error {
    case invalidURL
    case unauthorized
    case requestFailed
    case invalidImage
    case networkError(Error)
    
    var description: String {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .unauthorized: return "登录失败，请检查密码"
        case .requestFailed: return "请求失败"
        case .invalidImage: return "无效的图片"
        case .networkError(let error): return "网络错误: \(error.localizedDescription)"
        }
    }
}

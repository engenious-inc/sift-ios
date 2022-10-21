import Foundation

public class OrchestratorAPI {

    public enum Status: String {
        case enabled
        case disabled
        case quarantine
    }

    private let endpoint: String
    private let token: String
    private let session = URLSession.shared
    private let log: Logging?
    
    private let path = "/v1/sift"
        private let pathRun = "/v1/sift/run"
        private let pathResult = "/v1/sift/result"

    public init(endpoint: String, token: String, log: Logging?) {
        self.endpoint = endpoint
        self.token = token
        self.log = log
    }

    public func get(testplan: String, status: Status, platform: String = "IOS") -> Config? {
        
        guard let url = URL(string: endpoint + path)?
            .appending("testplan", value: testplan)?
            .appending("status", value: status.rawValue.uppercased())?
            .appending("platform", value: platform) else {
            log?.error("Can't resolve URL endpoint")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "token")

        let result = session.sendSynchronous(request: request)
        
        if result.error != nil {
            log?.error("\(result.error!)")
            return nil
        }
        
        guard let data = result.data else {
            log?.error("Data is nil")
            return nil
        }

        guard let response = result.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            log?.error("Server error!")
            return nil
        }

        guard let mime = result.response?.mimeType, mime == "application/json" else {
            log?.error("Wrong MIME type!")
            return nil
        }

        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            log?.error("JSON parse error: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func post(tests: [String], platform: String = "IOS") -> Bool {
        guard let url = URL(string: endpoint + path)?
            .appending("platform", value: platform) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let json: [String : Any] = ["platform": platform.lowercased(), "tests": tests]
        let jsonData = try! JSONSerialization.data(withJSONObject: json, options: [])
        request.httpBody = jsonData

        let result = session.sendSynchronous(request: request)

        if result.error != nil {
            log?.error("\(result.error!)")
            return false
        }

        guard let response = result.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            log?.error("Server error!")
            return false
        }
        
        return true
    }
}

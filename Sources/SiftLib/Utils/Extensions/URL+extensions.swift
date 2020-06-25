import Foundation

extension URL {
    func appending(_ queryItem: String, value: String?) -> Self? {
        guard var urlComponents = URLComponents(string: absoluteString) else { return absoluteURL }
        var queryItems: [URLQueryItem] = urlComponents.queryItems ??  []
        queryItems.append(URLQueryItem(name: queryItem, value: value))
        urlComponents.queryItems = queryItems
        return urlComponents.url
    }
}

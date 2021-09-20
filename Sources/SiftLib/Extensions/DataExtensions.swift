import Foundation

extension Data {
    
    func string(encoding: String.Encoding) -> String? {
        String(data: self, encoding: encoding)
    }
}

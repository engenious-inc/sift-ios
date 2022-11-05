import Foundation

extension String {
	func matches(regex: String) -> [String] {
		guard let regex = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) else { return [] }
		let matches  = regex.matches(in: self, options: [], range: NSMakeRange(0, self.count))
		return matches.map { match in
			return String(self[Range(match.range, in: self)!])
		}
	}
}

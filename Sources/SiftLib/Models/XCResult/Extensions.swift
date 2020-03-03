import Foundation

extension KeyedDecodingContainer {
    func decodeXCResultType(forKey key: KeyedDecodingContainer<K>.Key) throws -> Bool {
        return try decodeXCResultType(forKey: key, defaultValue: false)
    }

    func decodeXCResultType(forKey key: KeyedDecodingContainer<K>.Key) throws -> Double {
        return try decodeXCResultType(forKey: key, defaultValue: Double(0))
    }

    func decodeXCResultType(forKey key: KeyedDecodingContainer<K>.Key) throws -> Int {
        return try decodeXCResultType(forKey: key, defaultValue: 0)
    }

    func decodeXCResultType(forKey key: KeyedDecodingContainer<K>.Key) throws -> String {
        return try decodeXCResultType(forKey: key, defaultValue: "")
    }

    func decodeXCResultType<T: Codable>(forKey key: KeyedDecodingContainer<K>.Key) throws -> T {
        let resultValueType = try self.decode(XCResultValueType.self, forKey: key)
        return resultValueType.getValue() as! T
    }

    func decodeXCResultType<T: Codable>(forKey key: KeyedDecodingContainer<K>.Key, defaultValue: T) throws -> T {
        let resultValueType = try self.decodeIfPresent(XCResultValueType.self, forKey: key)
        if let retval = resultValueType?.getValue() as! T? {
            return retval
        } else {
            return defaultValue
        }
    }
    
    func decodeXCResultTypeIfPresent<T: Codable>(forKey key: KeyedDecodingContainer<K>.Key) throws -> T? {
        let resultValueType = try self.decodeIfPresent(XCResultValueType.self, forKey: key)
        return resultValueType?.getValue() as! T?
    }

    func decodeXCResultArray<T: Codable>(forKey key: KeyedDecodingContainer<K>.Key) throws -> [T] {
        let arrayValues = try self.decodeIfPresent(XCResultArrayValue<T>.self, forKey: key)
        if let retval = arrayValues?.values {
            return retval
        } else {
            return []
        }
    }
    
    func decodeXCResultObject<T: Codable>(forKey key: K) throws -> T {
        let resultObject = try self.decode(XCResultObject.self, forKey: key)
        if let type = resultObject.type.getType() as? T.Type {
            return try self.decode(type.self, forKey: key)
        } else {
            return try self.decode(T.self, forKey: key)
        }
    }
    
    func decodeXCResultObjectIfPresent<T: Codable>(forKey key: K) throws -> T? {
        let resultObject = try self.decodeIfPresent(XCResultObject.self, forKey: key)
        if let type = resultObject?.type.getType() as? T.Type {
            return try self.decode(type.self, forKey: key)
        } else {
            return nil
        }
    }
    
    func decode<T : Codable, U : ClassFamily>(family: U.Type, forKey key: K) throws -> [T] {
        var container = try self.nestedUnkeyedContainer(forKey: key)
        var list = [T]()
        var tmpContainer = container
        while !container.isAtEnd {
            let resultObj = try container.decode(XCResultObject.self)
            if let type = resultObj.type.getType() as? T.Type {
                list.append(try tmpContainer.decode(type))
            }
        }
        return list
    }
}

extension JSONDecoder {
    func decode<T: ClassFamily, U: Decodable>(family: T.Type, from data: Data) throws -> [U] {
        return try self.decode([ClassWrapper<T, U>].self, from: data).compactMap { $0.object }
    }
    
    private class ClassWrapper<T: ClassFamily, U: Decodable>: Decodable {
        let family: T
        let object: U?
        
        required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Overlook.self)
            family = try container.decode(T.self, forKey: T.overlook)
            if let type = family.getType() as? U.Type {
                object = try type.init(from: decoder)
            } else {
                object = nil
            }
        }
    }
}

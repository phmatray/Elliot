//
//  ProtocolVersionCoding.swift
//  ACPModel
//

import Foundation

enum ProtocolVersionCoding {
    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Int {
        guard container.contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: container.codingPath + [key],
                    debugDescription: "Missing protocolVersion"
                )
            )
        }

        if let intValue = try? container.decode(Int.self, forKey: key) {
            return intValue
        }

        if let stringValue = try? container.decode(String.self, forKey: key) {
            return Int(stringValue) ?? 1
        }

        if (try? container.decodeNil(forKey: key)) == true {
            return 1
        }

        return 1
    }
}

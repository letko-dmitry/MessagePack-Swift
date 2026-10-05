import Benchmark
import Foundation
import MessagePack

// MARK: - Fixtures

private let smallIntArray = MessagePackValue.array(
    (0..<64).map { .int64(Int64($0)) }
)

private let largeIntArray = MessagePackValue.array(
    (0..<10_000).map { .int64(Int64($0 * 31 - 5_000)) }
)

private let doubleArray = MessagePackValue.array(
    (0..<10_000).map { .float64(Double($0) * 0.001) }
)

private let stringArray = MessagePackValue.array(
    (0..<1_000).map { .string("string value number \($0) with some padding") }
)

private let mapValue = MessagePackValue.map(
    Dictionary(
        uniqueKeysWithValues: (0..<1_000).map {
            (MessagePackValue.string("key_\($0)"), MessagePackValue.int64(Int64($0)))
        }
    )
)

private let nestedValue: MessagePackValue = {
    var leaf = MessagePackValue.map([
        .string("id"): .uint32(12345),
        .string("name"): .string("nested object"),
        .string("scores"): .array([.float64(1.5), .float64(2.5), .float64(3.5)]),
        .string("active"): .bool(true),
    ])
    return .array((0..<500).map { _ in leaf })
}()

private let binaryValue = MessagePackValue.binary(Data(repeating: 0xa5, count: 1 << 20))

private func serialized(_ value: MessagePackValue) -> Data {
    try! MessagePackSerializer.serialize(value: value)
}

// MARK: - Codable fixtures

private struct Person: Codable {
    var id: Int
    var name: String
    var email: String?
    var isActive: Bool
    var score: Double
    var tags: [String]
}

private let people = (0..<1_000).map {
    Person(
        id: $0,
        name: "person number \($0)",
        email: $0 % 3 == 0 ? nil : "person\($0)@example.com",
        isActive: $0 % 2 == 0,
        score: Double($0) * 0.5,
        tags: ["tag\($0 % 5)", "tag\($0 % 7)"]
    )
}

private let intValues = (0..<10_000).map { $0 * 31 - 5_000 }

/// Sixteen optional fields, every other one nil: keyed decoding through
/// `decodeIfPresent`, the shape of sparse API payloads.
private struct Wide: Codable {
    var id: Int?
    var name: String?
    var email: String?
    var phone: String?
    var age: Int?
    var height: Double?
    var weight: Double?
    var isActive: Bool?
    var isVerified: Bool?
    var score: Double?
    var rank: Int?
    var city: String?
    var country: String?
    var createdAt: Int?
    var updatedAt: Int?
    var note: String?
}

private let wides = (0..<1_000).map {
    Wide(
        id: $0, name: nil, email: "wide\($0)@example.com", phone: nil, age: $0 % 90,
        height: nil, weight: Double($0) * 0.1, isActive: nil, isVerified: $0 % 2 == 0,
        score: nil, rank: $0, city: nil, country: "BY", createdAt: nil,
        updatedAt: 1_700_000_000 + $0, note: nil
    )
}

/// A tree of 1093 nodes, seven levels deep: nested keyed and unkeyed
/// containers, where the coding path grows with every level.
private struct TreeNode: Codable {
    var id: Int
    var name: String
    var children: [TreeNode]
}

private func makeTree(depth: Int, id: inout Int) -> TreeNode {
    id += 1
    let nodeID = id
    let children = depth > 1 ? (0..<3).map { _ in makeTree(depth: depth - 1, id: &id) } : []
    return TreeNode(id: nodeID, name: "node \(nodeID)", children: children)
}

private let tree: TreeNode = {
    var id = 0
    return makeTree(depth: 7, id: &id)
}()

/// A typical RPC or event message: small, with a nested optional
/// dictionary, the case where per-call overheads (allocations, container
/// set-up) dominate.
private struct Event: Codable {
    var id: Int
    var type: String
    var timestamp: Date
    var userID: String?
    var attributes: [String: String]?
}

private let event = Event(
    id: 42,
    type: "workout.finished",
    timestamp: Date(timeIntervalSince1970: 1_700_000_000.25),
    userID: "user-7f3a",
    attributes: ["source": "watch", "level": "4"]
)

private let stringKeyedInts = Dictionary(
    uniqueKeysWithValues: (0..<1_000).map { ("key_\($0)", $0 * 7) }
)

// MARK: - Macro fixtures

/// Mirrors ``Person`` on the macro (`MessagePackSerializable`) route.
@MessagePackSerializable
private struct MacroPerson {
    var id: Int
    var name: String
    var email: String?
    var isActive: Bool
    var score: Double
    var tags: [String]
}

private let macroPeople = (0..<1_000).map {
    MacroPerson(
        id: $0,
        name: "person number \($0)",
        email: $0 % 3 == 0 ? nil : "person\($0)@example.com",
        isActive: $0 % 2 == 0,
        score: Double($0) * 0.5,
        tags: ["tag\($0 % 5)", "tag\($0 % 7)"]
    )
}

private let macroPeopleData = MessagePackSerializer.serialize(macroPeople)

private let peopleMsgPackData = try! MessagePackEncoder().encode(people)
private let peopleJSONData = try! JSONEncoder().encode(people)
private let intValuesMsgPackData = try! MessagePackEncoder().encode(intValues)
private let widesMsgPackData = try! MessagePackEncoder().encode(wides)
private let treeMsgPackData = try! MessagePackEncoder().encode(tree)
private let stringKeyedIntsMsgPackData = try! MessagePackEncoder().encode(stringKeyedInts)
private let eventMsgPackData = try! MessagePackEncoder().encode(event)

private let smallIntArrayData = serialized(smallIntArray)
private let largeIntArrayData = serialized(largeIntArray)
private let doubleArrayData = serialized(doubleArray)
private let stringArrayData = serialized(stringArray)
private let mapData = serialized(mapValue)
private let nestedData = serialized(nestedValue)
private let binaryData = serialized(binaryValue)

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        // Instructions stay stable under background load, where wall clock
        // and CPU time drift by several percent.
        metrics: [.cpuTotal, .wallClock, .instructions, .mallocCountTotal, .throughput],
        maxDuration: .seconds(3)
    )

    Benchmark("serialize: small int array (64)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: smallIntArray))
        }
    }

    Benchmark("serialize: large int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: largeIntArray))
        }
    }

    Benchmark("serialize: double array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: doubleArray))
        }
    }

    Benchmark("serialize: string array (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: stringArray))
        }
    }

    Benchmark("serialize: map (1k entries)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: mapValue))
        }
    }

    Benchmark("serialize: nested objects (500)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: nestedValue))
        }
    }

    Benchmark("serialize: binary 1MB") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.serialize(value: binaryValue))
        }
    }

    Benchmark("deserialize: small int array (64)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: smallIntArrayData))
        }
    }

    Benchmark("deserialize: large int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: largeIntArrayData))
        }
    }

    Benchmark("deserialize: double array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: doubleArrayData))
        }
    }

    Benchmark("deserialize: string array (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: stringArrayData))
        }
    }

    Benchmark("deserialize: map (1k entries)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: mapData))
        }
    }

    Benchmark("deserialize: nested objects (500)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: nestedData))
        }
    }

    Benchmark("deserialize: binary 1MB") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize(data: binaryData))
        }
    }

    Benchmark("round trip: nested objects (500)") { benchmark in
        for _ in benchmark.scaledIterations {
            let data = try MessagePackSerializer.serialize(value: nestedValue)
            blackHole(try MessagePackSerializer.deserialize(data: data))
        }
    }

    Benchmark("codable encode: structs (1k)") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(people))
        }
    }

    Benchmark("codable decode: structs (1k)") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Person].self, from: peopleMsgPackData))
        }
    }

    Benchmark("codable encode: int array (10k)") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(intValues))
        }
    }

    Benchmark("codable decode: int array (10k)") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Int].self, from: intValuesMsgPackData))
        }
    }

    Benchmark("codable encode: event") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(event))
        }
    }

    Benchmark("codable decode: event") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode(Event.self, from: eventMsgPackData))
        }
    }

    // A size series on the struct fixture: fixed costs per call show at 1
    // and 10 elements, per-element costs at 100 and 1k.
    for count in [1, 10, 100] {
        let slice = Array(people.prefix(count))
        let data = try! MessagePackEncoder().encode(slice)

        Benchmark("codable encode: structs (\(count))") { benchmark in
            let encoder = MessagePackEncoder()
            for _ in benchmark.scaledIterations {
                blackHole(try encoder.encode(slice))
            }
        }

        Benchmark("codable decode: structs (\(count))") { benchmark in
            let decoder = MessagePackDecoder()
            for _ in benchmark.scaledIterations {
                blackHole(try decoder.decode([Person].self, from: data))
            }
        }
    }

    Benchmark("codable encode: wides (1k)") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(wides))
        }
    }

    Benchmark("codable decode: wides (1k)") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Wide].self, from: widesMsgPackData))
        }
    }

    Benchmark("codable encode: tree (1093 nodes)") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(tree))
        }
    }

    Benchmark("codable decode: tree (1093 nodes)") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode(TreeNode.self, from: treeMsgPackData))
        }
    }

    Benchmark("codable encode: string-keyed ints (1k)") { benchmark in
        let encoder = MessagePackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(stringKeyedInts))
        }
    }

    Benchmark("codable decode: string-keyed ints (1k)") { benchmark in
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([String: Int].self, from: stringKeyedIntsMsgPackData))
        }
    }

    Benchmark("codable round trip: structs (1k)") { benchmark in
        let encoder = MessagePackEncoder()
        let decoder = MessagePackDecoder()
        for _ in benchmark.scaledIterations {
            let data = try encoder.encode(people)
            blackHole(try decoder.decode([Person].self, from: data))
        }
    }

    // The serializer route on the same struct fixture: hand-building a
    // MessagePackValue tree and serializing it (what using the library
    // without Codable looks like), and the reverse.
    Benchmark("serializer route encode: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            let tree = MessagePackValue.array(
                people.map { person in
                    .map([
                        .string("id"): .int64(Int64(person.id)),
                        .string("name"): .string(person.name),
                        .string("email"): person.email.map { .string($0) } ?? .nil,
                        .string("isActive"): .bool(person.isActive),
                        .string("score"): .float64(person.score),
                        .string("tags"): .array(person.tags.map { .string($0) }),
                    ])
                })
            blackHole(try MessagePackSerializer.serialize(value: tree))
        }
    }

    Benchmark("serializer route decode: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            let tree = try MessagePackSerializer.deserialize(data: peopleMsgPackData)
            let decoded = tree.arrayValue!.map { entry -> Person in
                let map = entry.mapValue!
                return Person(
                    id: Int(map[.string("id")]!.int64Value!),
                    name: map[.string("name")]!.stringValue!,
                    email: map[.string("email")].flatMap(\.stringValue),
                    isActive: map[.string("isActive")]!.boolValue!,
                    score: map[.string("score")]!.doubleValue!,
                    tags: map[.string("tags")]!.arrayValue!.map { $0.stringValue! }
                )
            }
            blackHole(decoded)
        }
    }

    // The macro route on the same struct fixture: @MessagePackSerializable
    // generated code writing/reading the wire format directly.
    Benchmark("macro serialize: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackSerializer.serialize(macroPeople))
        }
    }

    Benchmark("macro deserialize: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize([MacroPerson].self, from: macroPeopleData))
        }
    }

    Benchmark("macro round trip: structs (1k)") { benchmark in
        for _ in benchmark.scaledIterations {
            let data = MessagePackSerializer.serialize(macroPeople)
            blackHole(try MessagePackSerializer.deserialize([MacroPerson].self, from: data))
        }
    }

    Benchmark("macro serialize: int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MessagePackSerializer.serialize(intValues))
        }
    }

    Benchmark("macro deserialize: int array (10k)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try MessagePackSerializer.deserialize([Int].self, from: intValuesMsgPackData))
        }
    }

    // Reference points: Foundation JSON coders on the same fixtures.
    Benchmark("reference JSONEncoder: structs (1k)") { benchmark in
        let encoder = JSONEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(try encoder.encode(people))
        }
    }

    Benchmark("reference JSONDecoder: structs (1k)") { benchmark in
        let decoder = JSONDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(try decoder.decode([Person].self, from: peopleJSONData))
        }
    }
}

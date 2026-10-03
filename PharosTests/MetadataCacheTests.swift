// Standalone test for MetadataCache: one entry per connection, so windows on
// different connections never see each other's schemas. Compiled by
// scripts/test-metadata-cache.sh with a fake loader (no Rust core).
import Combine
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func table(_ schema: String, _ name: String) -> TableInfo {
    let json = #"{"name":"\#(name)","schemaName":"\#(schema)","tableType":"table","isPartitioned":false,"isPartition":false,"hasChildTables":false}"#
    return try! JSONDecoder().decode(TableInfo.self, from: Data(json.utf8))
}

private func column(_ table: String, _ name: String) -> SchemaColumnInfo {
    SchemaColumnInfo(tableName: table, name: name, dataType: "text", isNullable: true, isPrimaryKey: false,
                     ordinalPosition: 1, columnDefault: nil)
}

/// Two servers: "a" has schema public.users(id), "b" has schema zeek.conn(uid).
@MainActor
private final class FakeServers {
    var schemaCalls: [String] = []
    var gate: [String: CheckedContinuation<Void, Never>] = [:]
    var holdSchemas: Set<String> = []

    var loader: MetadataLoader {
        MetadataLoader(
            schemas: { id in
                await MainActor.run { self.schemaCalls.append(id) }
                if await MainActor.run(body: { self.holdSchemas.contains(id) }) {
                    await withCheckedContinuation { c in Task { @MainActor in self.gate[id] = c } }
                }
                return id == "a" ? [SchemaInfo(name: "public", owner: nil)] : [SchemaInfo(name: "zeek", owner: nil)]
            },
            tables: { id, schema in id == "a" ? [table(schema, "users")] : [table(schema, "conn")] },
            columns: { id, _ in id == "a" ? [column("users", "id")] : [column("conn", "uid")] })
    }

    func release(_ id: String) { gate.removeValue(forKey: id)?.resume() }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
}

@MainActor
private func testTwoConnectionsStayApart() async {
    let servers = FakeServers()
    let cache = MetadataCache(loader: servers.loader, ttlMinutes: { 0 })
    var seenByA: [MetadataCache.ConnectionMetadata] = []
    var seenByB: [MetadataCache.ConnectionMetadata] = []
    var bag = Set<AnyCancellable>()
    cache.publisher(for: "a").sink { seenByA.append($0) }.store(in: &bag)
    cache.publisher(for: "b").sink { seenByB.append($0) }.store(in: &bag)

    cache.load(connectionId: "a")
    await settle()
    cache.load(connectionId: "b")
    await settle()

    let a = cache.metadata(for: "a"), b = cache.metadata(for: "b")
    expect(a.schemas.map(\.name) == ["public"] && b.schemas.map(\.name) == ["zeek"],
           "each connection keeps its own schemas", "a \(a.schemas.map(\.name)), b \(b.schemas.map(\.name))")
    expect(a.tables["public"]?.map(\.name) == ["users"] && a.columnsByTable["public.users"]?.map(\.name) == ["id"],
           "a's tables and columns", "\(a.tables), \(a.columnsByTable.keys)")
    expect(b.tables["zeek"]?.map(\.name) == ["conn"] && b.tables["public"] == nil,
           "b has its own tables and none of a's")
    expect(!a.isLoading && !b.isLoading, "neither is loading once done")
    expect(seenByA.last?.schemas.map(\.name) == ["public"] && seenByA.allSatisfy { !$0.schemas.contains { $0.name == "zeek" } },
           "a's subscriber never sees b's schemas")
    let aUpdates = seenByA.count
    cache.load(connectionId: "b", force: true)
    await settle()
    expect(seenByA.count == aUpdates, "reloading b does not republish to a's subscriber",
           "\(seenByA.count - aUpdates) extra")

    cache.clearConnection("b")
    expect(cache.metadata(for: "b").schemas.isEmpty, "clearing b empties b")
    expect(cache.metadata(for: "a").schemas.map(\.name) == ["public"], "clearing b leaves a")
    expect(cache.metadata(for: nil).schemas.isEmpty, "no connection: empty metadata")
}

@MainActor
private func testCacheHitAndLoading() async {
    let servers = FakeServers()
    let cache = MetadataCache(loader: servers.loader, ttlMinutes: { 0 })
    servers.holdSchemas = ["a"]
    cache.load(connectionId: "a")
    await settle()
    expect(cache.metadata(for: "a").isLoading, "a is loading while its schemas are in flight")
    expect(!cache.metadata(for: "b").isLoading, "b is not loading because a is")
    servers.release("a")
    await settle()
    expect(!cache.metadata(for: "a").isLoading && cache.metadata(for: "a").schemas.count == 1, "a loaded")
    servers.holdSchemas = []
    cache.load(connectionId: "a")
    await settle()
    expect(servers.schemaCalls.filter { $0 == "a" }.count == 1, "a second load of a loaded connection fetches nothing",
           "calls \(servers.schemaCalls)")
    cache.load(connectionId: "a", force: true)
    await settle()
    expect(servers.schemaCalls.filter { $0 == "a" }.count == 2, "force fetches again")
}

@MainActor
private func testClearAllReportsWhatItHeld() async {
    let servers = FakeServers()
    let cache = MetadataCache(loader: servers.loader, ttlMinutes: { 0 })
    cache.load(connectionId: "a")
    cache.load(connectionId: "b")
    await settle()
    let cleared = cache.clearAll()
    expect(Set(cleared) == ["a", "b"], "clearAll returns the connections it held, for a reload", "got \(cleared)")
    expect(cache.metadata(for: "a").schemas.isEmpty && cache.metadata(for: "b").schemas.isEmpty, "clearAll empties both")
}

func runTests() {
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        await testTwoConnectionsStayApart()
        await testCacheHitAndLoading()
        await testClearAllReportsWhatItHeld()
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    if failures == 0 { print("\nAll MetadataCache tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}

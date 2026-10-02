// Standalone test for SQLLexSnapshot. Compiled by scripts/test-sql-lex-snapshot.sh.
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

func runTests() {
    let sql = "SELECT 'a;b' -- c;\nFROM t;\n$$x;y$$"
    let a = SQLLexSnapshot.shared(for: sql)
    let b = SQLLexSnapshot.shared(for: sql)
    expect(a === b, "the same text is served from the cache")

    let c = SQLLexSnapshot.shared(for: sql + " ")
    expect(c !== a, "different text builds a new snapshot")
    // Query cards: several editors' texts take turns. Each must stay cached.
    expect(SQLLexSnapshot.shared(for: sql) === a, "two texts in turn: the first is still cached")
    expect(SQLLexSnapshot.shared(for: sql + " ") === c, "two texts in turn: the second is still cached")

    // Entry limit: the least recently used text goes first.
    SQLLexSnapshot.clearCache()
    let first = SQLLexSnapshot.shared(for: "SELECT 0")
    for i in 1..<SQLLexSnapshot.cacheCapacity { _ = SQLLexSnapshot.shared(for: "SELECT \(i)") }
    expect(SQLLexSnapshot.shared(for: "SELECT 0") === first, "a full cache still holds its oldest entry")
    // "SELECT 0" is now the most recent; "SELECT 1" is the least recent.
    let one = SQLLexSnapshot.shared(for: "SELECT 1")
    _ = SQLLexSnapshot.shared(for: "SELECT 0")
    _ = SQLLexSnapshot.shared(for: "SELECT overflow")
    expect(SQLLexSnapshot.shared(for: "SELECT 0") === first, "a recently used entry survives an overflow")
    expect(SQLLexSnapshot.shared(for: "SELECT 1") === one, "the entry used just before the overflow survives too")
    expect(SQLLexSnapshot.cachedCount == SQLLexSnapshot.cacheCapacity, "the cache never holds more than its capacity", "got \(SQLLexSnapshot.cachedCount)")

    // Size limit: large texts push out older entries, but the newest always stays.
    SQLLexSnapshot.clearCache()
    let small = SQLLexSnapshot.shared(for: "SELECT small")
    let huge = String(repeating: "x", count: SQLLexSnapshot.maxCachedLength)
    let hugeSnap = SQLLexSnapshot.shared(for: huge)
    expect(SQLLexSnapshot.shared(for: huge) === hugeSnap, "a text at the size limit is still cached")
    expect(SQLLexSnapshot.shared(for: "SELECT small") !== small, "the size limit pushed out the older entry")
    SQLLexSnapshot.clearCache()

    expect(a.length == Array(sql.utf16).count, "length is the UTF-16 count")
    expect(a.lineStarts == [0, 19, 27], "line starts are the offsets after each newline", "got \(a.lineStarts)")
    expect(a.stateMap.count == a.length, "one lex state per UTF-16 unit")
    // Offsets: 'a;b' spans 7...11; the ';' inside it is at 9.
    expect(a.stateMap[9] == .singleQuote, "a semicolon inside a string is in string state")
    expect(a.stateMap[15] == .lineComment, "a semicolon inside a line comment is in comment state")
    expect(a.stateMap[24].isNormal, "the statement's own semicolon is in normal state")

    // The parsers agree with a fresh lex: segment split honours the map.
    let segments = SQLSegmentParser.parse(sql)
    expect(segments.count == 2, "two segments: the quoted and commented semicolons do not split", "got \(segments.count)")

    let empty = SQLLexSnapshot(text: "")
    expect(empty.length == 0 && empty.lineStarts == [0] && empty.stateMap.isEmpty, "the empty text snapshot is well formed")

    // Concurrent readers of one text never see a torn or wrong snapshot.
    let group = DispatchGroup()
    var mismatches = 0
    let lock = NSLock()
    for i in 0..<64 {
        group.enter()
        DispatchQueue.global().async {
            let text = i % 2 == 0 ? sql : sql + " "
            let s = SQLLexSnapshot.shared(for: text)
            if s.text != text || s.stateMap.count != s.length { lock.lock(); mismatches += 1; lock.unlock() }
            group.leave()
        }
    }
    group.wait()
    expect(mismatches == 0, "concurrent lookups for alternating texts each get their own text's snapshot")

    if failures == 0 { print("\nAll SQLLexSnapshot tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}

import Foundation
import Testing

@testable import GitCore

@Test
func commitConstruction() {
    let date = Date(timeIntervalSince1970: 0)
    let commit = Commit(
        sha: "abc123def456",
        parents: ["p1", "p2"],
        authorName: "Test Author",
        authorEmail: "test@example.com",
        authorDate: date,
        summary: "Test commit",
        refs: ["HEAD -> main", "tag: v1.0"]
    )

    #expect(commit.sha == "abc123def456")
    #expect(commit.shortSha == "abc123d")
    #expect(commit.isMerge == true)
    #expect(commit.parents.count == 2)
}

@Test
func commitNotMerge() {
    let date = Date(timeIntervalSince1970: 0)
    let commit = Commit(
        sha: "abc123def456",
        parents: ["parent1"],
        authorName: "Test Author",
        authorEmail: "test@example.com",
        authorDate: date,
        summary: "Test commit",
        refs: []
    )

    #expect(commit.isMerge == false)
}

@Test
func branchConstruction() {
    let branch = Branch(
        name: "main",
        sha: "abc123def456",
        isHead: true,
        upstream: "origin/main"
    )

    #expect(branch.name == "main")
    #expect(branch.id == "main")
}

@Test
func tagConstruction() {
    let tag = Tag(
        name: "v1.0",
        sha: "abc123def456",
        isAnnotated: true
    )

    #expect(tag.name == "v1.0")
    #expect(tag.id == "v1.0")
}

@Test
func refCollectionConstruction() {
    let local1 = Branch(name: "main", sha: "abc", isHead: true, upstream: nil)
    let local2 = Branch(name: "dev", sha: "def", isHead: false, upstream: nil)
    let remote1 = Branch(name: "origin/main", sha: "abc", isHead: false, upstream: nil)
    let remote2 = Branch(name: "origin/dev", sha: "def", isHead: false, upstream: nil)
    let remote3 = Branch(name: "upstream/feature", sha: "ghi", isHead: false, upstream: nil)

    let refs = RefCollection(
        localBranches: [local1, local2],
        remoteBranches: [remote1, remote2, remote3],
        tags: []
    )

    let remoteNames = refs.remoteNames
    #expect(remoteNames == ["origin", "upstream"])
}

@Test
func changeKindFromPorcelain() {
    #expect(ChangeKind.from(porcelain: "M") == .modified)
    #expect(ChangeKind.from(porcelain: "A") == .added)
    #expect(ChangeKind.from(porcelain: "D") == .deleted)
    #expect(ChangeKind.from(porcelain: "R") == .renamed)
    #expect(ChangeKind.from(porcelain: "C") == .copied)
    #expect(ChangeKind.from(porcelain: "T") == .typeChanged)
    #expect(ChangeKind.from(porcelain: "U") == .unmerged)
    #expect(ChangeKind.from(porcelain: "?") == .untracked)
    #expect(ChangeKind.from(porcelain: "!") == .ignored)
    #expect(ChangeKind.from(porcelain: ".") == nil)
    #expect(ChangeKind.from(porcelain: "X") == .unknown("X"))
}

@Test
func fileStatusConstruction() {
    let status = FileStatus(
        path: "src/main.swift",
        originalPath: nil,
        staged: .modified,
        unstaged: .modified
    )

    #expect(status.path == "src/main.swift")
    #expect(status.id == "src/main.swift")
    #expect(status.isUntracked == false)
}

@Test
func fileStatusUntracked() {
    let status = FileStatus(
        path: "newfile.swift",
        originalPath: nil,
        staged: nil,
        unstaged: .untracked
    )

    #expect(status.isUntracked == true)
}

@Test
func workingCopyStatusConstruction() {
    let status = WorkingCopyStatus(
        headSha: "abc123",
        branch: "main",
        upstream: "origin/main",
        ahead: 2,
        behind: 1,
        files: []
    )

    #expect(status.headSha == "abc123")
    #expect(status.branch == "main")
}

@Test
func diffLineConstruction() {
    let line = DiffLine(
        id: 0,
        kind: .added,
        oldNumber: nil,
        newNumber: 1,
        text: "let x = 5"
    )

    #expect(line.id == 0)
    #expect(line.text == "let x = 5")
}

@Test
func hunkConstruction() {
    let lines = [
        DiffLine(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: "let x = 5"),
        DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 2, text: "let y = 10")
    ]

    let hunk = Hunk(
        header: "@@ -1,1 +1,2 @@ func test",
        oldStart: 1,
        oldCount: 1,
        newStart: 1,
        newCount: 2,
        lines: lines
    )

    #expect(hunk.id == "@@ -1,1 +1,2 @@ func test")
}

@Test
func fileDiffConstruction() {
    let diff = FileDiff(
        oldPath: "src/old.swift",
        newPath: "src/new.swift",
        kind: .renamed,
        isBinary: false,
        hunks: []
    )

    #expect(diff.displayPath == "src/new.swift")
    #expect(diff.id == "src/old.swift→src/new.swift")
}

@Test
func fileDiffDisplayPathForAdded() {
    let diff = FileDiff(
        oldPath: nil,
        newPath: "src/new.swift",
        kind: .added,
        isBinary: false,
        hunks: []
    )

    #expect(diff.displayPath == "src/new.swift")
}

@Test
func fileDiffDisplayPathForDeleted() {
    let diff = FileDiff(
        oldPath: "src/old.swift",
        newPath: nil,
        kind: .deleted,
        isBinary: false,
        hunks: []
    )

    #expect(diff.displayPath == "src/old.swift")
}

@Test
func graphEdgeConstruction() {
    let edge = GraphEdge(fromLane: 0, toLane: 1, fromAbove: true)

    #expect(edge.fromLane == 0)
    #expect(edge.toLane == 1)
    #expect(edge.fromAbove == true)
}

@Test
func graphRowConstruction() {
    let edge = GraphEdge(fromLane: 0, toLane: 1, fromAbove: false)
    let row = GraphRow(
        sha: "abc123def456",
        lane: 0,
        edges: [edge],
        laneCount: 2
    )

    #expect(row.sha == "abc123def456")
    #expect(row.id == "abc123def456")
    #expect(row.laneCount == 2)
}

@Test
func repoSnapshotConstruction() {
    let root = URL(fileURLWithPath: "/path/to/repo")
    let status = WorkingCopyStatus(
        headSha: "abc123",
        branch: "main",
        upstream: nil,
        ahead: 0,
        behind: 0,
        files: []
    )
    let refs = RefCollection(localBranches: [], remoteBranches: [], tags: [])

    let snapshot = RepoSnapshot(
        root: root,
        status: status,
        refs: refs,
        commits: [],
        graph: []
    )

    #expect(snapshot.root == root)
    #expect(snapshot.commits.count == 0)
}

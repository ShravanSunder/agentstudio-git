import Testing

@testable import AgentStudioGitLocal

@Suite("Sparse checkout matcher")
struct SparseCheckoutMatcherTests {
    @Test("cone mode includes root files, parent-directory files, and recursive directories only")
    func coneModeIncludesRootParentAndRecursiveDirectories() {
        // Arrange
        let matcher = SparseCheckoutMatcher(
            patternFile: "/*\n!/*/\n/src/\n!/src/*/\n/src/app/\n",
            coneMode: true
        )

        // Act / Assert
        #expect(matcher.includes("README.md"))
        #expect(matcher.includes("src/main.swift"))
        #expect(!matcher.includes("src/other/file.swift"))
        #expect(matcher.includes("src/app/deep/file.swift"))
        #expect(!matcher.includes("docs/guide.md"))
    }

    @Test("non-cone mode lets the last matching pattern decide and undecided paths inherit their directory")
    func nonConeModeUsesLastMatchAndDirectoryInheritance() {
        // Arrange
        let matcher = SparseCheckoutMatcher(
            patternFile: "/*\n!/dropped/\n/dropped/keep.txt\n*.log\n!build/**/*.log\n",
            coneMode: false
        )

        // Act / Assert
        #expect(matcher.includes("kept/one.txt"))
        #expect(!matcher.includes("dropped/three.txt"))
        #expect(matcher.includes("dropped/keep.txt"))
        #expect(matcher.includes("dropped/nested/trace.log"))
        #expect(!matcher.includes("build/out/trace.log"))
    }

    @Test("a cone-flagged pattern file that is not in cone form falls back to pattern rules")
    func nonConeFormFallsBackToPatternRules() {
        // Arrange
        let matcher = SparseCheckoutMatcher(patternFile: "/docs/*.md\n", coneMode: true)

        // Act / Assert
        #expect(matcher.includes("docs/guide.md"))
        #expect(!matcher.includes("docs/nested/guide.md"))
        #expect(!matcher.includes("README.md"))
    }

    @Test("Git bracket classes translate exactly, including a leading ], negation, ranges, and POSIX classes")
    func gitBracketClassesTranslateExactly() {
        // Arrange
        let leadingBracket = SparseCheckoutMatcher(patternFile: "/[]]*\n", coneMode: false)
        let negated = SparseCheckoutMatcher(patternFile: "/[!a-c]*\n", coneMode: false)
        let posix = SparseCheckoutMatcher(patternFile: "/v[[:digit:]].txt\n", coneMode: false)

        // Act / Assert
        #expect(!leadingBracket.hasUntranslatablePatterns)
        #expect(leadingBracket.includes("]notes.txt"))
        #expect(!leadingBracket.includes("notes.txt"))
        #expect(negated.includes("docs.txt"))
        #expect(!negated.includes("build.txt"))
        #expect(posix.includes("v7.txt"))
        #expect(!posix.includes("vx.txt"))
        #expect(!posix.includes("v].txt"))
    }

    @Test("bracket members that are special to ICU stay literal, and a reversed range matches nothing")
    func icuSpecialBracketMembersStayLiteral() {
        // Arrange
        let icuOperators = SparseCheckoutMatcher(patternFile: "/[&&]x\n/[a[]y\n", coneMode: false)
        let reversedRange = SparseCheckoutMatcher(patternFile: "/[z-a]x\n", coneMode: false)

        // Act / Assert
        #expect(!icuOperators.hasUntranslatablePatterns)
        #expect(icuOperators.includes("&x"))
        #expect(icuOperators.includes("[y"))
        #expect(!icuOperators.includes("bx"))
        #expect(!reversedRange.hasUntranslatablePatterns)
        #expect(!reversedRange.includes("zx"))
        #expect(!reversedRange.includes("mx"))
    }

    @Test(".gitmodules names map registered paths, and quoted paths are unquoted")
    func gitmodulesNamesMapRegisteredPaths() {
        // Arrange
        let text = """
            [submodule "library"]
            \tpath = deps/library
            \turl = ../library
            [submodule "spaced name"]
            \tpath = "deps/with space"
            [core]
            \tpath = not-a-submodule
            """

        // Act
        let names = WorktreeForkSubmoduleRegistrations.namesByPath(text)

        // Assert
        #expect(names == ["deps/library": "library", "deps/with space": "spaced name"])
    }
}

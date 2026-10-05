// Altered Swift bytecode port of Git-derived wildmatch (Rich Salz / Wayne Davison).
// References: vendor/libgit2/src/util/wildmatch.c and Git dir.c match_pathname's literal-prefix split.
// WM_PATHNAME is always enabled.
// Copyright Rich Salz. All rights reserved.
// Redistribution and use in any form are permitted provided that the following restrictions are are met:
// 1. Source distributions must retain this entire copyright notice and comment.
// 2. Binary distributions must include the acknowledgement ``This product includes software developed by
//    Rich Salz'' in the documentation or other materials provided with the distribution. This must not be
//    represented as an endorsement or promotion without specific prior written permission.
// 3. The origin of this software must not be misrepresented, either by explicit claim or by omission.
//    Credits must appear in the source and documentation.
// 4. Altered versions must be plainly marked as such in the source and documentation and must not be
//    misrepresented as being the original software.
// THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, WITHOUT
// LIMITATION, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.

/// Parsed once into byte instructions. Git's abort-to-recursive-star result is retained, so a component
/// star never accidentally crosses a separator during backtracking. Case folding is ASCII, as in Git.
struct GitWildmatchPattern: Sendable {
    fileprivate enum StarKind: Sendable {
        case component
        case recursive
        case recursiveDirectory
        var crossesSeparator: Bool { self != .component }
    }
    fileprivate enum Instruction: Sendable {
        case literal(UInt8)
        case escapedLiteral(UInt8)
        case anyByte
        case star(StarKind)
        case characterClass(GitWildmatchCharacterClass)
        case abort
    }
    fileprivate let instructions: [Instruction]

    init(bytes: [UInt8]) throws(GitPathPatternError) {
        var instructions: [Instruction] = []
        var cursor = 0
        var globByteSeen = false
        while cursor < bytes.count {
            let byte = bytes[cursor]
            switch byte {
            case 92:
                guard cursor + 1 < bytes.count else { throw .malformed }
                instructions.append(.escapedLiteral(bytes[cursor + 1]))
                cursor += 2
            case 63:
                instructions.append(.anyByte)
                cursor += 1
            case 42:
                var end = cursor + 1
                while end < bytes.count, bytes[end] == 42 { end += 1 }
                let recursive =
                    end - cursor >= 2 && (cursor == 0 || bytes[cursor - 1] == 47 || !globByteSeen)
                    && (end == bytes.count || bytes[end] == 47
                        || (bytes[end] == 92 && end + 1 < bytes.count && bytes[end + 1] == 47))
                let kind: StarKind =
                    recursive
                    ? (end < bytes.count && bytes[end] == 47 ? .recursiveDirectory : .recursive) : .component
                instructions.append(.star(kind))
                cursor = end
            case 91:
                let parsed = try GitWildmatchCharacterClass.parse(bytes: bytes, at: cursor)
                if let characterClass = parsed.characterClass {
                    instructions.append(.characterClass(characterClass))
                } else {
                    instructions.append(.abort)
                }
                cursor = parsed.nextIndex
            default:
                instructions.append(.literal(bytes[cursor]))
                cursor += 1
            }
            if byte == 42 || byte == 63 || byte == 91 || byte == 92 { globByteSeen = true }
        }
        self.instructions = instructions
    }

    func matches(_ text: ArraySlice<UInt8>, ignoreCase: Bool) -> Bool {
        var execution = Execution(pattern: self, text: text, ignoreCase: ignoreCase)
        return execution.evaluate(State(patternIndex: 0, textIndex: text.startIndex)) == .match
    }

    static func folded(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
    private struct State: Hashable {
        let patternIndex: Int
        let textIndex: Int
    }
    private enum Outcome {
        case match
        case noMatch
        case abortAll
        case abortToRecursive
    }
    private struct Execution {
        let pattern: GitWildmatchPattern
        let text: ArraySlice<UInt8>
        let ignoreCase: Bool
        var outcomes: [State: Outcome] = [:]

        mutating func evaluate(_ state: State) -> Outcome {
            if let cached = outcomes[state] { return cached }
            let result = run(state)
            outcomes[state] = result
            return result
        }

        private mutating func run(_ state: State) -> Outcome {
            var patternIndex = state.patternIndex
            var textIndex = state.textIndex
            while patternIndex < pattern.instructions.count {
                let instruction = pattern.instructions[patternIndex]
                if case .star(let kind) = instruction {
                    return matchStar(kind, at: State(patternIndex: patternIndex, textIndex: textIndex))
                }
                guard textIndex < text.endIndex else { return .abortAll }
                let textByte = ignoreCase ? GitWildmatchPattern.folded(text[textIndex]) : text[textIndex]
                switch instruction {
                case .literal(let byte):
                    let patternByte = ignoreCase ? GitWildmatchPattern.folded(byte) : byte
                    if patternByte != textByte { return .noMatch }
                case .escapedLiteral(let byte):
                    // dowild's escape branch compares the following byte literally after folding text.
                    if byte != textByte { return .noMatch }
                case .anyByte:
                    if textByte == 47 { return .noMatch }
                case .characterClass(let characterClass):
                    if !characterClass.matches(text[textIndex], ignoreCase: ignoreCase) { return .noMatch }
                case .abort: return .abortAll
                case .star: return .abortAll  // handled above
                }
                patternIndex += 1
                textIndex += 1
            }
            return textIndex == text.endIndex ? .match : .noMatch
        }

        private mutating func matchStar(_ kind: StarKind, at state: State) -> Outcome {
            let nextIndex = state.patternIndex + 1
            if nextIndex == pattern.instructions.count {
                return kind.crossesSeparator || !text[state.textIndex...].contains(47) ? .match : .noMatch
            }
            let next = pattern.instructions[nextIndex]
            if kind == .recursiveDirectory,
                evaluate(State(patternIndex: nextIndex + 1, textIndex: state.textIndex)) == .match
            {
                return .match
            }
            if kind == .component, case .literal(47) = next {
                guard let slash = text[state.textIndex...].firstIndex(of: 47) else { return .noMatch }
                return evaluate(State(patternIndex: nextIndex + 1, textIndex: slash + 1))
            }
            var textIndex = state.textIndex
            while textIndex < text.endIndex {
                // The C implementation skips directly to a following ordinary literal. Escapes and
                // classes retain their full instruction evaluation, including their case semantics.
                if case .literal(let byte) = next {
                    let wanted = ignoreCase ? GitWildmatchPattern.folded(byte) : byte
                    while textIndex < text.endIndex {
                        let current = ignoreCase ? GitWildmatchPattern.folded(text[textIndex]) : text[textIndex]
                        if !kind.crossesSeparator && current == 47 { break }
                        if current == wanted { break }
                        textIndex += 1
                    }
                    guard textIndex < text.endIndex else { return .noMatch }
                    let current = ignoreCase ? GitWildmatchPattern.folded(text[textIndex]) : text[textIndex]
                    if current != wanted { return .noMatch }
                }
                let result = evaluate(State(patternIndex: nextIndex, textIndex: textIndex))
                if result != .noMatch {
                    if !kind.crossesSeparator || result != .abortToRecursive { return result }
                } else if !kind.crossesSeparator && text[textIndex] == 47 {
                    return .abortToRecursive
                }
                textIndex += 1
            }
            return .abortAll
        }
    }
}

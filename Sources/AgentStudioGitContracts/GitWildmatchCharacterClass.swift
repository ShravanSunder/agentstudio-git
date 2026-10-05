// Altered Swift byte-class compilation from Git-derived wildmatch (Rich Salz / Wayne Davison).
// Reference: vendor/libgit2/src/util/wildmatch.c. Copyright Rich Salz. All rights reserved.
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

import Foundation

/// Git classes consume one byte. Both case policies are compiled into constant-size membership maps;
/// ranges retain their preceding literal member, including when the range itself is reversed.
struct GitWildmatchCharacterClass: Sendable {
    let sensitiveWords: [UInt64]
    let foldedWords: [UInt64]

    struct ParsedClass {
        let characterClass: GitWildmatchCharacterClass?
        let nextIndex: Int
    }
    private enum Member {
        case literal(UInt8)
        case range(UInt8, UInt8)
        case posix(POSIXClass)
    }
    private enum POSIXClass: String {
        case alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit

        func matches(_ byte: UInt8, ignoreCase: Bool) -> Bool {
            let lower = byte >= 97 && byte <= 122
            let upper = byte >= 65 && byte <= 90
            let digit = byte >= 48 && byte <= 57
            let printable = byte >= 32 && byte <= 126
            // Git's sane_ctype, rather than libc isspace: vertical tab and form feed are not space.
            let whitespace = byte == 9 || byte == 10 || byte == 13 || byte == 32
            switch self {
            case .alnum: return lower || upper || digit
            case .alpha: return lower || upper
            case .blank: return byte == 32 || byte == 9
            case .cntrl: return byte < 32 || byte == 127
            case .digit: return digit
            case .graph: return byte > 32 && byte <= 126
            case .lower: return lower
            case .print: return printable
            case .punct: return printable && !whitespace && !lower && !upper && !digit
            case .space: return whitespace
            case .upper: return upper || (ignoreCase && lower)
            case .xdigit: return digit || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
            }
        }
    }

    static func parse(bytes: [UInt8], at start: Int) throws(GitPathPatternError) -> ParsedClass {
        var cursor = start + 1
        let negated = cursor < bytes.count && (bytes[cursor] == 33 || bytes[cursor] == 94)
        if negated { cursor += 1 }
        var members: [Member] = []
        var previous: UInt8 = 0
        var first = true
        while cursor < bytes.count {
            var byte = bytes[cursor]
            if byte == 93 && !first {
                return ParsedClass(characterClass: compile(members: members, negated: negated), nextIndex: cursor + 1)
            }
            first = false
            if byte == 92 {
                cursor += 1
                guard cursor < bytes.count else { break }
                byte = bytes[cursor]
                members.append(.literal(byte))
            } else if byte == 45 && previous != 0 && cursor + 1 < bytes.count && bytes[cursor + 1] != 93 {
                cursor += 1
                if bytes[cursor] == 92 { cursor += 1 }
                guard cursor < bytes.count else { break }
                members.append(.range(previous, bytes[cursor]))
                byte = 0
            } else if byte == 91 && cursor + 1 < bytes.count && bytes[cursor + 1] == 58 {
                let nameStart = cursor + 2
                guard let closing = bytes[nameStart...].firstIndex(of: 93) else { break }
                if closing > nameStart && bytes[closing - 1] == 58 {
                    guard let name = String(bytes: bytes[nameStart..<(closing - 1)], encoding: .utf8),
                        let posix = POSIXClass(rawValue: name)
                    else { throw .malformed }
                    members.append(.posix(posix))
                    cursor = closing
                    byte = 0
                } else {
                    // An incomplete [:name] is ordinary '[' membership, exactly as dowild does.
                    members.append(.literal(byte))
                }
            } else {
                members.append(.literal(byte))
            }
            previous = byte
            cursor += 1
        }
        // An unclosed bracket aborts wildmatch; it is never silently reinterpreted as a literal '['.
        return ParsedClass(characterClass: nil, nextIndex: bytes.count)
    }

    private static func compile(members: [Member], negated: Bool) -> Self {
        var sensitiveWords = Array(repeating: UInt64(0), count: 4)
        var foldedWords = sensitiveWords
        for number in 0..<256 {
            let byte = UInt8(number)
            if byte == 47 { continue }
            let mask = UInt64(1) << (number % 64)
            if accepts(byte, members: members, ignoreCase: false) != negated { sensitiveWords[number / 64] |= mask }
            if accepts(byte, members: members, ignoreCase: true) != negated { foldedWords[number / 64] |= mask }
        }
        return Self(sensitiveWords: sensitiveWords, foldedWords: foldedWords)
    }

    private static func accepts(_ byte: UInt8, members: [Member], ignoreCase: Bool) -> Bool {
        let subject = ignoreCase ? GitWildmatchPattern.folded(byte) : byte
        return members.contains { member in
            switch member {
            case .literal(let literal): return subject == literal
            case .range(let lower, let upper):
                if subject >= lower && subject <= upper { return true }
                if ignoreCase && subject >= 97 && subject <= 122 {
                    return subject - 32 >= lower && subject - 32 <= upper
                }
                return false
            case .posix(let posix): return posix.matches(subject, ignoreCase: ignoreCase)
            }
        }
    }

    func matches(_ byte: UInt8, ignoreCase: Bool) -> Bool {
        let words = ignoreCase ? foldedWords : sensitiveWords
        return words[Int(byte) / 64] & (UInt64(1) << (Int(byte) % 64)) != 0
    }
}

import CLibGit2Local
import CryptoKit
import Foundation

struct LibGit2LargeFilePointerCleanliness: Sendable {
    private static let filterAttributeName = "filter"
    private static let largeFileFilterName = "lfs"
    fileprivate static let maximumPointerByteCount = 1024
    private static let hashReadByteCount = 1_048_576

    func isCleanSmudgedFile(
        delta: git_diff_delta,
        repository: OpaquePointer,
        worktreePath: String
    ) throws -> Bool {
        guard delta.status == GIT_DELTA_MODIFIED,
            delta.old_file.mode == delta.new_file.mode,
            !LibGit2ReviewSupport.isZeroOID(delta.old_file.id),
            hasFlag(delta.old_file.flags, GIT_DIFF_FLAG_VALID_ID),
            try usesLargeFileFilter(repository: repository, path: worktreePath),
            let pointerData = try committedPointerData(file: delta.old_file, repository: repository),
            let pointer = LargeFilePointer(data: pointerData)
        else {
            return false
        }

        let worktreeFile = try LibGit2ReviewSupport.containedWorkingTreeFile(
            repository: repository,
            path: worktreePath
        )
        let values = try worktreeFile.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            return false
        }
        if fileSize == pointerData.count,
            try Data(contentsOf: worktreeFile, options: [.mappedIfSafe]) == pointerData
        {
            return true
        }
        guard fileSize == pointer.payloadByteCount else {
            return false
        }
        return try sha256Hex(of: worktreeFile) == pointer.payloadSHA256
    }

    private func usesLargeFileFilter(repository: OpaquePointer, path: String) throws -> Bool {
        var attributeValue: UnsafePointer<CChar>?
        let result = path.withCString { pathPointer in
            Self.filterAttributeName.withCString { attributeNamePointer in
                git_attr_get(&attributeValue, repository, 0, pathPointer, attributeNamePointer)
            }
        }
        guard result >= 0 else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        guard let attributeValue,
            git_attr_value(attributeValue) == GIT_ATTR_VALUE_STRING
        else {
            return false
        }
        return String(cString: attributeValue) == Self.largeFileFilterName
    }

    private func committedPointerData(
        file: git_diff_file,
        repository: OpaquePointer
    ) throws -> Data? {
        var oid = file.id
        var blob: OpaquePointer?
        let lookupResult = git_blob_lookup(&blob, repository, &oid)
        guard lookupResult >= 0, let blob else {
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_blob_free(blob) }

        let rawSize = git_blob_rawsize(blob)
        guard rawSize >= 0, rawSize < Self.maximumPointerByteCount,
            let rawContent = git_blob_rawcontent(blob)
        else {
            return nil
        }
        return Data(bytes: rawContent, count: Int(rawSize))
    }

    private func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: Self.hashReadByteCount), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hasFlag(_ flags: UInt32, _ flag: git_diff_flag_t) -> Bool {
        (flags & flag.rawValue) != 0
    }
}

private struct LargeFilePointer {
    private static let versionLine = "version https://git-lfs.github.com/spec/v1"

    let payloadSHA256: String
    let payloadByteCount: Int

    init?(data: Data) {
        guard data.count < LibGit2LargeFilePointerCleanliness.maximumPointerByteCount,
            let contents = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let normalizedContents = contents.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedContents.contains("\r") else {
            return nil
        }
        var lines = normalizedContents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let payloadByteCountText = lines.count == 3 ? String(lines[2].dropFirst("size ".count)) : ""
        guard lines.count == 3,
            lines[0] == Self.versionLine,
            lines[1].hasPrefix("oid sha256:"),
            lines[2].hasPrefix("size "),
            !payloadByteCountText.isEmpty,
            payloadByteCountText.allSatisfy({ ("0"..."9").contains($0) }),
            let payloadByteCount = Int(payloadByteCountText)
        else {
            return nil
        }
        let payloadSHA256 = String(lines[1].dropFirst("oid sha256:".count))
        guard payloadSHA256.count == 64,
            payloadSHA256.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else {
            return nil
        }
        self.payloadSHA256 = payloadSHA256
        self.payloadByteCount = payloadByteCount
    }
}

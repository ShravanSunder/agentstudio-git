import Darwin
import Foundation

/// Whether two regular files are the same counterpart: equal bytes, permission bits, user-visible flags,
/// extended attributes, and extended ACL. Used to tell a strict clone of a source file from a different file
/// that happens to share its name.
enum WorktreeForkFileEquivalence {
    /// Kernel-managed attributes a copy may carry differently from its original.
    private static let kernelManagedAttributes: Set<String> = ["com.apple.provenance"]
    private static let readChunkSize = 64 * 1024

    static func isEquivalent(_ first: URL, _ second: URL) -> Bool {
        let firstDescriptor = first.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard firstDescriptor >= 0 else {
            return false
        }
        defer { close(firstDescriptor) }
        let secondDescriptor = second.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard secondDescriptor >= 0 else {
            return false
        }
        defer { close(secondDescriptor) }
        return isEquivalent(firstDescriptor, secondDescriptor)
    }

    static func isEquivalent(_ first: Int32, _ second: Int32) -> Bool {
        guard case .success(let firstInfo) = WorktreeForkDescriptors.statDescriptor(first),
            case .success(let secondInfo) = WorktreeForkDescriptors.statDescriptor(second),
            firstInfo.st_mode & S_IFMT == S_IFREG, secondInfo.st_mode & S_IFMT == S_IFREG,
            firstInfo.st_size == secondInfo.st_size,
            firstInfo.st_mode & WorktreeForkEntryMetadata.permissionMask
                == secondInfo.st_mode & WorktreeForkEntryMetadata.permissionMask,
            firstInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask
                == secondInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask,
            let firstAttributes = extendedAttributes(first), let secondAttributes = extendedAttributes(second),
            firstAttributes == secondAttributes,
            accessControlText(first) == accessControlText(second)
        else {
            return false
        }
        return contentsMatch(first, second, size: Int(firstInfo.st_size))
    }

    private static func contentsMatch(_ first: Int32, _ second: Int32, size: Int) -> Bool {
        var firstBuffer = [UInt8](repeating: 0, count: readChunkSize)
        var secondBuffer = [UInt8](repeating: 0, count: readChunkSize)
        var offset = 0
        while offset < size {
            let length = min(readChunkSize, size - offset)
            let firstRead = pread(first, &firstBuffer, length, off_t(offset))
            let secondRead = pread(second, &secondBuffer, length, off_t(offset))
            guard firstRead == length, secondRead == length, firstBuffer[0..<length] == secondBuffer[0..<length] else {
                return false
            }
            offset += length
        }
        return true
    }

    /// Name to value, without kernel-managed attributes; nil when the attributes cannot be read.
    private static func extendedAttributes(_ descriptor: Int32) -> [String: [UInt8]]? {
        let namesSize = flistxattr(descriptor, nil, 0, 0)
        guard namesSize >= 0 else {
            return errno == ENOTSUP ? [:] : nil
        }
        var names = [CChar](repeating: 0, count: namesSize)
        guard namesSize == 0 || flistxattr(descriptor, &names, names.count, 0) == namesSize else {
            return nil
        }
        var attributes: [String: [UInt8]] = [:]
        for nameBytes in names.split(separator: 0) {
            guard let name = String(bytes: nameBytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                return nil
            }
            guard !kernelManagedAttributes.contains(name) else {
                continue
            }
            let valueSize = fgetxattr(descriptor, name, nil, 0, 0, 0)
            guard valueSize >= 0 else {
                return nil
            }
            var value = [UInt8](repeating: 0, count: valueSize)
            guard fgetxattr(descriptor, name, &value, value.count, 0, 0) == valueSize else {
                return nil
            }
            attributes[name] = value
        }
        return attributes
    }

    private static func accessControlText(_ descriptor: Int32) -> String? {
        guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        guard let text = acl_to_text(accessControlList, nil) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }
}

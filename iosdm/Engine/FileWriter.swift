import Foundation
import Darwin

enum FileWriterError: LocalizedError {
    case openFailed(Int32)
    case truncateFailed(Int32)
    case writeFailed(Int32)
    case closed

    var errorDescription: String? {
        switch self {
        case .openFailed(let code):
            return "无法打开本地临时文件 (errno \(code): \(String(cString: strerror(code))))"
        case .truncateFailed(let code):
            return "无法预分配文件空间 (errno \(code): \(String(cString: strerror(code))))"
        case .writeFailed(let code):
            if code == ENOSPC {
                return "设备存储空间不足，无法继续写入"
            }
            return "文件写入失败 (errno \(code): \(String(cString: strerror(code))))"
        case .closed:
            return "文件句柄已关闭"
        }
    }
}

final class FileWriter: @unchecked Sendable {
    private var fd: Int32 = -1
    private var rwlock = pthread_rwlock_t()
    let fileURL: URL

    init(url: URL, expectedSize: Int64?, truncateToZero: Bool = false) throws {
        self.fileURL = url
        pthread_rwlock_init(&rwlock, nil)

        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let openedFD = url.path.withCString { cPath in
            Darwin.open(cPath, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard openedFD >= 0 else {
            let err = errno
            pthread_rwlock_destroy(&rwlock)
            throw FileWriterError.openFailed(err)
        }
        self.fd = openedFD

        if truncateToZero {
            if Darwin.ftruncate(openedFD, 0) != 0 {
                let err = errno
                Darwin.close(openedFD)
                self.fd = -1
                pthread_rwlock_destroy(&rwlock)
                throw FileWriterError.truncateFailed(err)
            }
        } else if let expectedSize, expectedSize >= 0 {
            var st = stat()
            if Darwin.fstat(openedFD, &st) == 0 && st.st_size != expectedSize {
                if Darwin.ftruncate(openedFD, off_t(expectedSize)) != 0 {
                    let err = errno
                    Darwin.close(openedFD)
                    self.fd = -1
                    pthread_rwlock_destroy(&rwlock)
                    throw FileWriterError.truncateFailed(err)
                }
            }
        }
    }

    deinit {
        close()
        pthread_rwlock_destroy(&rwlock)
    }

    func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        pthread_rwlock_rdlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }

        guard fd >= 0 else {
            throw FileWriterError.closed
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            let totalCount = rawBuffer.count
            while totalWritten < totalCount {
                let ptr = baseAddress.advanced(by: totalWritten)
                let written = Darwin.pwrite(fd, ptr, totalCount - totalWritten, off_t(offset) + off_t(totalWritten))
                if written < 0 {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    throw FileWriterError.writeFailed(err)
                }
                if written == 0 {
                    throw FileWriterError.writeFailed(EIO)
                }
                totalWritten += written
            }
        }
    }

    func truncate(to size: Int64) throws {
        pthread_rwlock_wrlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }

        guard fd >= 0 else {
            throw FileWriterError.closed
        }
        if Darwin.ftruncate(fd, off_t(size)) != 0 {
            throw FileWriterError.truncateFailed(errno)
        }
    }

    func syncAndClose() {
        pthread_rwlock_wrlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }

        guard fd >= 0 else { return }
        _ = Darwin.fsync(fd)
        _ = Darwin.close(fd)
        fd = -1
    }

    func close() {
        pthread_rwlock_wrlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }

        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        fd = -1
    }
}

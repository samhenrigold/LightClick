#!/usr/bin/env python3
"""A small NFSv3 and MOUNT server for one host folder, on one TCP port, to measure file identity on a guest.

    probes/nfs3-server.py FOLDER [--port N]      Serves until killed. Prints the port.
    probes/nfs3-server.py --self-test            Exercises every call against a loopback client, including escapes.

Every OS X guest has `mount_nfs`, so this reaches Tiger to Big Sur, unlike 9P, with no guest driver and no rebuild of QEMU.
Guests mount it with -o vers=3,tcp,port=N,mountport=N,nolocks. It is a probe: on loopback only, unauthenticated, and
single-threaded. The guest is untrusted, so nothing may resolve outside the folder, whatever a handle, name or symlink says.
"""
import errno
import hashlib
import os
import socket
import stat
import struct
import sys
import tempfile
import threading

NFS_PROGRAM, MOUNT_PROGRAM = 100003, 100005
OK, PERM, NOENT, IO, ACCES, EXIST, NOTDIR, ISDIR, INVAL, NOTEMPTY, STALE = 0, 1, 2, 5, 13, 17, 20, 21, 22, 66, 70
ERRORS = {errno.EPERM: PERM, errno.ENOENT: NOENT, errno.EIO: IO, errno.EACCES: ACCES, errno.EEXIST: EXIST,
          errno.ENOTDIR: NOTDIR, errno.EISDIR: ISDIR, errno.EINVAL: INVAL, errno.ENOTEMPTY: NOTEMPTY}
MAX_TRANSFER = 1 << 20


class Reader:
    def __init__(self, data):
        self.data, self.at = data, 0

    def u32(self):
        value = struct.unpack_from('>I', self.data, self.at)[0]
        self.at += 4
        return value

    def u64(self):
        value = struct.unpack_from('>Q', self.data, self.at)[0]
        self.at += 8
        return value

    def opaque(self, limit=MAX_TRANSFER):
        length = self.u32()
        if length > limit or self.at + length > len(self.data):
            raise ValueError('bad length')
        value = self.data[self.at:self.at+length]
        self.at += (length+3) & ~3
        return value

    def name(self):
        return self.opaque(1024).decode('utf-8', 'surrogateescape')


def u32(value):
    return struct.pack('>I', value & 0xffffffff)


def u64(value):
    return struct.pack('>Q', value)


def opaque(value):
    return u32(len(value)) + value + b'\0'*(-len(value) & 3)


class Share:
    def __init__(self, root):
        self.root = os.path.realpath(root)
        self.handles = {}
        self.add(self.root)

    def add(self, path):
        handle = hashlib.sha256(path.encode('utf-8', 'surrogateescape')).digest()
        self.handles[handle] = path
        return handle

    def path(self, handle):
        path = self.handles.get(handle)
        if path is None:
            raise OSError(errno.ESTALE, 'stale')
        return path

    def inside(self, path):
        """Refuses a path whose existing part leads outside, as a symlink planted by the guest could."""
        resolved = os.path.realpath(path)
        if resolved != self.root and not resolved.startswith(self.root + '/'):
            raise OSError(errno.EACCES, 'outside the share')
        return path

    def entry(self, directory, name):
        """For calls that act on the entry itself, not what a symlink there leads to."""
        if name in ('', '.', '..') or '/' in name:
            raise OSError(errno.EACCES, 'bad name')
        return os.path.join(self.inside(directory), name)

    def child(self, directory, name):
        return directory if name == '.' else self.inside(self.entry(directory, name))


def attributes(path, info=None):
    info = info or os.lstat(path)
    kinds = {stat.S_IFREG: 1, stat.S_IFDIR: 2, stat.S_IFLNK: 5}
    kind = kinds.get(stat.S_IFMT(info.st_mode), 1)

    def time(value):
        return u32(int(value)) + u32(int((value % 1) * 1e9))
    return (u32(kind) + u32(stat.S_IMODE(info.st_mode)) + u32(info.st_nlink) + u32(os.getuid()) + u32(os.getgid()) +
            u64(info.st_size) + u64(info.st_blocks*512) + u32(0) + u32(0) + u64(1) + u64(info.st_ino) +
            time(info.st_atime) + time(info.st_mtime) + time(info.st_ctime))


def post(path):
    try:
        return u32(1) + attributes(path)
    except OSError:
        return u32(0)


WCC_NONE = u32(0)


class Server:
    def __init__(self, root):
        self.share = Share(root)
        self.writes = {}
        self.calls = {}

    def status(self, error):
        return ERRORS.get(error.errno, STALE if error.errno == errno.ESTALE else IO)

    def handle_of(self, path):
        return u32(1) + opaque(self.share.add(path)) + u32(1) + attributes(path)

    def set_attributes(self, reader, path):
        mode = uid = gid = size = atime = mtime = None
        if reader.u32():
            mode = reader.u32()
        if reader.u32():
            uid = reader.u32()
        if reader.u32():
            gid = reader.u32()
        if reader.u32():
            size = reader.u64()
        how = reader.u32()
        if how == 2:
            atime = reader.u32() + reader.u32()/1e9
        how_m = reader.u32()
        if how_m == 2:
            mtime = reader.u32() + reader.u32()/1e9
        if path is None:
            return mode
        # A listing hands out a handle for any symlink, and these calls would follow it.
        self.share.inside(path)
        if mode is not None:
            os.chmod(path, mode & 0o7777)
        if size is not None:
            os.truncate(path, size)
        if atime is not None or mtime is not None or how == 1 or how_m == 1:
            info = os.stat(path)
            os.utime(path, (atime if atime is not None else info.st_atime, mtime if mtime is not None else info.st_mtime))
        return mode

    def nfs(self, procedure, reader):
        self.calls[procedure] = self.calls.get(procedure, 0) + 1
        share = self.share
        if procedure == 0:
            return b''
        if procedure == 1:
            return u32(OK) + attributes(share.path(reader.opaque(64)))
        if procedure == 2:
            path = share.path(reader.opaque(64))
            self.set_attributes(reader, path)
            return u32(OK) + WCC_NONE + post(path)
        if procedure == 3:
            directory = share.path(reader.opaque(64))
            path = share.child(directory, reader.name())
            os.lstat(path)
            return u32(OK) + opaque(share.add(path)) + post(path) + post(directory)
        if procedure == 4:
            path = share.path(reader.opaque(64))
            return u32(OK) + post(path) + u32(reader.u32())
        if procedure == 5:
            path = share.path(reader.opaque(64))
            return u32(OK) + post(path) + opaque(os.readlink(path).encode('utf-8', 'surrogateescape'))
        if procedure == 6:
            path = share.path(reader.opaque(64))
            offset, count = reader.u64(), min(reader.u32(), MAX_TRANSFER)
            share.inside(path)
            with open(path, 'rb') as file:
                data = os.pread(file.fileno(), count, offset)
            return u32(OK) + post(path) + u32(len(data)) + u32(1 if len(data) < count else 0) + opaque(data)
        if procedure == 7:
            path = share.path(reader.opaque(64))
            offset, count, stable = reader.u64(), reader.u32(), reader.u32()
            data = reader.opaque()
            share.inside(path)
            descriptor = os.open(path, os.O_WRONLY)
            try:
                os.pwrite(descriptor, data[:count], offset)
            finally:
                os.close(descriptor)
            return u32(OK) + WCC_NONE + post(path) + u32(min(count, len(data))) + u32(2) + b'lightclk'
        if procedure == 8:
            directory = share.path(reader.opaque(64))
            path = share.child(directory, reader.name())
            how = reader.u32()
            mode = self.set_attributes(reader, None) if how != 2 else None
            flags = os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW | (os.O_EXCL if how else 0)
            os.close(os.open(path, flags, (mode or 0o644) & 0o777))
            return u32(OK) + self.handle_of(path) + WCC_NONE + post(directory)
        if procedure == 9:
            directory = share.path(reader.opaque(64))
            path = share.child(directory, reader.name())
            mode = self.set_attributes(reader, None)
            os.mkdir(path, (mode or 0o755) & 0o777)
            return u32(OK) + self.handle_of(path) + WCC_NONE + post(directory)
        if procedure == 10:
            directory = share.path(reader.opaque(64))
            path = share.child(directory, reader.name())
            self.set_attributes(reader, None)
            target = reader.name()
            # Only ever followed through inside(), so a link out of the share is inert.
            os.symlink(target, path)
            return u32(OK) + self.handle_of(path) + WCC_NONE + post(directory)
        if procedure in (12, 13):
            directory = share.path(reader.opaque(64))
            path = share.entry(directory, reader.name())
            (os.unlink if procedure == 12 else os.rmdir)(path)
            return u32(OK) + WCC_NONE + post(directory)
        if procedure == 14:
            source_directory = share.path(reader.opaque(64))
            source = share.entry(source_directory, reader.name())
            target_directory = share.path(reader.opaque(64))
            target = share.entry(target_directory, reader.name())
            os.rename(source, target)
            share.add(target)
            return u32(OK) + WCC_NONE + WCC_NONE + WCC_NONE + WCC_NONE
        if procedure == 15:
            source = share.inside(share.path(reader.opaque(64)))
            directory = share.path(reader.opaque(64))
            target = share.child(directory, reader.name())
            os.link(source, target)
            return u32(OK) + post(source) + WCC_NONE + post(directory)
        if procedure in (16, 17):
            directory = share.path(reader.opaque(64))
            cookie = reader.u64()
            reader.u64()
            limit = reader.u32()
            if procedure == 17:
                reader.u32()
            names = ['.', '..'] + sorted(os.listdir(directory))
            entries = b''
            done = True
            for index in range(cookie, len(names)):
                name = names[index]
                path = directory if name == '.' else os.path.dirname(directory) if name == '..' else os.path.join(directory, name)
                if name == '..' and directory == share.root:
                    path = directory
                encoded = name.encode('utf-8', 'surrogateescape')
                info = os.lstat(path)
                entry = u32(1) + u64(info.st_ino) + opaque(encoded) + u64(index+1)
                if procedure == 17:
                    entry += post(path) + (u32(1) + opaque(share.add(path)))
                if len(entries) + len(entry) + 256 > limit:
                    done = False
                    break
                entries += entry
            return u32(OK) + post(directory) + b'\0'*8 + entries + u32(0) + u32(1 if done else 0)
        if procedure == 18:
            path = share.path(reader.opaque(64))
            info = os.statvfs(path)
            total, free = info.f_blocks*info.f_frsize, info.f_bavail*info.f_frsize
            return u32(OK) + post(path) + u64(total) + u64(free) + u64(free) + u64(info.f_files) + u64(info.f_favail) + u64(info.f_favail) + u32(0)
        if procedure == 19:
            path = share.path(reader.opaque(64))
            sizes = u32(MAX_TRANSFER) + u32(MAX_TRANSFER) + u32(4096) + u32(MAX_TRANSFER) + u32(MAX_TRANSFER) + u32(4096) + u32(4096)
            return u32(OK) + post(path) + sizes + u64(1 << 62) + u32(0) + u32(1) + u32(0x1b)
        if procedure == 20:
            path = share.path(reader.opaque(64))
            return u32(OK) + post(path) + u32(1024) + u32(255) + u32(1) + u32(1) + u32(0) + u32(1)
        if procedure == 21:
            path = share.path(reader.opaque(64))
            return u32(OK) + WCC_NONE + post(path) + b'lightclk'
        return None

    def mount(self, procedure, reader):
        if procedure == 0:
            return b''
        if procedure == 1:
            reader.name()
            return u32(OK) + opaque(self.share.add(self.share.root)) + u32(1) + u32(1)
        if procedure == 3:
            return b''
        if procedure == 5:
            return u32(1) + opaque(b'/') + u32(0) + u32(0)
        return None

    def call(self, message):
        reader = Reader(message)
        try:
            xid, kind, _, program, version, procedure = (reader.u32() for _ in range(6))
            reader.opaque(400)
            reader.opaque(400)
        except (ValueError, struct.error):
            return None
        head = u32(xid) + u32(1) + u32(0) + u32(0) + u32(0)
        if kind != 0:
            return None
        if program == NFS_PROGRAM and version == 3:
            handler = self.nfs
        elif program == MOUNT_PROGRAM and version in (1, 3):
            handler = self.mount
        else:
            return head + u32(1)
        try:
            body = handler(procedure, reader)
        except OSError as error:
            # A failed call still needs its op's shape: status, then empty attributes, which covers each we return early.
            return head + u32(0) + u32(self.status(error)) + WCC_NONE + WCC_NONE
        except (ValueError, struct.error):
            return head + u32(4)
        if body is None:
            return head + u32(3)
        return head + u32(0) + body

    def serve_connection(self, connection):
        with connection:
            while True:
                message = b''
                while True:
                    header = recv_exactly(connection, 4)
                    if not header:
                        return
                    word = struct.unpack('>I', header)[0]
                    size = word & 0x7fffffff
                    if size > 2*MAX_TRANSFER:
                        return
                    message += recv_exactly(connection, size)
                    if word & 0x80000000:
                        break
                reply = self.call(message)
                if reply is not None:
                    connection.sendall(struct.pack('>I', 0x80000000 | len(reply)) + reply)


def recv_exactly(connection, size):
    data = b''
    while len(data) < size:
        part = connection.recv(size-len(data))
        if not part:
            return b''
        data += part
    return data


def listen(root, port=0):
    server = Server(root)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Loopback only. slirp brings the guest here, and nothing else should be able to.
    listener.bind(('127.0.0.1', port))
    listener.listen(8)

    def accept():
        while True:
            try:
                connection, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=server.serve_connection, args=(connection,), daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    return server, listener, listener.getsockname()[1]


def self_test():
    with tempfile.TemporaryDirectory() as parent:
        root = os.path.join(parent, 'share')
        os.mkdir(root)
        secret = os.path.join(parent, 'secret')
        open(secret, 'w').write('secret')
        server, listener, port = listen(root)
        connection = socket.create_connection(('127.0.0.1', port))
        xid = [0]

        def call(program, procedure, arguments=b'', version=3):
            xid[0] += 1
            message = (u32(xid[0]) + u32(0) + u32(2) + u32(program) + u32(version) + u32(procedure) + opaque(b'') + opaque(b'')
                       + arguments)
            connection.sendall(struct.pack('>I', 0x80000000 | len(message)) + message)
            size = struct.unpack('>I', recv_exactly(connection, 4))[0] & 0x7fffffff
            return Reader(recv_exactly(connection, size)[24:])
        mount = call(MOUNT_PROGRAM, 1, opaque(b'/'))
        assert mount.u32() == OK
        root_handle = mount.opaque(64)
        assert call(NFS_PROGRAM, 1, opaque(root_handle)).u32() == OK
        # Create, write, read back.
        sattr = u32(0)*4 + u32(0)*2
        created = call(NFS_PROGRAM, 8, opaque(root_handle) + opaque(b'a.txt') + u32(0) + sattr)
        assert created.u32() == OK
        assert created.u32() == 1
        handle = created.opaque(64)
        assert call(NFS_PROGRAM, 7, opaque(handle) + u64(0) + u32(5) + u32(2) + opaque(b'hello')).u32() == OK
        read = call(NFS_PROGRAM, 6, opaque(handle) + u64(0) + u32(100))
        assert read.u32() == OK
        assert read.u32() == 1
        read.at += 84
        assert read.u32() == 5
        assert read.u32() == 1
        assert read.opaque() == b'hello'
        assert open(os.path.join(root, 'a.txt')).read() == 'hello', 'the host sees the real file'
        # Escapes: .., an absolute-looking name, an unknown handle, and a symlink out.
        assert call(NFS_PROGRAM, 3, opaque(root_handle) + opaque(b'..')).u32() == ACCES
        assert call(NFS_PROGRAM, 3, opaque(root_handle) + opaque(b'../secret')).u32() == ACCES
        assert call(NFS_PROGRAM, 1, opaque(b'\0'*32)).u32() == STALE
        os.symlink(secret, os.path.join(root, 'link'))
        assert call(NFS_PROGRAM, 3, opaque(root_handle) + opaque(b'link')).u32() == ACCES
        os.symlink(parent, os.path.join(root, 'dirlink'))
        assert call(NFS_PROGRAM, 3, opaque(root_handle) + opaque(b'dirlink')).u32() == ACCES
        # A symlink the guest makes, pointed out, can't be read through.
        link = call(NFS_PROGRAM, 10, opaque(root_handle) + opaque(b'planted') + sattr + opaque(secret.encode()))
        assert link.u32() == OK
        assert call(NFS_PROGRAM, 3, opaque(root_handle) + opaque(b'planted')).u32() == ACCES
        # A handle for that symlink, from a listing, can't change what it points at.
        planted = server.share.add(os.path.join(root, 'planted'))
        before = os.stat(secret).st_mode
        chmod = u32(1) + u32(0o777) + u32(0)*5
        assert call(NFS_PROGRAM, 2, opaque(planted) + chmod + u32(0)).u32() == ACCES
        assert os.stat(secret).st_mode == before
        assert call(NFS_PROGRAM, 6, opaque(planted) + u64(0) + u32(10)).u32() == ACCES
        # Rename, and removal that a name can't redirect.
        assert call(NFS_PROGRAM, 14, opaque(root_handle) + opaque(b'a.txt') + opaque(root_handle) + opaque(b'b.txt')).u32() == OK
        assert os.path.exists(os.path.join(root, 'b.txt'))
        assert call(NFS_PROGRAM, 12, opaque(root_handle) + opaque(b'../secret')).u32() == ACCES
        assert os.path.exists(secret)
        assert call(NFS_PROGRAM, 14, opaque(root_handle) + opaque(b'b.txt') + opaque(root_handle) + opaque(b'../out')).u32() == ACCES
        assert not os.path.exists(os.path.join(parent, 'out'))
        # Removing a planted link removes the link, not its target.
        assert call(NFS_PROGRAM, 12, opaque(root_handle) + opaque(b'planted')).u32() == OK
        assert os.path.exists(secret)
        # Directory listing runs and ends.
        listing = call(NFS_PROGRAM, 17, opaque(root_handle) + u64(0) + u64(0) + u32(65536) + u32(65536))
        assert listing.u32() == OK
        # Truncated and lying requests don't kill the server.
        connection.sendall(struct.pack('>I', 0x80000000 | 8) + b'\0'*8)
        connection.close()
        connection = socket.create_connection(('127.0.0.1', port))
        assert call(NFS_PROGRAM, 0).at == 0
        assert call(NFS_PROGRAM, 1, u32(1 << 30)).data == b''
        listener.close()
    print('nfs3-server self-test passed')


if __name__ == '__main__':
    if '--self-test' in sys.argv:
        self_test()
    else:
        port = int(sys.argv[sys.argv.index('--port')+1]) if '--port' in sys.argv else 0
        _, _, bound = listen(sys.argv[1], port)
        print(f'port {bound}', flush=True)
        threading.Event().wait()

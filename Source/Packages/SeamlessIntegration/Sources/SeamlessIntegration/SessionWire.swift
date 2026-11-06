import Foundation

/// The wire between the session and the guest's tool, as `probes/seamless-wire.h` defines it for the guest's side. Only what
/// a session reads is decoded here. What it passes on from a proxy's input view is already encoded.
public enum SessionWire {
    public static let magic: UInt32 = 0x314D_5753
    public static let headerSize = 12
    static let maximumDimension: UInt32 = 8192
    static let maximumText = 1024
    static let maximumData = 16 * 1024 * 1024
    public static let documentPiece = 32768
    public static let documentFixed = 8

    public enum Kind: UInt16 {
        case hello = 1, window = 2, frame = 3, gone = 4
        case pointer = 16, key = 17, focus = 18
        case menu = 48, menuPress = 49, document = 50, quitApp = 51, appGone = 52
        case dragCancel = 53, dragQuery = 54, dragState = 55, dragSend = 56, appState = 57, crop = 58, overlay = 59, surfaceOrigin = 60, covers = 61
    }

    public struct Window: Equatable, Sendable {
        public var id, pid: UInt32
        public var level: Int32
        public var x, y, width, height: Int32
        public var pixelWidth, pixelHeight: UInt32
        public var order, group, alpha, margin: UInt32
        public var title, owner: String
    }

    public struct Frame: Equatable, Sendable {
        public var window, fullWidth, fullHeight, x, y, width, height: UInt32
        /// Where the pixels start in the bytes given to `parse`: BGRA, premultiplied, top row first, `width * 4` a row.
        public var pixelOffset: Int
    }

    public struct DocumentPiece: Equatable, Sendable {
        public var id: UInt32
        public var isLast: Bool
        public var flags: UInt8
        public var payload: Data
    }

    public enum Message: Equatable, Sendable {
        case hello(version: UInt32)
        case window(Window)
        case frame(Frame)
        case gone(UInt32)
        case menu(Data)
        case document(DocumentPiece)
        case dragState(Data)
        case appState(Data)
        case appGone
        case crop(UInt32)
        case overlay(UInt32)
        case surfaceOrigin(UInt32, x: Int32, y: Int32)
        case covers(UInt32, [CGRect])
    }

    public enum Parsed: Equatable, Sendable {
        case message(Message, used: Int)
        /// `size` when the header has said, otherwise nil.
        case needMore(size: Int?)
        case bad
    }

    /// `bytes` comes from a guest, so everything here is checked against it, and nothing is trusted to fit.
    public static func parse(_ bytes: UnsafeRawBufferPointer) -> Parsed {
        guard bytes.count >= headerSize else {
            if bytes.count >= 4, u32(bytes, 0) != magic { return .bad }
            return .needMore(size: nil)
        }
        guard u32(bytes, 0) == magic, u16(bytes, 6) == 0 else { return .bad }
        let length = Int(u32(bytes, 8))
        guard let kind = Kind(rawValue: u16(bytes, 4)), length <= 8192 * 8192 * 4 + 32 else { return .bad }
        let used = headerSize + length
        switch kind {
        case .menu, .dragState, .appState, .document:
            guard length > 0, length <= maximumData else { return .bad }
        case .hello, .gone, .appGone, .crop, .overlay:
            guard length == 4 else { return .bad }
        case .surfaceOrigin:
            guard length == 12 else { return .bad }
        case .covers:
            guard length >= 8, length <= 8 + 32 * 16, (length - 8) % 16 == 0 else { return .bad }
        case .window:
            guard length >= 56, length <= 56 + 2 * maximumText else { return .bad }
        case .frame:
            guard length >= 32 else { return .bad }
        default:
            return .bad  // Only ever host to guest.
        }
        guard bytes.count >= used else { return .needMore(size: used) }
        let body = headerSize
        switch kind {
        case .hello: return .message(.hello(version: u32(bytes, body)), used: used)
        case .gone: return .message(.gone(u32(bytes, body)), used: used)
        case .crop: return .message(.crop(u32(bytes, body)), used: used)
        case .overlay: return .message(.overlay(u32(bytes, body)), used: used)
        case .covers:
            let rects = (0..<(length - 8) / 16).map { index -> CGRect in
                func value(_ field: Int) -> Double {
                    Double(Int32(bitPattern: u32(bytes, body + 8 + index * 16 + field * 4)))
                }
                return CGRect(x: value(0), y: value(1), width: value(2), height: value(3))
            }
            guard Int(u32(bytes, body + 4)) == rects.count else { return .bad }
            return .message(.covers(u32(bytes, body), rects), used: used)
        case .surfaceOrigin:
            return .message(
                .surfaceOrigin(
                    u32(bytes, body), x: Int32(bitPattern: u32(bytes, body + 4)), y: Int32(bitPattern: u32(bytes, body + 8))),
                used: used)
        case .appGone: return .message(.appGone, used: used)
        case .menu: return .message(.menu(data(bytes, body, length)), used: used)
        case .dragState: return .message(.dragState(data(bytes, body, length)), used: used)
        case .appState: return .message(.appState(data(bytes, body, length)), used: used)
        case .document:
            guard length >= documentFixed else { return .bad }
            let skip = documentFixed + Int(u16(bytes, body + 6))
            guard skip <= length else { return .bad }
            return .message(
                .document(
                    DocumentPiece(
                        id: u32(bytes, body), isLast: bytes[body + 4] != 0, flags: bytes[body + 5],
                        payload: data(bytes, body + skip, length - skip))), used: used)
        case .window:
            let titleLength = Int(u16(bytes, body + 36))
            let ownerLength = Int(u16(bytes, body + 38))
            guard titleLength <= maximumText, ownerLength <= maximumText, 56 + titleLength + ownerLength == length,
                u32(bytes, body + 28) <= maximumDimension, u32(bytes, body + 32) <= maximumDimension
            else { return .bad }
            return .message(
                .window(
                    Window(
                        id: u32(bytes, body), pid: u32(bytes, body + 4), level: Int32(bitPattern: u32(bytes, body + 8)),
                        x: Int32(bitPattern: u32(bytes, body + 12)), y: Int32(bitPattern: u32(bytes, body + 16)),
                        width: Int32(bitPattern: u32(bytes, body + 20)),
                        height: Int32(bitPattern: u32(bytes, body + 24)),
                        pixelWidth: u32(bytes, body + 28), pixelHeight: u32(bytes, body + 32),
                        order: u32(bytes, body + 40),
                        group: u32(bytes, body + 44), alpha: u32(bytes, body + 48), margin: u32(bytes, body + 52),
                        title: String(decoding: data(bytes, body + 56, titleLength), as: UTF8.self),
                        owner: String(decoding: data(bytes, body + 56 + titleLength, ownerLength), as: UTF8.self))),
                used: used)
        case .frame:
            let frame = Frame(
                window: u32(bytes, body), fullWidth: u32(bytes, body + 8), fullHeight: u32(bytes, body + 12),
                x: u32(bytes, body + 16), y: u32(bytes, body + 20), width: u32(bytes, body + 24),
                height: u32(bytes, body + 28), pixelOffset: body + 32)
            guard frame.fullWidth > 0, frame.fullHeight > 0, frame.fullWidth <= maximumDimension,
                frame.fullHeight <= maximumDimension, frame.x <= frame.fullWidth, frame.y <= frame.fullHeight,
                frame.height > 0, frame.width <= frame.fullWidth - frame.x, frame.height <= frame.fullHeight - frame.y,
                length == 32 + Int(frame.width) * Int(frame.height) * 4
            else { return .bad }
            return .message(.frame(frame), used: used)
        default: return .bad
        }
    }

    // MARK: To the guest

    public static func header(_ kind: Kind, length: Int) -> Data {
        var out = Data()
        put32(&out, magic)
        put16(&out, kind.rawValue)
        put16(&out, 0)
        put32(&out, UInt32(length))
        return out
    }

    public static func value(_ kind: Kind, _ value: UInt32 = 0) -> Data {
        var out = header(kind, length: 4)
        put32(&out, value)
        return out
    }

    public static func text(_ kind: Kind, _ text: String) -> Data {
        let bytes = Data(text.utf8)
        return header(kind, length: bytes.count) + bytes
    }

    /// `SWM_MOVE` 0, `SWM_DOWN` 1, `SWM_UP` 2, `SWM_DRAG` 3. In guest screen points.
    public static func pointer(kind: UInt8, x: Double, y: Double) -> Data {
        var out = header(.pointer, length: 20)
        put32(&out, 0)
        out.append(contentsOf: [kind, 0, 1, 0])
        put32(&out, UInt32(bitPattern: Int32(x * 16)))
        put32(&out, UInt32(bitPattern: Int32(y * 16)))
        put32(&out, 0)
        return out
    }

    public static func key(code: UInt16, down: Bool) -> Data {
        var out = header(.key, length: 8)
        put16(&out, code)
        out.append(contentsOf: [down ? 1 : 0, 0])
        put32(&out, 0)
        return out
    }

    public static let dragFlag: UInt8 = 1
    public static let dragStartFlag: UInt8 = 2

    /// A whole file as document pieces. Without flags the guest's app opens it.
    public static func documentPieces(id: UInt32, name: String, flags: UInt8, contents: Data) -> [Data] {
        let nameBytes = Data(name.utf8)
        var pieces: [Data] = []
        var offset = contents.startIndex
        repeat {
            let end = min(offset + documentPiece, contents.endIndex)
            var out = header(.document, length: documentFixed + nameBytes.count + (end - offset))
            put32(&out, id)
            out.append(contentsOf: [end == contents.endIndex ? 1 : 0, flags])
            put16(&out, UInt16(nameBytes.count))
            out.append(nameBytes)
            out.append(contents[offset..<end])
            pieces.append(out)
            offset = end
        } while offset < contents.endIndex
        return pieces
    }

    public static func dragSend(id: UInt32, path: String) -> Data {
        let bytes = Data(path.utf8)
        var out = header(.dragSend, length: 4 + bytes.count)
        put32(&out, id)
        return out + bytes
    }

    private static func put16(_ out: inout Data, _ value: UInt16) {
        out.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)])
    }
    private static func put32(_ out: inout Data, _ value: UInt32) {
        put16(&out, UInt16(value & 0xffff))
        put16(&out, UInt16(value >> 16))
    }
    private static func u16(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    private static func u32(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> UInt32 {
        UInt32(u16(bytes, at)) | UInt32(u16(bytes, at + 2)) << 16
    }
    private static func data(_ bytes: UnsafeRawBufferPointer, _ at: Int, _ count: Int) -> Data {
        Data(bytes[at..<(at + count)])
    }
}

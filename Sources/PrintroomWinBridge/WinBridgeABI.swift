import Foundation
import PrintroomCore

private func allocCString(_ s: String) -> UnsafeMutablePointer<CChar>? {
  s.withCString { cstr in
    let len = strlen(cstr) + 1
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: len)
    buf.initialize(from: cstr, count: len)
    return buf
  }
}

@_cdecl("pr_bridge_verify_resources")
public func pr_bridge_verify_resources(
  _ assetsRootPtr: UnsafePointer<CChar>?,
  _ outMessagePtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  let root = assetsRootPtr.map { String(cString: $0) }
  do {
    let summary = try WinAppAssets.verifyResources(explicitRoot: root)
    outMessagePtr?.pointee = allocCString(summary)
    return 0
  } catch {
    outMessagePtr?.pointee = allocCString(error.localizedDescription)
    return -1
  }
}

@_cdecl("pr_bridge_create")
public func pr_bridge_create(
  _ assetsRootPtr: UnsafePointer<CChar>?,
  _ outErrorPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> UnsafeMutableRawPointer? {
  let root = assetsRootPtr.map { String(cString: $0) }
  do {
    let controller = try WinEditorController(assetsRoot: root)
    return Unmanaged.passRetained(controller).toOpaque()
  } catch {
    outErrorPtr?.pointee = allocCString(error.localizedDescription)
    return nil
  }
}

@_cdecl("pr_bridge_destroy")
public func pr_bridge_destroy(_ handle: UnsafeMutableRawPointer?) {
  guard let handle else { return }
  Unmanaged<WinEditorController>.fromOpaque(handle).release()
}

@_cdecl("pr_bridge_set_hwnd")
public func pr_bridge_set_hwnd(_ handle: UnsafeMutableRawPointer?, _ hwnd: Int) {
  guard let handle else { return }
  let controller = Unmanaged<WinEditorController>.fromOpaque(handle).takeUnretainedValue()
  controller.setHWND(hwnd)
}

@_cdecl("pr_bridge_dispatch")
public func pr_bridge_dispatch(
  _ handle: UnsafeMutableRawPointer?,
  _ commandJsonPtr: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
  guard let handle, let commandJsonPtr else {
    return allocCString("{\"ok\":false,\"error\":\"Invalid bridge handle or command\"}")
  }
  let controller = Unmanaged<WinEditorController>.fromOpaque(handle).takeUnretainedValue()
  let reply = controller.dispatch(json: String(cString: commandJsonPtr))
  return allocCString(reply)
}

@_cdecl("pr_bridge_poll_state")
public func pr_bridge_poll_state(
  _ handle: UnsafeMutableRawPointer?,
  _ lastRevision: UInt64
) -> UnsafeMutablePointer<CChar>? {
  guard let handle else { return nil }
  let controller = Unmanaged<WinEditorController>.fromOpaque(handle).takeUnretainedValue()
  guard let json = controller.pollStateIfChanged(lastRevision: lastRevision) else { return nil }
  return allocCString(json)
}

@_cdecl("pr_bridge_copy_preview_bgra")
public func pr_bridge_copy_preview_bgra(
  _ handle: UnsafeMutableRawPointer?,
  _ outWidth: UnsafeMutablePointer<Int32>?,
  _ outHeight: UnsafeMutablePointer<Int32>?,
  _ outRevision: UnsafeMutablePointer<UInt64>?,
  _ destBuffer: UnsafeMutablePointer<UInt8>?,
  _ destCapacity: Int
) -> Int32 {
  guard let handle, let outWidth, let outHeight, let outRevision else { return 0 }
  let controller = Unmanaged<WinEditorController>.fromOpaque(handle).takeUnretainedValue()
  return controller.copyPreviewBGRA(
    outWidth: outWidth, outHeight: outHeight, outRevision: outRevision,
    destBuffer: destBuffer, destCapacity: destCapacity)
}

@_cdecl("pr_bridge_copy_thumbnail_bgra")
public func pr_bridge_copy_thumbnail_bgra(
  _ handle: UnsafeMutableRawPointer?,
  _ frameIdPtr: UnsafePointer<CChar>?,
  _ outWidth: UnsafeMutablePointer<Int32>?,
  _ outHeight: UnsafeMutablePointer<Int32>?,
  _ destBuffer: UnsafeMutablePointer<UInt8>?,
  _ destCapacity: Int
) -> Int32 {
  guard let handle, let frameIdPtr, let outWidth, let outHeight else { return 0 }
  let controller = Unmanaged<WinEditorController>.fromOpaque(handle).takeUnretainedValue()
  return controller.copyThumbnailBGRA(
    frameIDString: String(cString: frameIdPtr),
    outWidth: outWidth, outHeight: outHeight,
    destBuffer: destBuffer, destCapacity: destCapacity)
}

@_cdecl("pr_bridge_free_string")
public func pr_bridge_free_string(_ ptr: UnsafeMutablePointer<CChar>?) {
  ptr?.deallocate()
}

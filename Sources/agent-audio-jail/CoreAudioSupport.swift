import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String { "\(operation) failed (OSStatus \(status))" }
}

func checkStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
}

func makePropertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func readProperty<Value: BitwiseCopyable>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: Value) throws -> Value {
    var address = makePropertyAddress(selector)
    var size = UInt32(MemoryLayout<Value>.size)
    var value = initial
    try checkStatus(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "read property \(selector)")
    return value
}

func readObjectIDList(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var address = makePropertyAddress(selector)
    var size: UInt32 = 0
    try checkStatus(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "size of property \(selector)")
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    try checkStatus(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &objectIDs), "read property \(selector)")
    return Array(objectIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func readStringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var address = makePropertyAddress(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    try checkStatus(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "read property \(selector)")
    return value?.takeRetainedValue() as String? ?? ""
}

/// A process that has connected to coreaudiod. Only these can be tapped.
struct AudioClient {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
}

func listAudioClients() throws -> [AudioClient] {
    let objectIDs = try readObjectIDList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    return objectIDs.compactMap { objectID in
        guard let pid = try? readProperty(objectID, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else {
            return nil
        }
        let bundleID = (try? readStringProperty(objectID, kAudioProcessPropertyBundleID)) ?? ""
        let isRunningOutput = ((try? readProperty(objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
        return AudioClient(objectID: objectID, pid: pid, bundleID: bundleID, isRunningOutput: isRunningOutput)
    }
}

func readDefaultOutputDeviceUID() throws -> String {
    let deviceID = try readProperty(
        AudioObjectID(kAudioObjectSystemObject),
        kAudioHardwarePropertyDefaultOutputDevice,
        initial: AudioDeviceID(kAudioObjectUnknown)
    )
    return try readStringProperty(deviceID, kAudioDevicePropertyDeviceUID)
}

func addSystemPropertyListener(_ selector: AudioObjectPropertySelector, queue: DispatchQueue, handler: @escaping () -> Void) throws {
    var address = makePropertyAddress(selector)
    try checkStatus(
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in handler() },
        "listen for property \(selector)"
    )
}

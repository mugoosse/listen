// Read and set the default input and output devices, for `verify_tap_routes.sh`.
//
// The system audio tap rides whichever device is the default output, so the
// question "does this Mac record the far side reliably" has a different answer
// per route and there is no way to ask it from the shell. `SwitchAudioSource`
// is not a dependency this repo wants, and it cannot set the input and the
// output together, which is the case that matters: the AirPods failures on
// 2026-09-01 had the same device on both.
//
// Usage:
//   audioroute list                 every device, with in/out channel counts
//   audioroute get                  the current default input and output ids
//   audioroute set-out <id>         default output
//   audioroute set-in <id>          default input
//   audioroute find <substring>     ids of devices whose name matches
//
// Exits non-zero when a set does not take. That is not paranoia: setting the
// default output to the Microsoft Teams virtual device returned `noErr` and
// silently left the default where it was, which invalidated a whole test run
// before anyone noticed. Every set is read back.

import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0,
                              count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func name(_ id: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let ok = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) == noErr
    }
    return ok ? value as String : "?"
}

func channels(_ id: AudioDeviceID, input: Bool) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration,
                       input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// "builtin", "bluetooth", "usb" and so on, so a report can group by route
/// without matching on product names that change with every pair of headphones.
func transport(_ id: AudioDeviceID) -> String {
    var addr = address(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
    else { return "unknown" }
    switch value {
    case UInt32(kAudioDeviceTransportTypeBuiltIn):     return "builtin"
    case UInt32(kAudioDeviceTransportTypeBluetooth),
         UInt32(kAudioDeviceTransportTypeBluetoothLE): return "bluetooth"
    case UInt32(kAudioDeviceTransportTypeUSB):         return "usb"
    case UInt32(kAudioDeviceTransportTypeThunderbolt): return "thunderbolt"
    case UInt32(kAudioDeviceTransportTypeAirPlay):     return "airplay"
    case UInt32(kAudioDeviceTransportTypeVirtual),
         UInt32(kAudioDeviceTransportTypeAggregate):   return "virtual"
    case UInt32(kAudioDeviceTransportTypeDisplayPort),
         UInt32(kAudioDeviceTransportTypeHDMI):        return "display"
    default:                                           return "other"
    }
}

func defaultDevice(input: Bool) -> AudioDeviceID {
    var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &addr, 0, nil, &size, &id)
    return id
}

/// Set, then read back. A `noErr` here is not evidence that anything moved.
func setDefault(_ id: AudioDeviceID, input: Bool) -> Bool {
    var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice)
    var value = id
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    guard status == noErr else {
        FileHandle.standardError.write(Data("set failed (status \(status))\n".utf8))
        return false
    }
    // The device needs a moment to become the default, and a read straight
    // back can still report the old one.
    for _ in 0..<20 {
        if defaultDevice(input: input) == id { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let still = defaultDevice(input: input)
    let message = "set returned noErr but the default is still \(still) (\(name(still)))\n"
    FileHandle.standardError.write(Data(message.utf8))
    return false
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "list" {
case "list":
    for id in allDevices() {
        let ins = channels(id, input: true), outs = channels(id, input: false)
        print("\(id)\t\(transport(id))\tin:\(ins)\tout:\(outs)\t\(name(id))")
    }
case "get":
    let out = defaultDevice(input: false), input = defaultDevice(input: true)
    print("out\t\(out)\t\(transport(out))\t\(name(out))")
    print("in\t\(input)\t\(transport(input))\t\(name(input))")
case "find":
    guard args.count > 1 else { exit(2) }
    let needle = args[1].lowercased()
    for id in allDevices() where name(id).lowercased().contains(needle) {
        print("\(id)\t\(transport(id))\tin:\(channels(id, input: true))"
              + "\tout:\(channels(id, input: false))\t\(name(id))")
    }
case "set-out", "set-in":
    guard args.count > 1, let id = AudioDeviceID(args[1]) else { exit(2) }
    exit(setDefault(id, input: args[0] == "set-in") ? 0 : 1)
default:
    FileHandle.standardError.write(Data("usage: audioroute list|get|find <s>|set-out <id>|set-in <id>\n".utf8))
    exit(2)
}

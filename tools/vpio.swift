// A voice-processing session, held open on the default devices, and nothing
// else. This is what a WhatsApp or FaceTime call does to the built-in
// microphone, and the reason it is here rather than in a note is that it is
// the only way to put that microphone into its call state on demand.
//
// Measured on 2026-09-02 (macOS 26.6.2, MacBook Pro): for as long as any
// `kAudioUnitSubType_VoiceProcessingIO` client runs, `BuiltInMicrophoneDevice`
// reports a 3-channel input stream to *every* client, in place of the processed
// 1-channel stream it has the rest of the time. `MicRecorder` used to build an
// `AVAudioFormat` that is nil above two channels, threw four milliseconds into
// a 22 minute call, and never tried again. See `.agents/notes/capture.md`,
// "A call on the built-in microphone turns it into three channels".
//
//   swiftc -O -o .xcbuild/tools/vpio tools/vpio.swift
//   .xcbuild/tools/vpio [seconds] [--no-duck]
//                                      default 8; prints the built-in
//                                      microphone's input format once a
//                                      second while the unit runs. --no-duck
//                                      leaves other apps' output undimmed,
//                                      for level comparisons
//
// Then, in another shell while it runs:
//
//   LISTEN_LIBRARY=/tmp/scratch LISTEN_DEBUG=1 \
//       Listen.app/Contents/MacOS/Listen record --seconds 6
//
// should trace `mic format 48000 Hz, 3 ch` and still report a peak on the
// "you" track. It needs microphone permission for whatever terminal runs it,
// and it takes the default output as well, so a headset that is the default
// output will drop into its call profile for the duration.
import AudioToolbox
import CoreAudio
import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
// `--no-duck` keeps other apps' output at full volume. A voice-processing
// client ducks everything else by default, which is what a call does, but
// it also makes a played test phrase 30 dB quieter than the same phrase
// without the unit, so a level comparison needs it off.
let noDuck = CommandLine.arguments.contains("--no-duck")

func builtInMic() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    for id in ids {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &valueSize, &value) == noErr,
              let value else { continue }
        if (value.takeRetainedValue() as String) == "BuiltInMicrophoneDevice" { return id }
    }
    return nil
}

func micFormat() -> String {
    guard let id = builtInMic() else { return "no built-in microphone" }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &asbd) == noErr
    else { return "format unreadable" }
    return "\(asbd.mChannelsPerFrame) ch @ \(Int(asbd.mSampleRate)) Hz"
}

print("before: built-in microphone input is \(micFormat())")
var description = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_VoiceProcessingIO,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let component = AudioComponentFindNext(nil, &description) else {
    print("no voice-processing component"); exit(1)
}
var made: AudioUnit?
guard AudioComponentInstanceNew(component, &made) == noErr, let unit = made else {
    print("could not create the voice-processing unit"); exit(1)
}
var on: UInt32 = 1
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on,
                     UInt32(MemoryLayout<UInt32>.size))
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on,
                     UInt32(MemoryLayout<UInt32>.size))
if noDuck {
    var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false,
                                                          mDuckingLevel: .min)
    let set = AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                                   kAudioUnitScope_Global, 0, &ducking,
                                   UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
    print("ducking off: \(set)")
}
print("initialise: \(AudioUnitInitialize(unit))  start: \(AudioOutputUnitStart(unit))")
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    print("running: built-in microphone input is \(micFormat())")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 1)
}
AudioOutputUnitStop(unit)
AudioUnitUninitialize(unit)
AudioComponentInstanceDispose(unit)
Thread.sleep(forTimeInterval: 0.5)
print("after: built-in microphone input is \(micFormat())")

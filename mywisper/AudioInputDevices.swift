//
//  AudioInputDevices.swift
//  mywisper
//
//  Enumerates available audio input devices and lets the app point recording at a chosen
//  device. AVAudioRecorder always records from the *system default* input, so to honor a
//  user-picked microphone we temporarily switch the default input device for the duration of
//  a recording and restore it afterwards (see AudioRecorder).
//

import Foundation
import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Equatable {
    /// AVCaptureDevice.uniqueID, used as the stable persisted identifier.
    let uniqueID: String
    let name: String
    /// CoreAudio device ID, used to switch the system default input device.
    let coreAudioID: AudioDeviceID
    var id: String { uniqueID }
}

enum AudioInputDevices {
    /// All available audio input devices (microphones, USB interfaces, …).
    static func available() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.compactMap { device in
            guard let caID = coreAudioID(forUID: device.uniqueID) else { return nil }
            return AudioInputDevice(uniqueID: device.uniqueID, name: device.localizedName, coreAudioID: caID)
        }
    }

    /// CoreAudio ID of the current system default input device (so we can restore it later).
    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    /// Set the system default input device. Returns true on success.
    @discardableResult
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        )
        return status == noErr
    }

    /// Resolve an AVCaptureDevice uniqueID to its CoreAudio device ID by matching device UIDs.
    private static func coreAudioID(forUID uid: String) -> AudioDeviceID? {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for device in devices {
            guard hasInputStreams(device) else { continue }
            if deviceUID(device) == uid { return device }
        }
        return nil
    }

    /// True if the CoreAudio device exposes at least one input stream (i.e. is an input device).
    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        for buffer in abl where buffer.mNumberChannels > 0 { return true }
        return false
    }

    /// The CoreAudio UID string for a device, matching AVCaptureDevice.uniqueID.
    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (uid as String) : nil
    }
}

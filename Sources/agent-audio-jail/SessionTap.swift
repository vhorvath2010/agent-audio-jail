import AVFoundation
import CoreAudio
import Foundation

/// One Core Audio process tap over every audio client of a single agent session.
/// A muted tap keeps the audio off the speakers; a private aggregate device reads
/// the tapped audio so the session's ClipRecorder can save it.
final class SessionTap {
    let processObjectIDs: Set<AudioObjectID>
    let isMuted: Bool
    private let label: String
    private let recorder: ClipRecorder
    private let queue: DispatchQueue
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjectIDs: Set<AudioObjectID>, isMuted: Bool, label: String, recorder: ClipRecorder, queue: DispatchQueue) {
        self.processObjectIDs = processObjectIDs
        self.isMuted = isMuted
        self.label = label
        self.recorder = recorder
        self.queue = queue
    }

    func start() throws {
        do {
            try createTap()
            try startRecording()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs.sorted())
        description.uuid = UUID()
        description.name = "agent-audio-jail \(label)"
        description.isPrivate = true
        description.muteBehavior = isMuted ? .muted : .unmuted
        try checkStatus(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
    }

    private func startRecording() throws {
        let tapUID = try readStringProperty(tapID, kAudioTapPropertyUID)
        let outputDeviceUID = try readDefaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "agent-audio-jail \(label)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        try checkStatus(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
            "create aggregate device"
        )

        var streamDescription = try readProperty(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(operation: "read tap format", status: kAudioHardwareUnsupportedOperationError)
        }

        let recorder = recorder
        try checkStatus(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else {
                    return
                }
                recorder.append(buffer)
            },
            "create IO proc"
        )
        try checkStatus(AudioDeviceStart(aggregateDeviceID, ioProcID), "start aggregate device")
    }
}

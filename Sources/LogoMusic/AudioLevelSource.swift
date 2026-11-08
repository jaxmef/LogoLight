import AudioToolbox
import CoreAudio
import Foundation

/// Reports audio levels as linear RMS: `full` for the whole signal, `bass` below ~150 Hz.
public protocol AudioLevelSource: AnyObject {
    func start(_ onLevels: @escaping (_ full: Float, _ bass: Float) -> Void) throws
    func stop()
}

public enum AudioTapError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)
    public var description: String {
        switch self {
        case .coreAudio(let what, let st): return "\(what) failed (OSStatus \(st))"
        case .unsupportedFormat(let f): return "unsupported tap format: \(f)"
        }
    }
}

/// Taps everything the Mac plays, without changing what you hear. Without the system audio recording permission
/// the tap delivers silence.
public final class SystemAudioTap: AudioLevelSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.jaxmef.LogoLight.audiotap", qos: .userInteractive)
    private var lowState: [Float] = []
    private var sampleRate: Double = 48_000
    private var channels = 2
    private var interleaved = true

    public init() {}

    public func start(_ onLevels: @escaping (Float, Float) -> Void) throws {
        stop()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw AudioTapError.coreAudio("AudioHardwareCreateProcessTap", st) }

        // The IO block reads Float32 samples, so refuse other formats. If the format can't be read, assume Float32 stereo.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr {
            let isFloat32 = asbd.mFormatID == kAudioFormatLinearPCM && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                && asbd.mBitsPerChannel == 32
            guard isFloat32 else {
                stop()
                throw AudioTapError.unsupportedFormat("id \(asbd.mFormatID), flags \(asbd.mFormatFlags), \(asbd.mBitsPerChannel) bit")
            }
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            channels = max(1, Int(asbd.mChannelsPerFrame))
            interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        }
        lowState = [Float](repeating: 0, count: channels)

        let outputUID: String
        do { outputUID = try Self.defaultOutputUID() } catch { stop(); throw error }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LogoLight audio tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard st == noErr else { stop(); throw AudioTapError.coreAudio("AudioHardwareCreateAggregateDevice", st) }

        // One-pole low-pass at ~150 Hz for the bass band.
        let alpha = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        let ch = channels, inter = interleaved
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inData, _, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var sumFull: Float = 0, sumBass: Float = 0, count = 0
            for (bi, buf) in abl.enumerated() {
                guard let data = buf.mData else { continue }
                let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<n {
                    let c = inter ? (i % ch) : min(bi, ch - 1)
                    let x = samples[i]
                    self.lowState[c] += alpha * (x - self.lowState[c])
                    sumFull += x * x
                    sumBass += self.lowState[c] * self.lowState[c]
                    count += 1
                }
            }
            guard count > 0 else { return }
            onLevels((sumFull / Float(count)).squareRoot(), (sumBass / Float(count)).squareRoot())
        }
        guard st == noErr else { stop(); throw AudioTapError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", st) }
        st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else { stop(); throw AudioTapError.coreAudio("AudioDeviceStart", st) }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private static func defaultOutputUID() throws -> String {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard st == noErr else { throw AudioTapError.coreAudio("default output device", st) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid)
        guard st == noErr, let u = uid?.takeRetainedValue() else { throw AudioTapError.coreAudio("output device UID", st) }
        return u as String
    }
}

/// Synthetic 120 BPM "kick + hi-hat" levels for testing the pipeline without audio permission.
public final class TestBeatSource: AudioLevelSource {
    private var timer: DispatchSourceTimer?
    public let bpm: Double
    public init(bpm: Double = 120) { self.bpm = bpm }

    public func start(_ onLevels: @escaping (Float, Float) -> Void) throws {
        let t0 = Date()
        let beat = 60 / bpm
        let tm = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.github.jaxmef.LogoLight.testbeat"))
        tm.schedule(deadline: .now(), repeating: .milliseconds(10))
        tm.setEventHandler {
            let t = Date().timeIntervalSince(t0)
            let kick = Float(exp(-t.truncatingRemainder(dividingBy: beat) / 0.09))          // decaying kick every beat
            let hat = Float(exp(-(t + beat / 2).truncatingRemainder(dividingBy: beat) / 0.03)) // off-beat hat
            onLevels(0.25 * kick + 0.08 * hat, 0.22 * kick)
        }
        tm.resume()
        timer = tm
    }

    public func stop() { timer?.cancel(); timer = nil }
}

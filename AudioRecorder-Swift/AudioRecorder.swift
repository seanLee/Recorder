//
//  AudioRecorder.swift
//  AudioRecorder-Swift
//
//  Created by Sean on 2018/6/4.
//  Copyright © 2018年 swift. All rights reserved.
//

import Foundation
import CoreAudio
import AudioToolbox
import CoreFoundation
import AVFoundation

class AudioRecorder {
    
    private var sampleRate: Float64 = 44100.0
    
    private var auGraph: AUGraph?
    private var ioNode: AUNode = 0
    private var ioUnit: AudioUnit?
    private var convertNode: AUNode = 0
    private var convertUnit: AudioUnit?
    private var mixerNode: AUNode = 0
    private var mixerUnit: AudioUnit?
    
    private var destinationPath: String
    private var finalAudioFile: ExtAudioFileRef?
    
    private let inputElement: AudioUnitElement = 1
    
    init(_ path: String) {
        destinationPath = path
        print(path)
        ELAudioSession.shareInstance().category = convertFromAVAudioSessionCategory(AVAudioSession.Category.playAndRecord)
        ELAudioSession.shareInstance().active = true
        ELAudioSession.shareInstance().addRouteChangeListener()
        addAudioSessionInterruptedObserver()
        createAudioUnitGraph()
    }
    
    private func createAudioUnitGraph() {
        checkStatus(NewAUGraph(&auGraph), "Could not create a new AUGraph", true)
        
        addAudioUnitNodes()

        checkStatus(AUGraphOpen(auGraph!), "Could not open AUGraph", true)
        
        getUnitsFromNodes()
        setAudioUnitProperties()
        makeNodeConnections()
        CAShow(UnsafeMutableRawPointer(auGraph!))
        checkStatus(AUGraphInitialize(auGraph!), "Could not initialize AUGraph", true)
    }
    
    private func addAudioUnitNodes() {
        var ioDescription = AudioComponentDescription()
        ioDescription.componentManufacturer = kAudioUnitManufacturer_Apple
        ioDescription.componentType = kAudioUnitType_Output
        ioDescription.componentSubType = kAudioUnitSubType_RemoteIO
        checkStatus(AUGraphAddNode(auGraph!, &ioDescription, &ioNode), "Could not add I/O node to AUGraph", true)

        var converterDescription = AudioComponentDescription()
        converterDescription.componentManufacturer = kAudioUnitManufacturer_Apple
        converterDescription.componentType = kAudioUnitType_FormatConverter
        converterDescription.componentSubType = kAudioUnitSubType_AUConverter
        checkStatus(AUGraphAddNode(auGraph!, &converterDescription, &convertNode), "Could not add Converter node to AUGraph", true)

        var mixerDescription = AudioComponentDescription()
        mixerDescription.componentManufacturer = kAudioUnitManufacturer_Apple
        mixerDescription.componentType = kAudioUnitType_Mixer
        mixerDescription.componentSubType = kAudioUnitSubType_MultiChannelMixer
        checkStatus(AUGraphAddNode(auGraph!, &mixerDescription, &mixerNode), "Could not add mixer node to AUGraph", true)
    }
    
    private func getUnitsFromNodes() {
        checkStatus(AUGraphNodeInfo(auGraph!, ioNode, nil, &ioUnit), "Could not retrieve node info for I/O node", true)

        checkStatus(AUGraphNodeInfo(auGraph!, convertNode, nil, &convertUnit), "Could not retrieve node info for convert node", true)

        checkStatus(AUGraphNodeInfo(auGraph!, mixerNode, nil, &mixerUnit), "Could not retrieve node info for mixer node", true)
    }
    
    private func setAudioUnitProperties() {
        var stereoStreamFormat = noninterleavedPCMFormatWithChannels(2)
        
        checkStatus(AudioUnitSetProperty(ioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputElement, &stereoStreamFormat, UInt32(MemoryLayout.size(ofValue: stereoStreamFormat))),
                    "Could not set stream format on I/O unit output scope",
                    true)
        
        var enableIO: UInt32 = 1
        checkStatus(AudioUnitSetProperty(ioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputElement, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO))),
                    "Could not enable I/O on I/O unit input scope",
                    false)
        
        var mixerElementCount: UInt32 = 1
        checkStatus(AudioUnitSetProperty(mixerUnit!, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &mixerElementCount, UInt32(MemoryLayout.size(ofValue: mixerElementCount))),
                    "Could not set element count on mixer unit input scope",
                    true)
        
        checkStatus(AudioUnitSetProperty(mixerUnit!, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &sampleRate, UInt32(MemoryLayout.size(ofValue: sampleRate))),
                    "Could not set sample rate on mixer unit output scope",
                    true)
        
        var maximumFramesPerSlice: UInt32 = 4096
        AudioUnitSetProperty(ioUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFramesPerSlice, UInt32(MemoryLayout.size(ofValue: maximumFramesPerSlice)))
        
        let bytesPerSample = UInt32(MemoryLayout<Int32>.size)

        var _clientFormat32float = AudioStreamBasicDescription()

        _clientFormat32float.mFormatID = kAudioFormatLinearPCM
        _clientFormat32float.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved
        _clientFormat32float.mBytesPerPacket = bytesPerSample
        _clientFormat32float.mFramesPerPacket = 1
        _clientFormat32float.mBytesPerFrame = bytesPerSample
        _clientFormat32float.mChannelsPerFrame = 2
        _clientFormat32float.mBitsPerChannel = 8 * bytesPerSample
        _clientFormat32float.mSampleRate = sampleRate
        AudioUnitSetProperty(mixerUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_clientFormat32float, UInt32(MemoryLayout.size(ofValue: _clientFormat32float)))
        AudioUnitSetProperty(ioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_clientFormat32float, UInt32(MemoryLayout.size(ofValue: _clientFormat32float)))
        AudioUnitSetProperty(convertUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &stereoStreamFormat, UInt32(MemoryLayout.size(ofValue: stereoStreamFormat)))
        AudioUnitSetProperty(convertUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_clientFormat32float, UInt32(MemoryLayout.size(ofValue: _clientFormat32float)))
    }
    
    private let renderCallback: AURenderCallback = {
        (inRefCon: UnsafeMutableRawPointer,
         ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
         inTimeStamp: UnsafePointer<AudioTimeStamp>,
         inBusNumber: UInt32, _ inNumberFrames: UInt32,
         ioData: UnsafeMutablePointer<AudioBufferList>?) in
        
        let recoder = Unmanaged<AudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        AudioUnitRender(recoder.mixerUnit!, ioActionFlags, inTimeStamp, 0, inNumberFrames, ioData!)
        let result = ExtAudioFileWriteAsync(recoder.finalAudioFile!, inNumberFrames, ioData)

        return result
    }
    
    private func makeNodeConnections() {
        checkStatus(AUGraphConnectNodeInput(auGraph!, ioNode, 1, convertNode, 0), "Could not connect I/O node input to convert node input", true)
        
        checkStatus(AUGraphConnectNodeInput(auGraph!, convertNode, 0, mixerNode, 0), "Could not connect I/O node input to mixer node input", true)
        

        var finalRenderProc = AURenderCallbackStruct()
        finalRenderProc.inputProc = renderCallback
        finalRenderProc.inputProcRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        checkStatus(AUGraphSetNodeInputCallback(auGraph!, ioNode, 0, &finalRenderProc), "Could not set InputCallback For IONode", true)
    }
    
    private func prepareFinalWriteFile() {
        var destinationFormat = AudioStreamBasicDescription()
        
        destinationFormat.mFormatID = kAudioFormatLinearPCM
        destinationFormat.mSampleRate = sampleRate
        destinationFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        destinationFormat.mBitsPerChannel = 16
        destinationFormat.mChannelsPerFrame = 2
        destinationFormat.mBytesPerPacket = (destinationFormat.mBitsPerChannel / 8) * destinationFormat.mChannelsPerFrame
        destinationFormat.mBytesPerFrame = destinationFormat.mBytesPerPacket
        destinationFormat.mFramesPerPacket = 1
        
        var size = UInt32(MemoryLayout.size(ofValue: destinationFormat))
        checkStatus(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &destinationFormat), "AudioFormatGetProperty failed", true)
        
        let destinationURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, destinationPath as CFString, .cfurlposixPathStyle, false)
        
        // specify codec Saving the output in .m4a format
        checkStatus(ExtAudioFileCreateWithURL(destinationURL!,
                                              kAudioFileCAFType,
                                              &destinationFormat,
                                              nil,
                                              AudioFileFlags.eraseFile.rawValue,
                                              &finalAudioFile), "ExtAudioFileCreateWithURL", true)
        
        // This is a very important part and easiest way to set the ASBD for the File with correct format.
        var clientFormat = AudioStreamBasicDescription()
        
        // get the audio data format from the Output Unit
        var fsize = UInt32(MemoryLayout.size(ofValue: clientFormat))
        checkStatus(AudioUnitGetProperty(mixerUnit!,
                                         kAudioUnitProperty_StreamFormat,
                                         kAudioUnitScope_Output,
                                         0, &clientFormat, &fsize), "AudioUnitGetProperty on failed", true)
        
        checkStatus(ExtAudioFileSetProperty(finalAudioFile!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: clientFormat)), &clientFormat), "kExtAudioFileProperty_ClientDataFormat failed", true)
        
        var codec = kAppleHardwareAudioCodecManufacturer
        checkStatus(ExtAudioFileSetProperty(finalAudioFile!, kExtAudioFileProperty_CodecManufacturer, UInt32(MemoryLayout.size(ofValue: codec)), &codec), "AudioUnitGetProperty on failed", true)
        
        checkStatus(ExtAudioFileWriteAsync(finalAudioFile!, 0, nil), "ExtAudioFileWriteAsync Failed", true);
    }
    
    private func noninterleavedPCMFormatWithChannels(_ channels: UInt32) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Int32>.size)
        
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsNonInterleaved | (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | (AudioFormatFlags(kAudioUnitSampleFractionBits) << kLinearPCMFormatFlagsSampleFractionShift))
        asbd.mBitsPerChannel = 8 * bytesPerSample
        asbd.mBytesPerFrame = bytesPerSample
        asbd.mBytesPerPacket = bytesPerSample
        asbd.mFramesPerPacket = 1
        asbd.mChannelsPerFrame = channels
        
        return asbd
    }
    
    deinit {
        destroyAudioUnitGraph()
    }
    
    private func destroyAudioUnitGraph() {
        if let graph = auGraph {
            AUGraphStop(graph)
            AUGraphUninitialize(graph)
            AUGraphClose(graph)
            AUGraphRemoveNode(graph, mixerNode)
            AUGraphRemoveNode(graph, ioNode)
            DisposeAUGraph(graph)
        }
        ioUnit = nil
        mixerUnit = nil
        mixerNode = 0
        ioNode = 0
        auGraph = nil
    }
    
    func start() {
        prepareFinalWriteFile()
        
        checkStatus(AUGraphStart(auGraph!), "Could not start AUGraph", true);
    }
    
    func stop() {
        checkStatus(AUGraphStop(auGraph!), "Could not stop AUGraph", true)
        
        ExtAudioFileDispose(finalAudioFile!)
    }
    
    private func addAudioSessionInterruptedObserver() {
        removeAudioSessionInterruptedObserver()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.onNotificationAudioInterrupted(sender:)),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }
    
    private func removeAudioSessionInterruptedObserver() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    @objc private func onNotificationAudioInterrupted(sender: Notification) {
        if let type = sender.userInfo?[AVAudioSessionInterruptionTypeKey] as? AVAudioSession.InterruptionType {
            switch type {
            case .began:
                stop()
            case .ended:
                start()
            }
        }
    }
    
    private func checkStatus(_ status: OSStatus, _ message: String, _ fatal: Bool) {
        guard status != noErr else {
            return
        }
        
        let count = 5
        let stride = MemoryLayout<OSStatus>.stride
        let byteCount = stride * count
        
        var error = CFSwapInt32HostToBig(UInt32(status))
        var cc: [CChar] = [CChar](repeating: 0, count: byteCount)
        withUnsafeBytes(of: &error) { buffer in
            for (index, byte) in buffer.enumerated() {
                cc[index + 1] = CChar(byte)
            }
        }
        
        if (isprint(Int32(cc[1])) > 0 && isprint(Int32(cc[2])) > 0 && isprint(Int32(cc[3])) > 0 && isprint(Int32(cc[4])) > 0) {
            cc[0] = "\'".utf8CString[0]
            cc[5] = "\'".utf8CString[0]
            let errStr = NSString(bytes: &cc, length: cc.count, encoding: String.Encoding.ascii.rawValue)
            print("Error: \(message) (\(errStr!))")
        } else {
            print("Error: \(error)")
        }
        
        exit(1)
    }
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromAVAudioSessionCategory(_ input: AVAudioSession.Category) -> String {
	return input.rawValue
}

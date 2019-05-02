//
//  BBMetalVideoSource.swift
//  BBMetalImage
//
//  Created by Kaibo Lu on 4/24/19.
//  Copyright © 2019 Kaibo Lu. All rights reserved.
//

import AVFoundation

public class BBMetalVideoSource {
    /// Image consumers
    public var consumers: [BBMetalImageConsumer] {
        lock.wait()
        let c = _consumers
        lock.signal()
        return c
    }
    private var _consumers: [BBMetalImageConsumer]
    
    private let url: URL
    private let lock: DispatchSemaphore
    
    private var asset: AVAsset!
    private var assetReader: AVAssetReader!
    private var videoOutput: AVAssetReaderTrackOutput!
    
    private var audioOutput: AVAssetReaderTrackOutput!
    private var lastAudioBuffer: CMSampleBuffer?
    
    public var audioConsumer: BBMetalAudioConsumer? {
        get {
            lock.wait()
            let a = _audioConsumer
            lock.signal()
            return a
        }
        set {
            lock.wait()
            _audioConsumer = newValue
            lock.signal()
        }
    }
    private var _audioConsumer: BBMetalAudioConsumer?
    
    public var playWithVideoRate: Bool {
        get {
            lock.wait()
            let p = _playWithVideoRate
            lock.signal()
            return p
        }
        set {
            lock.wait()
            _playWithVideoRate = newValue
            lock.signal()
        }
    }
    private var _playWithVideoRate: Bool
    
    private var lastSampleFrameTime: CMTime!
    private var lastActualPlayTime: Double!
    
    #if !targetEnvironment(simulator)
    private var textureCache: CVMetalTextureCache!
    #endif
    
    public init?(url: URL) {
        _consumers = []
        self.url = url
        lock = DispatchSemaphore(value: 1)
        _playWithVideoRate = false
        
        #if !targetEnvironment(simulator)
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, BBMetalDevice.sharedDevice, nil, &textureCache) != kCVReturnSuccess ||
            textureCache == nil {
            return nil
        }
        #endif
    }
    
    public func start() {
        lock.wait()
        let isReading = (assetReader != nil)
        lock.signal()
        if isReading {
            print("Should not call \(#function) while asset reader is reading")
            return
        }
        let asset = AVAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
            guard let self = self else { return }
            if asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
                asset.tracks(withMediaType: .video).first != nil {
                DispatchQueue.global().async { [weak self] in
                    guard let self = self else { return }
                    self.lock.wait()
                    self.asset = asset
                    if self.prepareAssetReader() {
                        self.lock.signal()
                        self.processAsset()
                    } else {
                        self.reset()
                        self.lock.signal()
                    }
                }
            } else {
                self.safeReset()
            }
        }
    }
    
    public func cancel() {
        lock.wait()
        if let reader = assetReader,
            reader.status == .reading {
            reader.cancelReading()
            reset()
        }
        lock.signal()
    }
    
    private func safeReset() {
        lock.wait()
        reset()
        lock.signal()
    }
    
    private func reset() {
        asset = nil
        assetReader = nil
        videoOutput = nil
        audioOutput = nil
        lastAudioBuffer = nil
    }
    
    private func prepareAssetReader() -> Bool {
        guard let reader = try? AVAssetReader(asset: asset),
            let videoTrack = asset.tracks(withMediaType: .video).first else { return false }
        assetReader = reader
        videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        if !assetReader.canAdd(videoOutput) { return false }
        assetReader.add(videoOutput)
        
        if _audioConsumer != nil,
            let audioTrack = asset.tracks(withMediaType: .audio).first {
            audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey : kAudioFormatLinearPCM])
            audioOutput.alwaysCopiesSampleData = false
            if !assetReader.canAdd(audioOutput) { return false }
            assetReader.add(audioOutput)
        }
        return true
    }
    
    private func processAsset() {
        lock.wait()
        guard let reader = assetReader,
            reader.status == .unknown,
            reader.startReading() else {
            reset()
            lock.signal()
            return
        }
        lock.signal()
        
        // Read and process video buffer
        lock.wait()
        while let reader = assetReader,
            reader.status == .reading,
            let sampleBuffer = videoOutput.copyNextSampleBuffer(),
            let texture = texture(with: sampleBuffer) {
                let sampleFrameTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
                if _playWithVideoRate {
                    if let lastFrameTime = lastSampleFrameTime,
                        let lastPlayTime = lastActualPlayTime {
                        let detalFrameTime = CMTimeGetSeconds(CMTimeSubtract(sampleFrameTime, lastFrameTime))
                        let detalPlayTime = CACurrentMediaTime() - lastPlayTime
                        if detalFrameTime > detalPlayTime {
                            usleep(UInt32(1000000 * (detalFrameTime - detalPlayTime)))
                        }
                    }
                    lastSampleFrameTime = sampleFrameTime
                    lastActualPlayTime = CACurrentMediaTime()
                }
                let consumers = _consumers
                
                // Read and process audio buffer
                // Let video buffer go faster than audio buffer
                // Make sure audio and video buffer have similar output presentation timestamp
                var currentAudioBuffer: CMSampleBuffer?
                let currentAudioConsumer = _audioConsumer
                if currentAudioConsumer != nil {
                    if let last = lastAudioBuffer,
                        CMTimeCompare(CMSampleBufferGetOutputPresentationTimeStamp(last), sampleFrameTime) <= 0 {
                        // Process audio buffer
                        currentAudioBuffer = last
                        lastAudioBuffer = nil
                        
                    } else if lastAudioBuffer == nil,
                        audioOutput != nil,
                        let audioBuffer = audioOutput.copyNextSampleBuffer() {
                        if CMTimeCompare(CMSampleBufferGetOutputPresentationTimeStamp(audioBuffer), sampleFrameTime) <= 0 {
                            // Process audio buffer
                            currentAudioBuffer = audioBuffer
                        } else {
                            // Audio buffer goes faster than video
                            // Process audio buffer later
                            lastAudioBuffer = audioBuffer
                        }
                    }
                }
                lock.signal()
                
                // Transmit video texture
                let output = BBMetalDefaultTexture(metalTexture: texture, sampleTime: sampleFrameTime)
                for consumer in consumers { consumer.newTextureAvailable(output, from: self) }
                
                // Transmit audio buffer
                if let audioBuffer = currentAudioBuffer { currentAudioConsumer?.newAudioSampleBufferAvailable(audioBuffer) }
                lock.wait()
        }
        // Read and process the rest audio buffers
        if let consumer = _audioConsumer,
            let audioBuffer = lastAudioBuffer {
            lock.signal()
            consumer.newAudioSampleBufferAvailable(audioBuffer)
            lock.wait()
        }
        while let consumer = _audioConsumer,
            let reader = assetReader,
            reader.status == .reading,
            audioOutput != nil,
            let audioBuffer = audioOutput.copyNextSampleBuffer() {
                lock.signal()
                consumer.newAudioSampleBufferAvailable(audioBuffer)
                lock.wait()
        }
        if assetReader != nil {
            reset()
        }
        lock.signal()
    }
    
    private func texture(with sampleBuffer: CMSampleBuffer) -> MTLTexture? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        #if !targetEnvironment(simulator)
        var cvMetalTextureOut: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               imageBuffer,
                                                               nil,
                                                               .bgra8Unorm,
                                                               width,
                                                               height,
                                                               0,
                                                               &cvMetalTextureOut)
        if result == kCVReturnSuccess,
            let cvMetalTexture = cvMetalTextureOut,
            let texture = CVMetalTextureGetTexture(cvMetalTexture) {
            return texture
        }
        #endif
        return nil
    }
}

extension BBMetalVideoSource: BBMetalImageSource {
    @discardableResult
    public func add<T: BBMetalImageConsumer>(consumer: T) -> T {
        lock.wait()
        _consumers.append(consumer)
        lock.signal()
        consumer.add(source: self)
        return consumer
    }
    
    public func add(consumer: BBMetalImageConsumer, at index: Int) {
        lock.wait()
        _consumers.insert(consumer, at: index)
        lock.signal()
        consumer.add(source: self)
    }
    
    public func remove(consumer: BBMetalImageConsumer) {
        lock.wait()
        if let index = _consumers.firstIndex(where: { $0 === consumer }) {
            _consumers.remove(at: index)
            lock.signal()
            consumer.remove(source: self)
        } else {
            lock.signal()
        }
    }
    
    public func removeAllConsumers() {
        lock.wait()
        let consumers = _consumers
        _consumers.removeAll()
        lock.signal()
        for consumer in consumers {
            consumer.remove(source: self)
        }
    }
}

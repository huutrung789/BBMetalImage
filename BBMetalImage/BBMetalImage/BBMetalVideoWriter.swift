//
//  BBMetalVideoWriter.swift
//  BBMetalImage
//
//  Created by Kaibo Lu on 4/30/19.
//  Copyright © 2019 Kaibo Lu. All rights reserved.
//

import AVFoundation

public class BBMetalVideoWriter {
    public let url: URL
    public let frameSize: BBMetalIntSize
    public let fileType: AVFileType
    public let outputSettings: [String : Any]
    
    private var computePipeline: MTLComputePipelineState!
    private var outputTexture: MTLTexture!
    private let threadgroupSize: MTLSize
    private var threadgroupCount: MTLSize
    
    private var writer: AVAssetWriter!
    private var videoInput: AVAssetWriterInput!
    private var videoPixelBufferInput: AVAssetWriterInputPixelBufferAdaptor!
    private var videoPixelBuffer: CVPixelBuffer!
    
    public var hasAudioTrack: Bool {
        get {
            lock.wait()
            let h = _hasAudioTrack
            lock.signal()
            return h
        }
        set {
            lock.wait()
            _hasAudioTrack = newValue
            lock.signal()
        }
    }
    private var _hasAudioTrack: Bool
    
    /// A Boolean value (true by defaut) that indicates whether the input should tailor its processing of media data for real-time sources 
    public var expectsMediaDataInRealTime: Bool {
        get {
            lock.wait()
            let e = _expectsMediaDataInRealTime
            lock.signal()
            return e
        }
        set {
            lock.wait()
            _expectsMediaDataInRealTime = newValue
            lock.signal()
        }
    }
    private var _expectsMediaDataInRealTime: Bool
    
    private var audioInput: AVAssetWriterInput!
    
    private let lock: DispatchSemaphore
    
    public init(url: URL,
                frameSize: BBMetalIntSize,
                fileType: AVFileType = .mp4,
                outputSettings: [String : Any] = [AVVideoCodecKey : AVVideoCodecH264]) {
        
        self.url = url
        self.frameSize = frameSize
        self.fileType = fileType
        self.outputSettings = outputSettings
        
        let library = try! BBMetalDevice.sharedDevice.makeDefaultLibrary(bundle: Bundle(for: BBMetalVideoWriter.self))
        let kernelFunction = library.makeFunction(name: "passThroughKernel")!
        computePipeline = try! BBMetalDevice.sharedDevice.makeComputePipelineState(function: kernelFunction)
        
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = frameSize.width
        descriptor.height = frameSize.height
        descriptor.usage = [.shaderRead, .shaderWrite]
        outputTexture = BBMetalDevice.sharedDevice.makeTexture(descriptor: descriptor)
        
        threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        threadgroupCount = MTLSize(width: (frameSize.width + threadgroupSize.width - 1) / threadgroupSize.width,
                                   height: (frameSize.height + threadgroupSize.height - 1) / threadgroupSize.height,
                                   depth: 1)
        
        _hasAudioTrack = true
        _expectsMediaDataInRealTime = true
        lock = DispatchSemaphore(value: 1)
    }
    
    public func start() {
        lock.wait()
        defer { lock.signal() }
        if writer == nil {
            if !prepareAssetWriter() {
                reset()
                return
            }
        } else {
            print("Should not call \(#function) before last writing operation is finished")
            return
        }
        if !writer.startWriting() {
            reset()
            print("Asset writer can not start writing")
        }
    }
    
    public func finish(completion: (() -> Void)?) {
        lock.wait()
        defer { lock.signal() }
        if let videoInput = self.videoInput,
            let writer = self.writer,
            writer.status == .writing {
            videoInput.markAsFinished()
            if let audioInput = self.audioInput {
                audioInput.markAsFinished()
            }
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                self.lock.wait()
                self.reset()
                self.lock.signal()
                completion?()
            }
        } else {
            print("Should not call \(#function) while video writer is not writing")
        }
    }
    
    public func cancel() {
        lock.wait()
        defer { lock.signal() }
        if let videoInput = self.videoInput,
            let writer = self.writer,
            writer.status == .writing {
            videoInput.markAsFinished()
            if let audioInput = self.audioInput {
                audioInput.markAsFinished()
            }
            writer.cancelWriting()
            reset()
        } else {
            print("Should not call \(#function) while video writer is not writing")
        }
    }
    
    private func prepareAssetWriter() -> Bool {
        writer = try? AVAssetWriter(url: url, fileType: fileType)
        if writer == nil {
            print("Can not create asset writer")
            return false
        }
        
        var settings = outputSettings
        settings[AVVideoWidthKey] = frameSize.width
        settings[AVVideoHeightKey] = frameSize.height
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = _expectsMediaDataInRealTime
        if !writer.canAdd(videoInput) {
            print("Asset writer can not add video input")
            return false
        }
        writer.add(videoInput)
        
        let attributes: [String : Any] = [kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey as String : frameSize.width,
                                          kCVPixelBufferHeightKey as String : frameSize.height]
        videoPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)
        
        if _hasAudioTrack {
            let settings: [String : Any] = [AVFormatIDKey : kAudioFormatMPEG4AAC,
                                            AVNumberOfChannelsKey : 1,
                                            AVSampleRateKey : AVAudioSession.sharedInstance().sampleRate]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audioInput.expectsMediaDataInRealTime = _expectsMediaDataInRealTime
            if !writer.canAdd(audioInput) {
                print("Asset writer can not add audio input")
                return false
            }
            writer.add(audioInput)
        }
        return true
    }
    
    private func reset() {
        writer = nil
        videoInput = nil
        videoPixelBufferInput = nil
        videoPixelBuffer = nil
        audioInput = nil
    }
}

extension BBMetalVideoWriter: BBMetalImageConsumer {
    public func add(source: BBMetalImageSource) {}
    public func remove(source: BBMetalImageSource) {}
    
    public func newTextureAvailable(_ texture: BBMetalTexture, from source: BBMetalImageSource) {
        lock.wait()
        defer { lock.signal() }
        
        // Check nil
        guard let sampleTime = texture.sampleTime,
            let writer = self.writer,
            let videoInput = self.videoInput,
            let videoPixelBufferInput = self.videoPixelBufferInput else { return }
        
        if videoPixelBuffer == nil {
            // First frame
            writer.startSession(atSourceTime: sampleTime)
            guard let pool = videoPixelBufferInput.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &videoPixelBuffer) == kCVReturnSuccess else {
                    print("Can not create pixel buffer")
                    return
            }
        }
        
        // Render to output texture
        guard let commandBuffer = BBMetalDevice.sharedCommandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder() else {
                CVPixelBufferUnlockBaseAddress(videoPixelBuffer, [])
                print("Can not create compute command buffer or encoder")
                return
        }
        
        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(outputTexture, index: 0)
        encoder.setTexture(texture.metalTexture, index: 1)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // Wait to make sure that output texture contains new data
        
        // Check status
        guard videoInput.isReadyForMoreMediaData,
            writer.status == .writing else {
                print("Asset writer or video input is not ready for writing this frame")
                return
        }
        
        // Copy data from metal texture to pixel buffer
        guard videoPixelBuffer != nil,
            CVPixelBufferLockBaseAddress(videoPixelBuffer, []) == kCVReturnSuccess else {
                print("Pixel buffer can not lock base address")
                return
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(videoPixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(videoPixelBuffer, [])
            print("Can not get pixel buffer base address")
            return
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(videoPixelBuffer)
        let region = MTLRegionMake2D(0, 0, outputTexture.width, outputTexture.height)
        outputTexture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        videoPixelBufferInput.append(videoPixelBuffer, withPresentationTime: sampleTime)
        
        CVPixelBufferUnlockBaseAddress(videoPixelBuffer, [])
    }
}

extension BBMetalVideoWriter: BBMetalAudioConsumer {
    public func newAudioSampleBufferAvailable(_ sampleBuffer: CMSampleBuffer) {
        lock.wait()
        defer { lock.signal() }
        
        // Check nil
        guard let audioInput = self.audioInput,
            let writer = self.writer else { return }
        
        // Check first frame
        guard videoPixelBuffer != nil else { return }
        
        // Check status
        guard audioInput.isReadyForMoreMediaData,
            writer.status == .writing else {
                print("Asset writer or audio input is not ready for writing this frame")
                return
        }
        
        audioInput.append(sampleBuffer)
    }
}

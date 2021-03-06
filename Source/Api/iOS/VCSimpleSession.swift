//
//  VCSimpleSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/05.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import AVFoundation
import UIKit

public enum VCSessionState {
    case none
    case previewStarted
    case starting
    case started
    case ended
    case error
}

public enum VCCameraState {
    case front
    case back
}

public enum VCAspectMode {
    case fit
    case fill
}

public enum VCFilter {
    case normal
    case gray
    case invertColors
    case sepia
    case fisheye
    case glow
}

public enum VCVideoCodecType {
    case h264
    case hevc
}

let minVideoBitrate: Int = 32000

public typealias PixelBufferCallback = (_ data: UnsafeRawPointer, _ size: Int) -> Void

class PixelBufferOutput: IOutput {    
    var callback: PixelBufferCallback
    
    init(callback: @escaping PixelBufferCallback) {
        self.callback = callback
    }
    
    func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        callback(data, size)
    }
}

open class VCSimpleSession {
    private var pbOutput: PixelBufferOutput?
    private var micSource: MicSource?
    private var cameraSource: CameraSource?
    private var pixelBufferSource: PixelBufferSource?
    private var pbAspect: AspectTransform?
    private var pbPosition: PositionTransform?
    
    private var videoSplit: Split?
    private var aspectTransform: AspectTransform?
    private var atAspectMode: AspectTransform.AspectMode = .fill
    private var positionTransform: PositionTransform?
    private var audioMixer: AudioMixer?
    private var videoMixer: IVideoMixer?
    private var vtEncoder: IEncoder?
    private var aacEncoder: IEncoder?
    private var h264Packetizer: ITransform?
    private var aacPacketizer: ITransform?
    
    private var aacSplit: Split?
    private var vtSplit: Split?
    private var muxer: MP4Multiplexer?
    
    private var outputSession: IOutputSession?
    
    private var adtsEncoder: ITransform?
    private var annexbEncoder: ITransform?
    private var tsMuxer: TSMultiplexer?
    private var fileSink: FileSink?
    
    private let graphManagementQueue: DispatchQueue = .init(label: "com.videocast.session.graph")
    
    private var bpsCeiling: Int = 0
    
    private var _torch: Bool = false
    private var _audioChannelCount: Int = 2
    private var _audioSampleRate: Float = 44100
    private var _micGain: Float = 1
    private var _cameraState: VCCameraState

    open var sessionState: VCSessionState = .none {
        didSet {
            if Thread.isMainThread {
                delegate.connectionStatusChanged?(sessionState)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.delegate.connectionStatusChanged?(strongSelf.sessionState)
                }
            }
        }
    }
    open var previewView: VCPreviewView
    
    open var videoSize: CGSize {
        didSet {
            aspectTransform?.setBoundingSize(boundingWidth: Int(videoSize.width), boundingHeight: Int(videoSize.height))
            positionTransform?.setSize(width: Int(Float(videoSize.width) * videoZoomFactor),
                                       height: Int(Float(videoSize.height) * videoZoomFactor))
        }
    }
    open var bitrate: Int        // Change will not take place until the next Session
    open var fps: Int            // Change will not take place until the next Session
    open var videoCodecType: VCVideoCodecType   // Change will not take place until the next Session
    open let useInterfaceOrientation: Bool
    open var cameraState: VCCameraState {
        get { return _cameraState }
        set {
            if _cameraState != newValue {
                _cameraState = cameraState
                cameraSource?.toggleCamera()
            }
        }
    }
    open var orientationLocked: Bool = false {
        didSet {
            cameraSource?.orientationLocked = orientationLocked
        }
    }
    open var torch: Bool {
        get { return _torch }
        set {
            guard let cameraSource = cameraSource else {
                Logger.debug("unexpected return")
                return
            }
            _torch = cameraSource.setTorch(newValue)
        }
    }
    open var videoZoomFactor: Float = 1 {
        didSet {
            positionTransform?.setSize(width: Int(Float(videoSize.width) * videoZoomFactor),
                                       height: Int(Float(videoSize.height) * videoZoomFactor))
        }
    }
    open var audioChannelCount: Int {
        get { return _audioChannelCount }
        set {
            _audioChannelCount = max(1, min(newValue, 2))
            
            audioMixer?.setChannelCount(_audioChannelCount)
        }
    }
    open var audioSampleRate: Float {
        get { return _audioSampleRate }
        set {
            _audioSampleRate = ( newValue > 33075 ? 44100 : 22050)  // We can only support 44100 / 22050 with AAC + RTMP
            audioMixer?.setFrequencyInHz(newValue)
        }
    }
    open var micGain: Float {      // [0..1]
        get { return _micGain }
        set {
            guard let audioMixer = audioMixer, let micSource = micSource else {
                Logger.debug("unexpected return")
                return
            }
            audioMixer.setSourceGain(WeakRefISource(value: micSource), gain: micGain)
            _micGain = newValue
        }
    }
    open var focusPointOfInterest: CGPoint = CGPoint(x: 0.5, y: 0.5) {   // (0,0) is top-left, (1,1) is bottom-right
        didSet {
            cameraSource?.setFocusPointOfInterest(x: Float(focusPointOfInterest.x), y: Float(focusPointOfInterest.y))
        }
    }
    open var exposurePointOfInterest: CGPoint = CGPoint(x: 0.5, y: 0.5) {
        didSet {
            cameraSource?.setExposurePointOfInterest(x: Float(exposurePointOfInterest.x), y: Float(exposurePointOfInterest.y))
        }
    }
    open var continuousAutofocus: Bool = false {
        didSet {
            cameraSource?.setContinuousAutofocus(continuousAutofocus)
        }
    }
    open var continuousExposure: Bool = true {
        didSet {
            cameraSource?.setContinuousExposure(continuousExposure)
        }
    }
    open var useAdaptiveBitrate: Bool = false { /* Default is off */
        didSet {
            bpsCeiling = bitrate
        }
    }
    open private(set) var estimatedThroughput: Int = 0    /* Bytes Per Second. */
    open var aspectMode: VCAspectMode {
        didSet {
            switch aspectMode {
            case .fill:
                atAspectMode = .fill
            case .fit:
                atAspectMode = .fit
            }
        }
    }
    
    open var filter: VCFilter = .normal {    /* Default is normal */
        didSet {
            guard let videoMixer = videoMixer, let cameraSource = cameraSource else {
                Logger.debug("unexpected return")
                return
            }
            let filterName: String
            switch filter {
            case .normal:
                filterName = "com.videocast.filters.bgra"
            case .gray:
                filterName = "com.videocast.filters.grayscale"
            case .invertColors:
                filterName = "com.videocast.filters.invertColors"
            case .sepia:
                filterName = "com.videocast.filters.sepia"
            case .fisheye:
                filterName = "com.videocast.filters.fisheye"
            case .glow:
                filterName = "com.videocast.filters.glow"
            }
            
            Logger.info("FILTER IS : \(filter)")
            guard  let videoFilter = videoMixer.filterFactory.filter(name: filterName) as? IVideoFilter else {
                Logger.debug("unexpected return")
                return
            }
            videoMixer.setSourceFilter(WeakRefISource(value: cameraSource), filter: videoFilter)
        }
    }
    
    open let delegate: VCSessionDelegate
    
    private var applicationDocumentsDirectory: String? {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let basePath = (paths.count > 0) ? paths[0] : nil
        return basePath
    }
    
    public init(videoSize: CGSize,
         frameRate fps: Int,
         bitrate bps: Int,
         videoCodecType: VCVideoCodecType = .h264,
         useInterfaceOrientation: Bool = false,
         cameraState: VCCameraState = .back,
         aspectMode: VCAspectMode = .fit,
         delegate: VCSessionDelegate = .init()) {
        self.delegate = delegate
        
        self.bitrate = bps
        self.videoSize = videoSize
        self.fps = fps
        self.videoCodecType = videoCodecType
        self.useInterfaceOrientation = useInterfaceOrientation
        self.aspectMode = aspectMode
        
        self.previewView = .init()
        
        self._cameraState = cameraState
        
        graphManagementQueue.async { [weak self] in
            self?.setupGraph()
        }
    }
    
    deinit {
        endSession()
        audioMixer = nil
        videoMixer = nil
        videoSplit = nil
        aspectTransform = nil
        positionTransform = nil
        micSource = nil
        cameraSource = nil
        pbOutput = nil
    }
    
    open func startRtmpSession(url: String, streamKey: String) {
        graphManagementQueue.async { [weak self] in
            self?.startRtmpSessionInternal(url: url, streamKey: streamKey)
        }
    }
    
    private func startRtmpSessionInternal(url: String, streamKey: String) {
        let uri = url + "/" + streamKey
        
        outputSession = RTMPSession(uri: uri,
                                    callback: { [weak self] (session, state)  in
                                        guard let strongSelf = self else { return }
                                        
                                        Logger.info("ClientState: \(state)")
                                        
                                        switch state {
                                        case .connected:
                                            strongSelf.sessionState = .starting
                                        case .sessionStarted:
                                            strongSelf.graphManagementQueue.async { [weak strongSelf] in
                                                strongSelf?.addEncodersAndPacketizers()
                                            }
                                            strongSelf.sessionState = .started
                                        case .error:
                                            strongSelf.sessionState = .error
                                            strongSelf.endSession()
                                        case .notConnected:
                                            strongSelf.sessionState = .ended
                                            strongSelf.endSession()
                                        default:
                                            break
                                        }
        })
        
        bpsCeiling = bitrate
        
        if useAdaptiveBitrate {
            bitrate = 500000
        }
        
        outputSession?.setBandwidthCallback({[weak self] (vector, predicted, inst) in
            guard let strongSelf = self else { return }
            
            strongSelf.estimatedThroughput = Int(predicted)
            guard let video = strongSelf.vtEncoder, let audio = strongSelf.aacEncoder, strongSelf.useAdaptiveBitrate else { return }
            
            strongSelf.delegate.detectedThroughput?(Int(predicted), video.bitrate)
            
            guard vector != 0 else { return }
            
            let vector = vector < 0 ? -1 : 1
            
            let videoBr = video.bitrate

            switch videoBr {
            case 500001...:
                audio.bitrate = 128000
            case 250001...500000:
                audio.bitrate = 96000
            default:
                audio.bitrate = 80000
            }
            
            switch videoBr {
            case 1152001...:
                video.bitrate = min(Int(videoBr / 384000 + vector) * 384000, strongSelf.bpsCeiling)
            case 512001...:
                video.bitrate = min(Int(videoBr / 128000 + vector) * 128000, strongSelf.bpsCeiling)
            case 128001...:
                video.bitrate = min(Int(videoBr / 64000 + vector) * 64000, strongSelf.bpsCeiling)
            default:
                video.bitrate = min(Int(videoBr / 32000 + vector) * 32000, minVideoBitrate)
            }
            Logger.info("\n(\(vector) AudioBR: \(audio.bitrate) VideoBR: \(video.bitrate) (\(predicted)")
        })
        
        let sp = RTMPSessionParameters()
        
        sp.data = (Int(videoSize.width),
                   Int(videoSize.height),
                   1 / Double(fps),
                   bitrate,
                   Double(audioSampleRate),
                   audioChannelCount == 2)
        
        outputSession?.setSessionParameters(sp)
    }
    
    open func startSRTSession(url: String) {
        graphManagementQueue.async { [weak self] in
            self?.startSRTSessionInternal(url: url)
        }
    }
    
    private func startSRTSessionInternal(url: String) {
        outputSession = SRTSession(uri: url,
                                    callback: { [weak self] (session, state)  in
                                        guard let strongSelf = self else { return }
                                        
                                        Logger.info("ClientState: \(state)")
                                        
                                        switch state {
                                        case .connecting:
                                            strongSelf.sessionState = .starting
                                        case .connected:
                                            strongSelf.graphManagementQueue.async { [weak strongSelf] in
                                                strongSelf?.addEncodersAndPacketizers()
                                            }
                                            strongSelf.sessionState = .started
                                        case .error:
                                            strongSelf.sessionState = .error
                                            strongSelf.endSession()
                                        case .notConnected:
                                            strongSelf.sessionState = .ended
                                            strongSelf.endSession()
                                        default:
                                            break
                                        }
        })
        
        let sp = SRTSessionParameters()
        
        sp.data = (
            chunk: 0,
            loglevel: .err,
            logfa: .general,
            logfile: "",
            internal_log: true,
            autoreconnect: false,
            quiet: false,
            fullstats: false,
            report: 0,
            stats: 0)
        
        outputSession?.setSessionParameters(sp)
    }
    
    open func endSession() {
        h264Packetizer = nil
        aacPacketizer = nil
        if let vtEncoder = vtEncoder {
            videoSplit?.removeOutput(vtEncoder)
        }
        vtEncoder = nil
        aacEncoder = nil
        muxer?.stop {
            self.muxer = nil
        }
        
        outputSession?.stop {
            self.outputSession = nil
        }
        
        annexbEncoder = nil
        adtsEncoder = nil
        tsMuxer = nil
        fileSink = nil
        
        bitrate = bpsCeiling
        
        sessionState = .ended
    }
    
    open func getCameraPreviewLayer(_ previewLayer: inout AVCaptureVideoPreviewLayer) {
        if let cameraSource = cameraSource {
            cameraSource.getPreviewLayer(&previewLayer)
        }
    }
    
    private func setupGraph() {
        let frameDuration = 1 / Double(fps)
        
        // Add audio mixer
        let aacPacketTime = 1024 / Double(audioSampleRate)
        
        let audioMixer = AudioMixer(outChannelCount: audioChannelCount, outFrequencyInHz: Int(audioSampleRate), outBitsPerChannel: 16, frameDuration: aacPacketTime)
        self.audioMixer = audioMixer
        
        // The H.264 Encoder introduces about 2 frames of latency, so we will set the minimum audio buffer duration to 2 frames.
        audioMixer.setMinimumBufferDuration(frameDuration*2)
        
        if #available(iOS 8, *) {
            // Add video mixer
            videoMixer = GLESVideoMixer(frame_w: Int(videoSize.width), frame_h: Int(videoSize.height), frameDuration: frameDuration)
            
            let videoSplit = Split()
            
            self.videoSplit = videoSplit
            let preview = previewView
            
            let pbOutput = PixelBufferOutput(callback: { [weak self] (data: UnsafeRawPointer, size: Int)  in
                guard let strongSelf = self else { return }
                
                let ref = data.assumingMemoryBound(to: CVPixelBuffer.self).pointee
                preview.drawFrame(pixelBuffer: ref)
                if strongSelf.sessionState == .none {
                    strongSelf.sessionState = .previewStarted
                }
            })
            self.pbOutput = pbOutput
            
            videoSplit.setOutput(pbOutput)
            
            videoMixer?.setOutput(videoSplit)
        }
        
        // Create sources
        
        // Add camera source
        let cameraSource = CameraSource()
        self.cameraSource = cameraSource
        cameraSource.orientationLocked = orientationLocked
        let aspectTransform = AspectTransform(boundingWidth: Int(videoSize.width),boundingHeight: Int(videoSize.height),aspectMode: atAspectMode)
        
        let positionTransform = PositionTransform(x: Int(videoSize.width/2), y: Int(videoSize.height/2),
                                                  width: Int(Float(videoSize.width) * videoZoomFactor), height: Int(Float(videoSize.height) * videoZoomFactor),
                                                  contextWidth: Int(videoSize.width), contextHeight: Int(videoSize.height))
        
        cameraSource.setupCamera(fps: fps, useFront: cameraState == .front, useInterfaceOrientation: useInterfaceOrientation, sessionPreset: nil, callback: {
            self.cameraSource?.setContinuousAutofocus(true)
            self.cameraSource?.setContinuousExposure(true)
            
            self.cameraSource?.setOutput(aspectTransform)
            
            guard let videoMixer = self.videoMixer,
                let filter = videoMixer.filterFactory.filter(name: "com.videocast.filters.bgra") as? IVideoFilter else {
                    Logger.debug("unexpected return")
                    return
            }
            videoMixer.setSourceFilter(WeakRefISource(value: cameraSource), filter: filter)
            self.filter = .normal
            aspectTransform.setOutput(positionTransform)
            positionTransform.setOutput(videoMixer)
            self.aspectTransform = aspectTransform
            self.positionTransform = positionTransform
            
            // Inform delegate that camera source has been added
            self.delegate.didAddCameraSource?(self)
        })
        
        // Add mic source
        micSource = MicSource(sampleRate: Double(audioSampleRate), channelCount: audioChannelCount)
        micSource?.setOutput(audioMixer)
        
        let epoch = Date()
        
        audioMixer.setEpoch(epoch)
        videoMixer?.setEpoch(epoch)
        
        audioMixer.start()
        videoMixer?.start()
    }
    
    private func addEncodersAndPacketizers() {
        guard let outputSession = outputSession else {
            Logger.debug("unexpected return")
            return
        }
        let ctsOffset: CMTime = .init(value: 2, timescale: Int32(fps))  // 2 * frame duration
        
        // Add encoders
        
        let aacEncoder = AACEncode(frequencyInHz: Int(audioSampleRate), channelCount: audioChannelCount, averageBitrate: 96000)
        self.aacEncoder = aacEncoder
        let vtEncoder = VTEncode(frame_w: Int(videoSize.width),
                                 frame_h: Int(videoSize.height),
                                 fps: fps,
                                 bitrate: bitrate,
                                 codecType: videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                                 useBaseline: false,
                                 ctsOffset: ctsOffset)
        self.vtEncoder = vtEncoder
        audioMixer?.setOutput(aacEncoder)
        videoSplit?.setOutput(vtEncoder)
        
        let aacSplit = Split()
        self.aacSplit = aacSplit
        let vtSplit = Split()
        self.vtSplit = vtSplit
        aacEncoder.setOutput(aacSplit)
        vtEncoder.setOutput(vtSplit)
        
        if outputSession is RTMPSession {
            let h264Packetizer = H264Packetizer(ctsOffset: ctsOffset)
            self.h264Packetizer = h264Packetizer
            let aacPacketizer = AACPacketizer(sampleRate: Int(audioSampleRate), channelCount: audioChannelCount, ctsOffset: ctsOffset)
            self.aacPacketizer = aacPacketizer
            
            vtSplit.setOutput(h264Packetizer)
            aacSplit.setOutput(aacPacketizer)
            
            h264Packetizer.setOutput(outputSession)
            aacPacketizer.setOutput(outputSession)
        }
        
        /*muxer = .init()
         if let applicationDocumentsDirectory = applicationDocumentsDirectory, let muxer = muxer  {
         let params: MP4SessionParameters = .init()
         let file = applicationDocumentsDirectory + "/output.mp4"
         params.data = (file, fps, Int(videoSize.width), Int(videoSize.height), videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC)
         muxer.setSessionParameters(params)
         aacSplit.setOutput(muxer)
         vtSplit.setOutput(muxer)
         }*/

        if outputSession is SRTSession {
            var streamIndex = 0
            let vSt = TSMultiplexer.Stream(id: 0, mediaType: .video, videoCodecType: videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC, timeBase: .init(value: 1, timescale: CMTimeScale(fps)))
            annexbEncoder  = AnnexbEncode(streamIndex, codecType: videoCodecType == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC)
            streamIndex += 1
            let aSt = TSMultiplexer.Stream(id: 1, mediaType: .audio, videoCodecType: nil, timeBase: .init(value: 1, timescale: CMTimeScale(audioSampleRate)))
            adtsEncoder = ADTSEncode(streamIndex)
            let streams = [vSt, aSt]
            tsMuxer = .init(streams, ctsOffset: ctsOffset)
            if let tsMuxer = tsMuxer,
                let adtsEncoder = adtsEncoder,
                let annexbEncoder = annexbEncoder {
                
                /*fileSink = .init()
                if let applicationDocumentsDirectory = applicationDocumentsDirectory, let fileSink = fileSink {
                    let params: FileSinkSessionParameters = .init()
                    let file = applicationDocumentsDirectory + "/output.ts"
                    params.data = (file, nil)
                    fileSink.setSessionParameters(params)
                    
                    tsMuxer.setOutput(fileSink)
                }*/
                tsMuxer.setOutput(outputSession)
                
                adtsEncoder.setOutput(tsMuxer)
                annexbEncoder.setOutput(tsMuxer)
                
                aacSplit.setOutput(adtsEncoder)
                vtSplit.setOutput(annexbEncoder)
            }
        }
    }
    
    open func addPixelBufferSource(image: UIImage, rect: CGRect) {
        guard let cgImage = image.cgImage,
            let videoMixer = videoMixer else {
                Logger.debug("unexpected return")
                return
        }
        
        let pixelBufferSource = PixelBufferSource(width: cgImage.width,
                                              height: cgImage.height,
                                              pixelFormat: kCVPixelFormatType_32BGRA)
        self.pixelBufferSource = pixelBufferSource
        
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pxBuffer: CVPixelBuffer? = nil
        
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options as NSDictionary?, &pxBuffer)
        
        CVPixelBufferLockBaseAddress(pxBuffer!, [])
        
        let pxdata = CVPixelBufferGetBaseAddress(pxBuffer!)
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        let context = CGContext(data: pxdata, width: width, height: height,
                                bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let pbAspect = AspectTransform(boundingWidth: Int(rect.size.width), boundingHeight: Int(rect.size.height), aspectMode: .fit)
        self.pbAspect = pbAspect
        
        let pbPosition = PositionTransform(x: Int(rect.origin.x), y: Int(rect.origin.y),
                                       width: Int(rect.size.width), height: Int(rect.size.height),
                                       contextWidth: Int(videoSize.width), contextHeight: Int(videoSize.height)
        )
        self.pbPosition = pbPosition
        
        pixelBufferSource.setOutput(pbAspect)
        pbAspect.setOutput(pbPosition)
        pbPosition.setOutput(videoMixer)
        videoMixer.registerSource(pixelBufferSource)
        pixelBufferSource.pushPixelBuffer(data: pxdata!, size: width * height * 4)
        
        CVPixelBufferUnlockBaseAddress(pxBuffer!, [])
    }
}

//
// Created by Avently on 09.02.2023.
// Copyright (c) 2023 SimpleX Chat. All rights reserved.
//

import WebRTC
import LZString
import SwiftUI
import SimpleXChat

final class WebRTCClient: NSObject, RTCVideoViewDelegate, RTCVideoCapturerDelegate, RTCFrameEncryptorDelegate, RTCFrameDecryptorDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()

    struct Call {
        var connection: RTCPeerConnection
        var iceCandidates: [RTCIceCandidate]
        var localMedia: CallMediaType
        var localCamera: RTCVideoCapturer
        var localVideoSource: RTCVideoSource
        var localStream: RTCVideoTrack
        var remoteStream: RTCVideoTrack?
        var encryptedLocalVideoSource: RTCVideoSource
        var device: AVCaptureDevice.Position = .front
        var aesKey: String?
        var frameEncryptor: RTCFrameEncryptor?
        var frameDecryptor: RTCFrameDecryptor?
    }

    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    private let audioQueue = DispatchQueue(label: "audio")
    private var sendCallResponse: (WVAPIMessage) async -> Void
    private var activeCall: Binding<Call?>
    private var localRendererAspectRatio: Binding<CGFloat?>

    @available(*, unavailable)
    override init() {
        fatalError("Unimplemented")
    }

    required init(_ activeCall: Binding<Call?>, _ sendCallResponse: @escaping (WVAPIMessage) async -> Void, _ localRendererAspectRatio: Binding<CGFloat?>) {
        self.sendCallResponse = sendCallResponse
        self.activeCall = activeCall
        self.localRendererAspectRatio = localRendererAspectRatio
        super.init()
    }

    let defaultIceServers: [WebRTC.RTCIceServer] = [
        WebRTC.RTCIceServer(urlStrings: ["stun:stun.simplex.im:443"]),
        WebRTC.RTCIceServer(urlStrings: ["turn:turn.simplex.im:443?transport=udp"], username: "private", credential: "yleob6AVkiNI87hpR94Z"),
        WebRTC.RTCIceServer(urlStrings: ["turn:turn.simplex.im:443?transport=tcp"], username: "private", credential: "yleob6AVkiNI87hpR94Z"),
    ]

    func initializeCall(_ iceServers: [WebRTC.RTCIceServer]?, _ remoteIceCandidates: [RTCIceCandidate], _ mediaType: CallMediaType, _ aesKey: String?, _ relay: Bool?) -> Call {
        let connection = createPeerConnection(iceServers ?? getWebRTCIceServers() ?? defaultIceServers, relay)
        connection.delegate = self
        let (localStream, remoteStream, localCamera, localVideoSource, encryptedLocalVideoSource) = createMediaSenders(connection)
        var frameEncryptor: RTCFrameEncryptor? = nil
        var frameDecryptor: RTCFrameDecryptor? = nil
        if aesKey != nil {
            frameEncryptor = RTCFrameEncryptor.init(sizeChange: 28)
            frameEncryptor?.delegate = self
            frameDecryptor = RTCFrameDecryptor.init(sizeChange: -28)
            frameDecryptor?.delegate = self
        }
        return Call(
            connection: connection,
            iceCandidates: remoteIceCandidates,
            localMedia: mediaType,
            localCamera: localCamera,
            localVideoSource: localVideoSource,
            localStream: localStream,
            remoteStream: remoteStream,
            encryptedLocalVideoSource: encryptedLocalVideoSource,
            aesKey: aesKey,
            frameEncryptor: frameEncryptor,
            frameDecryptor: frameDecryptor
        )
    }

    func createPeerConnection(_ iceServers: [WebRTC.RTCIceServer], _ relay: Bool?) -> RTCPeerConnection {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])

        guard let connection = WebRTCClient.factory.peerConnection(
            with: getCallConfig(iceServers, relay),
            constraints: constraints, delegate: nil
        )
        else {
            fatalError("Unable to create RTCPeerConnection")
        }
        return connection
    }

    func getCallConfig(_ iceServers: [WebRTC.RTCIceServer], _ relay: Bool?) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = relay == true ? .relay : .all
        // Allows to wait 30 sec before `failing` connection if the answer from remote side is not received in time
        config.iceInactiveTimeout = 30_000
        return config
    }

    func supportsEncryption() -> Bool { true }

    func addIceCandidates(_ connection: RTCPeerConnection, _ remoteIceCandidates: [RTCIceCandidate]) {
        remoteIceCandidates.forEach { candidate in
            connection.add(candidate.toWebRTCCandidate()) { error in
                if let error = error {
                    logger.error("Adding candidate error \(error)")
                }
            }
        }
    }

    func sendCallCommand(command: WCallCommand) async {
        var resp: WCallResponse? = nil
        let pc = activeCall.wrappedValue?.connection
        switch command {
        case .capabilities:
            resp = .capabilities(capabilities: CallCapabilities(encryption: supportsEncryption()))
        case let .start(media: media, aesKey, iceServers, relay):
            logger.debug("starting incoming call - create webrtc session")
            if activeCall.wrappedValue != nil { endCall() }
            let encryption = supportsEncryption()
            let call = initializeCall(iceServers?.toWebRTCIceServers(), [], media, encryption ? aesKey : nil, relay)
            activeCall.wrappedValue = call
            call.connection.offer { answer in
                Task {
                    self.setSpeakerEnabledAndConfigureSession(media == .video)
                    let gotCandidates = await self.waitWithTimeout(10_000, stepMs: 1000, until: { self.activeCall.wrappedValue?.iceCandidates.count ?? 0 > 0 })
                    if gotCandidates {
                        await self.sendCallResponse(.init(
                            corrId: nil,
                            resp: .offer(
                                offer: compressToBase64(input: encodeJSON(CustomRTCSessionDescription(type: answer.type.toSdpType(), sdp: answer.sdp))),
                                iceCandidates: compressToBase64(input: encodeJSON(self.activeCall.wrappedValue?.iceCandidates ?? [])),
                                capabilities: CallCapabilities(encryption: encryption)
                            ),
                            command: command)
                        )
                    } else {
                        self.endCall()
                    }
                }

            }
        case let .offer(offer, iceCandidates, media, aesKey, iceServers, relay):
            if activeCall.wrappedValue != nil {
                resp = .error(message: "accept: call already started")
            } else if !supportsEncryption() && aesKey != nil {
                resp = .error(message: "accept: encryption is not supported")
            } else if let offer: CustomRTCSessionDescription = decodeJSON(decompressFromBase64(input: offer)),
                      let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)) {
                let call = initializeCall(iceServers?.toWebRTCIceServers(), remoteIceCandidates, media, supportsEncryption() ? aesKey : nil, relay)
                activeCall.wrappedValue = call
                let pc = call.connection
                if let type = offer.type, let sdp = offer.sdp {
                    if (try? await pc.setRemoteDescription(RTCSessionDescription(type: type.toWebRTCSdpType(), sdp: sdp))) != nil {
                        pc.answer { answer in
                            self.setSpeakerEnabledAndConfigureSession(media == .video)
                            self.addIceCandidates(pc, remoteIceCandidates)
//                            Task {
//                                try? await Task.sleep(nanoseconds: 32_000 * 1000000)
                            Task {
                                await self.sendCallResponse(.init(
                                    corrId: nil,
                                    resp: .answer(
                                        answer: compressToBase64(input: encodeJSON(CustomRTCSessionDescription(type: answer.type.toSdpType(), sdp: answer.sdp))),
                                        iceCandidates: compressToBase64(input: encodeJSON(call.iceCandidates))
                                    ),
                                    command: command)
                                )
                            }
//                            }
                        }
                    } else {
                        resp = .error(message: "accept: remote description is not set")
                    }
                }
            }
        case let .answer(answer, iceCandidates):
            if pc == nil {
                resp = .error(message: "answer: call not started")
            } else if pc?.localDescription == nil {
                resp = .error(message: "answer: local description is not set")
            } else if pc?.remoteDescription != nil {
                resp = .error(message: "answer: remote description already set")
            } else if let answer: CustomRTCSessionDescription = decodeJSON(decompressFromBase64(input: answer)),
                      let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)),
                      let type = answer.type, let sdp = answer.sdp,
                      let pc = pc {
                if (try? await pc.setRemoteDescription(RTCSessionDescription(type: type.toWebRTCSdpType(), sdp: sdp))) != nil {
                    addIceCandidates(pc, remoteIceCandidates)
                    resp = .ok
                } else {
                    resp = .error(message: "answer: remote description is not set")
                }
            }
        case let .ice(iceCandidates):
            if let pc = pc,
               let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)) {
                addIceCandidates(pc, remoteIceCandidates)
                resp = .ok
            } else {
                resp = .error(message: "ice: call not started")
            }
        case let .media(media, enable):
            if activeCall.wrappedValue == nil {
                resp = .error(message: "media: call not started")
            } else if activeCall.wrappedValue?.localMedia == .audio && media == .video {
                resp = .error(message: "media: no video")
            } else {
                enableMedia(media, enable)
                resp = .ok
            }
        case .end:
            await sendCallResponse(.init(corrId: nil, resp: .ok, command: command))
            endCall()
        }
        if let resp = resp {
            await sendCallResponse(.init(corrId: nil, resp: resp, command: command))
        }
    }

    func enableMedia(_ media: CallMediaType, _ enable: Bool) {
        media == .video ? setVideoEnabled(enable) : setAudioEnabled(enable)
    }

    func addLocalRenderer(_ activeCall: Call, _ renderer: RTCEAGLVideoView) {
        activeCall.localStream.add(renderer)
        // To get width and height of a frame, see videoView(videoView:, didChangeVideoSize)
        renderer.delegate = self
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        guard size.height > 0 else { return }
        localRendererAspectRatio.wrappedValue = size.width / size.height
    }

    func frameDecryptor(_ decryptor: RTCFrameDecryptor, withFrame encrypted: Data) -> Data? {
        debugPrint("LALAL DECRYPTED CALL \(encrypted)  \((encrypted as NSData).first)")
        guard encrypted.count > 0 else { return nil }
        if var key: [CChar] = activeCall.wrappedValue?.aesKey?.cString(using: .utf8),
           let pointer: UnsafeMutableRawPointer = malloc(encrypted.count) {
            memcpy(pointer, (encrypted as NSData).bytes, encrypted.count)
//            let raw: UInt8 = (encrypted[0] as UInt8) | ((encrypted[1] as UInt8) << 8) | ((encrypted[2] as UInt8) << 16)
            let isKeyFrame = encrypted[0] & 1 == 1
            debugPrint("LALAL key \(isKeyFrame)")
            let clearTextBytesSize = isKeyFrame ? 10 : 3
            chat_decrypt_media(&key, pointer.advanced(by: clearTextBytesSize), Int32(encrypted.count - clearTextBytesSize))
            return Data(bytes: pointer, count: encrypted.count - 28)
        } else {
            return nil
        }
//        let a: NSData = NSData(base64Encoding: "")!
//        let o = a.bytes.assumingMemoryBound(to: Int32.self)[0]
    }

    func frameEncryptor(_ encryptor: RTCFrameEncryptor, withFrame unencrypted: Data) -> Data? {
        debugPrint("LALAL UNENCRYPTED CALL \(unencrypted)  \((unencrypted as NSData).first)")
        guard unencrypted.count > 0 else { return nil }
        if var key: [CChar] = activeCall.wrappedValue?.aesKey?.cString(using: .utf8),
           let pointer: UnsafeMutableRawPointer = malloc(unencrypted.count + 28) {
            debugPrint("LALAL keeey \(key)   \(activeCall.wrappedValue?.aesKey)")
            memcpy(pointer, (unencrypted as NSData).bytes, unencrypted.count)
//            let raw: UInt8 = (unencrypted[0] as UInt8) | ((unencrypted[1] as UInt8) << 8) | ((unencrypted[2] as UInt8) << 16)
            let isKeyFrame = unencrypted[0] & 1 == 1
            debugPrint("LALAL key \(isKeyFrame)")
            let clearTextBytesSize = isKeyFrame ? 10 : 3
            for i in 0..<30 {
                debugPrint("LALAL before \(i)  \(unencrypted[i + clearTextBytesSize])")
            }
            chat_encrypt_media(&key, pointer.advanced(by: clearTextBytesSize), Int32(unencrypted.count + 28 - clearTextBytesSize))
            for i in 0..<30 {
                debugPrint("LALAL after \(i)  \(pointer.advanced(by: clearTextBytesSize).assumingMemoryBound(to: UInt8.self)[i])")
            }
            return Data(bytes: pointer, count: unencrypted.count + 28)
        } else {
            return nil
        }
    }

    private class EncryptedRTCVideoRenderer: NSObject, RTCVideoRenderer {
        let delegate: RTCVideoRenderer
        let aesKey: String
        init (_ aesKey: String, _ delegate: RTCVideoRenderer) {
            self.aesKey = aesKey
            self.delegate = delegate
        }
        func setSize(_ size: CGSize) {
            delegate.setSize(size)
        }

        func renderFrame(_ frame: RTCVideoFrame?) {
            if let frame = frame {
                delegate.renderFrame(frame.encryption(aesKey, encrypt: false))
            } else {
                delegate.renderFrame(frame)
            }
        }
    }

    func addRemoteRenderer(_ activeCall: Call, _ renderer: RTCVideoRenderer) {
        let aesKey: String? = activeCall.aesKey
        if let aesKey = aesKey {
            activeCall.remoteStream?.add(EncryptedRTCVideoRenderer(aesKey, renderer))
        } else {
            activeCall.remoteStream?.add(renderer)
        }
    }

    func startCaptureLocalVideo(_ activeCall: Call) {
        if let camera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == activeCall.device }) {
            let formats = RTCCameraVideoCapturer.supportedFormats(for: camera).forEach{ format in
                format.supportedDepthDataFormats.forEach { f in f.supportedDepthDataFormats }
            }
            debugPrint("LALAL formats \(formats)")
        }

        guard
            let capturer = activeCall.localCamera as? RTCCameraVideoCapturer,
            let camera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == activeCall.device }),
            let format = RTCCameraVideoCapturer.supportedFormats(for: camera)
            .max(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }),
            let fps = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else {
            return
        }

        debugPrint("LALAL format \(format)")

        capturer.delegate = self
        capturer.stopCapture()
        capturer.startCapture(with: camera,
            format: format,
            fps: Int(fps.maxFrameRate))
    }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        activeCall.wrappedValue?.localVideoSource.capturer(capturer, didCapture: frame)
        let aesKey: String? = activeCall.wrappedValue?.aesKey
        // Only be here when encryption is used
        guard let aesKey = aesKey else { return }
        let buffer: RTCCVPixelBuffer = frame.buffer as! RTCCVPixelBuffer
        var pixelBuffer: CVPixelBuffer = buffer.pixelBuffer
//        debugPrint("LALAL \(frame.width) \(frame.height)")
        if let newPixelBuffer = pixelBuffer.copy(aesKey, encrypt: true) {
            let modifiedBuffer: RTCCVPixelBuffer = RTCCVPixelBuffer(pixelBuffer: newPixelBuffer)
            print("LALAL0 \(modifiedBuffer) \(modifiedBuffer.width) \(modifiedBuffer.height) \(modifiedBuffer.pixelBuffer)")
            let frame: RTCVideoFrame = RTCVideoFrame(buffer: modifiedBuffer, rotation: frame.rotation, timeStampNs: frame.timeStampNs)
            activeCall.wrappedValue?.encryptedLocalVideoSource.capturer(capturer, didCapture: frame)
        }
    }

    private func createMediaSenders(_ connection: RTCPeerConnection) -> (RTCVideoTrack, RTCVideoTrack?, RTCVideoCapturer, RTCVideoSource, RTCVideoSource) {
        let streamId = "stream"
        let audioTrack = createAudioTrack()
        connection.add(audioTrack, streamIds: [streamId])
        let (localVideoTrack, localCamera, localVideoSource, encryptedLocalVideoTrack, encryptedLocalVideoSource) = createVideoTrack()
        connection.add(encryptedLocalVideoTrack, streamIds: [streamId])
        return (localVideoTrack, connection.transceivers.first { $0.mediaType == .video }?.receiver.track as? RTCVideoTrack, localCamera, localVideoSource, encryptedLocalVideoSource)
    }

    private func createAudioTrack() -> RTCAudioTrack {
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = WebRTCClient.factory.audioSource(with: audioConstrains)
        let audioTrack = WebRTCClient.factory.audioTrack(with: audioSource, trackId: "audio0")
        return audioTrack
    }

    private func createVideoTrack() -> (RTCVideoTrack, RTCVideoCapturer, RTCVideoSource, RTCVideoTrack, RTCVideoSource) {
        let localVideoSource = WebRTCClient.factory.videoSource()
        // Can be encrypted or not
        let encryptedLocalVideoSource = WebRTCClient.factory.videoSource()

        #if targetEnvironment(simulator)
        let localCamera = RTCFileVideoCapturer(delegate: self)
        #else
        let localCamera = RTCCameraVideoCapturer(delegate: self)
        #endif

        let localVideoTrack = WebRTCClient.factory.videoTrack(with: localVideoSource, trackId: "video-1")
        let encryptedLocalVideoTrack = WebRTCClient.factory.videoTrack(with: encryptedLocalVideoSource, trackId: "video0")
        return (localVideoTrack, localCamera, localVideoSource, encryptedLocalVideoTrack, encryptedLocalVideoSource)
    }

    func endCall() {
        activeCall.wrappedValue?.connection.close()
        activeCall.wrappedValue?.frameDecryptor?.delegate = nil
        activeCall.wrappedValue = nil
        setSpeakerEnabledAndConfigureSession(false)
    }

    func waitWithTimeout(_ timeoutMs: UInt64, stepMs: UInt64, until success: () -> Bool) async -> Bool {
        let startedAt = DispatchTime.now()
        while !success() && startedAt.uptimeNanoseconds + timeoutMs * 1000000 > DispatchTime.now().uptimeNanoseconds {
            guard let _ = try? await Task.sleep(nanoseconds: stepMs * 1000000) else { break }
        }
        return success()
    }
}


extension WebRTC.RTCPeerConnection {
    func mediaConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
    }

    func offer(_ completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        offer(for: mediaConstraints()) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }
            self.setLocalDescription(sdp, completionHandler: { (error) in
                completion(sdp)
            })
        }
    }

    func answer(_ completion: @escaping (_ sdp: RTCSessionDescription) -> Void)  {
        answer(for: mediaConstraints()) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }
            self.setLocalDescription(sdp, completionHandler: { (error) in
                completion(sdp)
            })
        }
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ connection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        logger.debug("Connection new signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ connection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger.debug("Connection did add stream")
        debugPrint("LALAL transceivers \(connection.transceivers)")
        if let frameEncryptor = activeCall.wrappedValue?.frameEncryptor, let frameDecryptor = activeCall.wrappedValue?.frameDecryptor {
            connection.transceivers.forEach{ $0.sender.setRtcFrameEncryptor(frameEncryptor) }
            connection.transceivers.forEach{ $0.receiver.setRtcFrameDecryptor(frameDecryptor) }
        }
    }

    func peerConnection(_ connection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        logger.debug("Connection did remove stream")
    }

    func peerConnectionShouldNegotiate(_ connection: RTCPeerConnection) {
        logger.debug("Connection should negotiate")
    }

    func peerConnection(_ connection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        logger.debug("Connection new connection state: \(newState.toString() ?? "" + newState.rawValue.description)")

        guard let call = activeCall.wrappedValue,
              let connectionStateString = newState.toString(),
              let iceConnectionStateString = connection.iceConnectionState.toString(),
              let iceGatheringStateString = connection.iceGatheringState.toString(),
              let signalingStateString = connection.signalingState.toString()
        else {
            return
        }
        Task {
            await sendCallResponse(.init(
                corrId: nil,
                resp: .connection(state: ConnectionState(
                    connectionState: connectionStateString,
                    iceConnectionState: iceConnectionStateString,
                    iceGatheringState: iceGatheringStateString,
                    signalingState: signalingStateString)
                ),
                command: nil)
            )

            switch newState {
            case .disconnected, .failed: endCall()
            default: do {}
            }
        }
    }

    func peerConnection(_ connection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        logger.debug("connection new gathering state: \(newState.toString() ?? "" + newState.rawValue.description)")
    }

    func peerConnection(_ connection: RTCPeerConnection, didGenerate candidate: WebRTC.RTCIceCandidate) {
//        logger.debug("Connection generated candidate \(candidate.debugDescription)")
        activeCall.wrappedValue?.iceCandidates.append(candidate.toCandidate(nil, nil, nil))
    }

    func peerConnection(_ connection: RTCPeerConnection, didRemove candidates: [WebRTC.RTCIceCandidate]) {
        logger.debug("Connection did remove candidates")
    }

    func peerConnection(_ connection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ connection: RTCPeerConnection,
                        didChangeLocalCandidate local: WebRTC.RTCIceCandidate,
                        remoteCandidate remote: WebRTC.RTCIceCandidate,
                        lastReceivedMs lastDataReceivedMs: Int32,
                        changeReason reason: String) {
//        logger.debug("Connection changed candidate \(reason) \(remote.debugDescription) \(remote.description)")
        sendConnectedEvent(connection, local: local, remote: remote)
    }

    func sendConnectedEvent(_ connection: WebRTC.RTCPeerConnection, local: WebRTC.RTCIceCandidate, remote: WebRTC.RTCIceCandidate) {
        connection.statistics { (stats: RTCStatisticsReport) in
            stats.statistics.values.forEach { stat in
//                logger.debug("Stat \(stat.debugDescription)")
                if stat.type == "candidate-pair", stat.values["state"] as? String == "succeeded",
                   let localId = stat.values["localCandidateId"] as? String,
                   let remoteId = stat.values["remoteCandidateId"] as? String,
                   let localStats = stats.statistics[localId],
                   let remoteStats = stats.statistics[remoteId],
                   local.sdp.contains("\((localStats.values["ip"] as? String ?? "--")) \((localStats.values["port"] as? String ?? "--"))") &&
                   remote.sdp.contains("\((remoteStats.values["ip"] as? String ?? "--")) \((remoteStats.values["port"] as? String ?? "--"))")
                {
                    Task {
                        await self.sendCallResponse(.init(
                            corrId: nil,
                            resp: .connected(connectionInfo: ConnectionInfo(
                                localCandidate: local.toCandidate(
                                    RTCIceCandidateType.init(rawValue: localStats.values["candidateType"] as! String),
                                    localStats.values["protocol"] as? String,
                                    localStats.values["relayProtocol"] as? String
                                ),
                                remoteCandidate: remote.toCandidate(
                                    RTCIceCandidateType.init(rawValue: remoteStats.values["candidateType"] as! String),
                                    remoteStats.values["protocol"] as? String,
                                    remoteStats.values["relayProtocol"] as? String
                                ))),
                            command: nil)
                        )
                    }
                }
            }
        }
    }
}

extension WebRTCClient {
    func setAudioEnabled(_ enabled: Bool) {
        setTrackEnabled(RTCAudioTrack.self, enabled)
    }

    func setSpeakerEnabledAndConfigureSession( _ enabled: Bool) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue)
                try self.rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
                try self.rtcAudioSession.overrideOutputAudioPort(enabled ? .speaker : .none)
                if enabled {
                    try self.rtcAudioSession.setActive(true)
                }
            } catch let error {
                logger.debug("Error configuring AVAudioSession: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }

    func setVideoEnabled(_ enabled: Bool) {
        setTrackEnabled(RTCVideoTrack.self, enabled)
    }

    func flipCamera() {
        switch activeCall.wrappedValue?.device {
        case .front: activeCall.wrappedValue?.device = .back
        case .back: activeCall.wrappedValue?.device = .front
        default: ()
        }
        if let call = activeCall.wrappedValue {
            startCaptureLocalVideo(call)
        }
    }

    private func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, _ enabled: Bool) {
        activeCall.wrappedValue?.connection.transceivers
        .compactMap { $0.sender.track as? T }
        .forEach { $0.isEnabled = enabled }
    }
}

struct CustomRTCSessionDescription: Codable {
    public var type: RTCSdpType?
    public var sdp: String?
}

enum RTCSdpType: String, Codable {
    case answer
    case offer
    case pranswer
    case rollback
}

extension RTCIceCandidate {
    func toWebRTCCandidate() -> WebRTC.RTCIceCandidate {
        WebRTC.RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: Int32(sdpMLineIndex ?? 0),
            sdpMid: sdpMid
        )
    }
}

extension WebRTC.RTCIceCandidate {
    func toCandidate(_ candidateType: RTCIceCandidateType?, _ protocol: String?, _ relayProtocol: String?) -> RTCIceCandidate {
        RTCIceCandidate(
            candidateType: candidateType,
            protocol: `protocol`,
            relayProtocol: relayProtocol,
            sdpMid: sdpMid,
            sdpMLineIndex: Int(sdpMLineIndex),
            candidate: sdp
        )
    }
}


extension [RTCIceServer] {
    func toWebRTCIceServers() -> [WebRTC.RTCIceServer] {
        self.map {
            WebRTC.RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            ) }
    }
}

extension RTCSdpType {
    func toWebRTCSdpType() -> WebRTC.RTCSdpType {
        switch self {
        case .answer: return WebRTC.RTCSdpType.answer
        case .offer: return WebRTC.RTCSdpType.offer
        case .pranswer: return WebRTC.RTCSdpType.prAnswer
        case .rollback: return WebRTC.RTCSdpType.rollback
        }
    }
}

extension WebRTC.RTCSdpType {
    func toSdpType() -> RTCSdpType {
        switch self {
        case .answer: return RTCSdpType.answer
        case .offer: return RTCSdpType.offer
        case .prAnswer: return RTCSdpType.pranswer
        case .rollback: return RTCSdpType.rollback
        default: return RTCSdpType.answer // should never be here
        }
    }
}

extension RTCPeerConnectionState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return"failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return nil // unknown
        }
    }
}

extension RTCIceConnectionState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return nil // unknown or unused on the other side
        }
    }
}

extension RTCIceGatheringState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        default: return nil // unknown
        }
    }
}

extension RTCSignalingState {
    func toString() -> String? {
        switch self {
        case .stable: return "stable"
        case .haveLocalOffer: return "have-local-offer"
        case .haveLocalPrAnswer: return "have-local-pranswer"
        case .haveRemoteOffer: return "have-remote-offer"
        case .haveRemotePrAnswer: return "have-remote-pranswer"
        case .closed: return "closed"
        default: return nil // unknown
        }
    }
}

extension CVPixelBuffer {
    func copy(_ aesKey: String?, encrypt: Bool) -> CVPixelBuffer? {
        var newPixelBuffer: CVPixelBuffer!
        let res = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(self),
            CVPixelBufferGetHeight(self),
            CVPixelBufferGetPixelFormatType(self),
            nil,
            &newPixelBuffer)
        guard res == kCVReturnSuccess else { fatalError() }

        CVPixelBufferLockBaseAddress(self, .readOnly)
        CVPixelBufferLockBaseAddress(newPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        defer {
            CVPixelBufferUnlockBaseAddress(newPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
            CVPixelBufferUnlockBaseAddress(self, .readOnly)
        }
        guard let baseAddress: UnsafeMutableRawPointer = CVPixelBufferGetBaseAddress(self) else {
            logger.error("Unable to get base address of video frame")
            return nil
        }
        let dataSize = CVPixelBufferGetDataSize(self)
//        debugPrint("LALAL data size \(dataSize)")
        //let int8Buffer: UnsafeMutablePointer<UInt8> = unsafeBitCast(baseAddress, to: UnsafeMutablePointer<UInt8>.self)

        guard let newBaseAddress: UnsafeMutableRawPointer = CVPixelBufferGetBaseAddress(newPixelBuffer) else {
            logger.error("Unable to get base address of new video frame")
            return nil
        }
//        var key: [CChar]? = aesKey?.cString(using: .utf8)
        let planeCount: Int = CVPixelBufferGetPlaneCount(self)
        if planeCount == 0 {
            let height = CVPixelBufferGetHeight(self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(self)
            let newBytesPerRow = CVPixelBufferGetBytesPerRow(newPixelBuffer)
            let len = height * newBytesPerRow
            if bytesPerRow == newBytesPerRow {
                memcpy(newBaseAddress, baseAddress, len)
            } else {
                var startOfRow = baseAddress
                var newStartOfRow = newBaseAddress
                for _ in 0..<height {
                    memcpy(newStartOfRow, startOfRow, min(bytesPerRow, newBytesPerRow))
                    startOfRow = startOfRow.advanced(by: bytesPerRow)
                    newStartOfRow = newStartOfRow.advanced(by: newBytesPerRow)
                }
            }
        } else {
            for plane in 0..<planeCount {
                let planeBaseAddress = CVPixelBufferGetBaseAddressOfPlane(self, plane)
                let newPlaneBaseAddress = CVPixelBufferGetBaseAddressOfPlane(newPixelBuffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(self, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(self, plane)
                let newBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(newPixelBuffer, plane)
                if bytesPerRow == newBytesPerRow {
                    memcpy(newPlaneBaseAddress, planeBaseAddress, height * bytesPerRow)
                } else {
                    var startOfRow = planeBaseAddress
                    var newStartOfRow = newPlaneBaseAddress
                    for _ in 0..<height {
                        memcpy(newStartOfRow, startOfRow, min(bytesPerRow, newBytesPerRow))
                        startOfRow = startOfRow?.advanced(by: bytesPerRow)
                        newStartOfRow = newStartOfRow?.advanced(by: newBytesPerRow)
                    }
                }
            }
        }
        //guard let newFrameMem: UnsafeMutableRawPointer = malloc(dataSize) else { fatalError() }
//            memcpy(newBaseAddress, baseAddress, dataSize)
        let newInt8Buffer: UnsafeMutablePointer<UInt8> = unsafeBitCast(newBaseAddress, to: UnsafeMutablePointer<UInt8>.self)
        /*var i = 0
        while i < dataSize / 3 * 2 {
            newInt8Buffer[i] = 1
            i += 1
        }*/
//        let data = Data.from(pixelBuffer: self)
//        pixelBuffer = CVPixelBuffer.from(data, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer))
        //CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        // IT'S FOR BGRA
        /*
         let int32Buffer: UnsafeMutablePointer<UInt32> = unsafeBitCast(CVPixelBufferGetBaseAddress(pixelBuffer), to: UnsafeMutablePointer<UInt32>.self)
        //debugPrint("LALAL \(CVPixelBufferGetWidth(pixelBuffer)) \(CVPixelBufferGetHeight(pixelBuffer))  \(frame.buffer.toI420())")
        let int32PerRow: Int = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // BGRA = Blue Green Red Alpha
        let totalPixels = frame.width * frame.height
        var t = 0
        var x = 0
        var y = 0
        while(t < totalPixels) {
            int32Buffer[x * 4 + y * int32PerRow] = 0
            t += 1
            if y == int32PerRow {
                y = 0
                x += 1
            } else {
                y += 1
            }
        }
        */
        //CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        return newPixelBuffer
    }
}

extension RTCVideoFrame {
    func encryption(_ aesKey: String, encrypt: Bool) -> RTCVideoFrame? {
        if let buffer: RTCCVPixelBuffer = self.buffer as? RTCCVPixelBuffer {
            let pixelBuffer: CVPixelBuffer = buffer.pixelBuffer
            if let newPixelBuffer = pixelBuffer.copy(aesKey, encrypt: encrypt) {
                let modifiedBuffer: RTCCVPixelBuffer = RTCCVPixelBuffer(pixelBuffer: newPixelBuffer)
//                print("LALAL1 \(modifiedBuffer) \(modifiedBuffer.width) \(modifiedBuffer.height) \(modifiedBuffer.pixelBuffer)")
                return RTCVideoFrame(buffer: modifiedBuffer, rotation: self.rotation, timeStampNs: self.timeStampNs)
            }
        } else if let buffer: RTCI420Buffer = self.buffer as? RTCI420Buffer {
            if let newPixelBuffer = buffer.encryption(aesKey, encrypt: false) {
                let modifiedBuffer: RTCCVPixelBuffer = RTCCVPixelBuffer(pixelBuffer: newPixelBuffer)
//                print("LALAL2 \(modifiedBuffer) \(modifiedBuffer.width) \(modifiedBuffer.height) \(modifiedBuffer.pixelBuffer)")
                return RTCVideoFrame(buffer: modifiedBuffer, rotation: self.rotation, timeStampNs: self.timeStampNs)
            }
        }
        return nil
    }
}

extension RTCI420Buffer {
    func encryption(_ aesKey: String, encrypt: Bool) -> CVPixelBuffer? {
        var newPixelBuffer: CVPixelBuffer!
        let res = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(self.width),
            Int(self.height),
            kCVPixelFormatType_420YpCbCr8PlanarFullRange,
            nil,
            &newPixelBuffer)
        guard res == kCVReturnSuccess else { fatalError() }

        CVPixelBufferLockBaseAddress(newPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        defer {
            CVPixelBufferUnlockBaseAddress(newPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        }
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(newPixelBuffer, 0)
        let uPlane = CVPixelBufferGetBaseAddressOfPlane(newPixelBuffer, 1)
        guard let uPlane = uPlane, let yPlane = yPlane else { return nil }
//        debugPrint("LALAL planes \(yPlane)  \(uPlane)   \(uPlane - yPlane)   \(Int(self.width) * Int(self.height) / 2)")
        var w = CVPixelBufferGetWidthOfPlane(newPixelBuffer, 0)
        var h = CVPixelBufferGetHeightOfPlane(newPixelBuffer, 0)
        memcpy(yPlane, self.dataY, w * h)
        memcpy(uPlane, self.dataU, (w * h) / 2)
//        memcpy(vPlane, self.dataV, w * h)
        return newPixelBuffer
    }
}

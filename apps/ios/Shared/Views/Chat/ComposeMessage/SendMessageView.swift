//
//  SendMessageView.swift
//  SimpleX
//
//  Created by Evgeny Poberezkin on 29/01/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

private let liveMsgInterval: UInt64 = 3000_000000

struct SendMessageView: View {
    @Binding var composeState: ComposeState
    var sendMessage: () -> Void
    var sendLiveMessage: (() async -> Void)? = nil
    var updateLiveMessage: (() async -> Void)? = nil
    var cancelLiveMessage: (() -> Void)? = nil
    var showVoiceMessageButton: Bool = true
    var voiceMessageAllowed: Bool = true
    var showEnableVoiceMessagesAlert: ChatInfo.ShowEnableVoiceMessagesAlert = .other
    var startVoiceMessageRecording: (() -> Void)? = nil
    var finishVoiceMessageRecording: (() -> Void)? = nil
    var allowVoiceMessagesToContact: (() -> Void)? = nil
    var onMediaAdded: ([UploadContent]) -> Void
    @State private var holdingVMR = false
    @Namespace var namespace
    @FocusState.Binding var keyboardVisible: Bool
    @State private var teHeight: CGFloat = 42
    @State private var teFont: Font = .body
    @State private var teUiFont: UIFont = UIFont.preferredFont(forTextStyle: .body)
    @State private var sendButtonSize: CGFloat = 29
    @State private var sendButtonOpacity: CGFloat = 1
    var maxHeight: CGFloat = 360
    var minHeight: CGFloat = 37
    @AppStorage(DEFAULT_LIVE_MESSAGE_ALERT_SHOWN) private var liveMessageAlertShown = false

    var body: some View {
        ZStack {
            HStack(alignment: .bottom) {
                ZStack(alignment: .leading) {
                    if case .voicePreview = composeState.preview {
                        Text("Voice message…")
                            .font(teFont.italic())
                            .multilineTextAlignment(.leading)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                    } else {
                        let alignment: TextAlignment = isRightToLeft(composeState.message) ? .trailing : .leading
                        Text(composeState.message)
                            .lineLimit(10)
                            .font(teFont)
                            .multilineTextAlignment(alignment)
// put text on top (after NativeTextEditor) and set color to precisely align it on changes
//                            .foregroundColor(.red)
                            .foregroundColor(.clear)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 6)
                            .matchedGeometryEffect(id: "te", in: namespace)
                            .background(GeometryReader(content: updateHeight))

                        NativeTextEditor(
                            text: $composeState.message,
                            height: teHeight,
                            font: teUiFont,
                            focused: $keyboardVisible,
                            alignment: alignment,
                            onImagesAdded: onMediaAdded
                        )
                        .allowsTightening(false)
                        .frame(height: teHeight)
                    }
                }

                if composeState.inProgress {
                    ProgressView()
                        .scaleEffect(1.4)
                        .frame(width: 31, height: 31, alignment: .center)
                        .padding([.bottom, .trailing], 3)
                } else {
                    VStack(alignment: .trailing) {
                        if teHeight > 100 {
                            deleteTextButton()
                            Spacer()
                        }
                        composeActionButtons()
                    }
                    .frame(height: teHeight, alignment: .bottom)
                }
            }

            RoundedRectangle(cornerSize: CGSize(width: 20, height: 20))
                .strokeBorder(.secondary, lineWidth: 0.3, antialiased: true)
                .frame(height: teHeight)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func composeActionButtons() -> some View {
        let vmrs = composeState.voiceMessageRecordingState
        if showVoiceMessageButton
            && composeState.message.isEmpty
            && !composeState.editing
            && composeState.liveMessage == nil
            && ((composeState.noPreview && vmrs == .noRecording)
                || (vmrs == .recording && holdingVMR)) {
            HStack {
                if voiceMessageAllowed {
                    RecordVoiceMessageButton(
                        startVoiceMessageRecording: startVoiceMessageRecording,
                        finishVoiceMessageRecording: finishVoiceMessageRecording,
                        holdingVMR: $holdingVMR,
                        disabled: composeState.disabled
                    )
                } else {
                    voiceMessageNotAllowedButton()
                }
                if let send = sendLiveMessage,
                   let update = updateLiveMessage,
                   case .noContextItem = composeState.contextItem {
                    startLiveMessageButton(send: send, update: update)
                }
            }
        } else if vmrs == .recording && !holdingVMR {
            finishVoiceMessageRecordingButton()
        } else if composeState.liveMessage != nil && composeState.liveMessage?.sentMsg == nil && composeState.message.isEmpty {
            cancelLiveMessageButton {
                cancelLiveMessage?()
            }
        } else {
            sendMessageButton()
        }
    }

    private func deleteTextButton() -> some View {
        Button {
            composeState.message = ""
        } label: {
            Image(systemName: "multiply.circle.fill")
        }
        .foregroundColor(Color(uiColor: .tertiaryLabel))
        .padding([.top, .trailing], 4)
    }

    @ViewBuilder private func sendMessageButton() -> some View {
        let v = Button(action: sendMessage) {
            Image(systemName: composeState.editing || composeState.liveMessage != nil
                                ? "checkmark.circle.fill"
                                : "arrow.up.circle.fill")
                .resizable()
                .foregroundColor(.accentColor)
                .frame(width: sendButtonSize, height: sendButtonSize)
                .opacity(sendButtonOpacity)
        }
        .disabled(
            !composeState.sendEnabled ||
            composeState.disabled ||
            (!voiceMessageAllowed && composeState.voicePreview) ||
            composeState.endLiveDisabled
        )
        .frame(width: 29, height: 29)

        if composeState.liveMessage == nil,
           case .noContextItem = composeState.contextItem,
           !composeState.voicePreview && !composeState.editing,
           let send = sendLiveMessage,
           let update = updateLiveMessage {
            v.contextMenu{
                Button {
                    startLiveMessage(send: send, update: update)
                } label: {
                    Label("Send live message", systemImage: "bolt.fill")
                }
            }
            .padding([.bottom, .trailing], 4)
        } else {
            v.padding([.bottom, .trailing], 4)
        }
    }

    private struct RecordVoiceMessageButton: View {
        var startVoiceMessageRecording: (() -> Void)?
        var finishVoiceMessageRecording: (() -> Void)?
        @Binding var holdingVMR: Bool
        var disabled: Bool
        @State private var pressed: TimeInterval? = nil

        var body: some View {
            Button(action: {}) {
                Image(systemName: "mic.fill")
                    .foregroundColor(.accentColor)
            }
            .disabled(disabled)
            .frame(width: 29, height: 29)
            .padding([.bottom, .trailing], 4)
            ._onButtonGesture { down in
                if down {
                    holdingVMR = true
                    pressed = ProcessInfo.processInfo.systemUptime
                    startVoiceMessageRecording?()
                } else {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let pressed = pressed,
                       now - pressed >= 1 {
                        finishVoiceMessageRecording?()
                    }
                    holdingVMR = false
                    pressed = nil
                }
            } perform: {}
        }
    }

    private func voiceMessageNotAllowedButton() -> some View {
        Button {
            switch showEnableVoiceMessagesAlert {
            case .userEnable:
                AlertManager.shared.showAlert(Alert(
                    title: Text("Allow voice messages?"),
                    message: Text("You need to allow your contact to send voice messages to be able to send them."),
                    primaryButton: .default(Text("Allow")) {
                        allowVoiceMessagesToContact?()
                    },
                    secondaryButton: .cancel()
                ))
            case .askContact:
                AlertManager.shared.showAlertMsg(
                    title: "Voice messages prohibited!",
                    message: "Please ask your contact to enable sending voice messages."
                )
            case .groupOwnerCan:
                AlertManager.shared.showAlertMsg(
                    title: "Voice messages prohibited!",
                    message: "Only group owners can enable voice messages."
                )
            case .other:
                AlertManager.shared.showAlertMsg(
                    title: "Voice messages prohibited!",
                    message: "Please check yours and your contact preferences."
                )
            }
        } label: {
            Image(systemName: "mic")
                .foregroundColor(.secondary)
        }
        .disabled(composeState.disabled)
        .frame(width: 29, height: 29)
        .padding([.bottom, .trailing], 4)
    }

    private func cancelLiveMessageButton(cancel: @escaping () -> Void) -> some View {
        return Button {
            cancel()
        } label: {
            Image(systemName: "multiply")
                .resizable()
                .scaledToFit()
                .foregroundColor(.accentColor)
                .frame(width: 15, height: 15)
        }
        .frame(width: 29, height: 29)
        .padding([.bottom, .horizontal], 4)
    }

    private func startLiveMessageButton(send:  @escaping () async -> Void, update: @escaping () async -> Void) -> some View {
        return Button {
            switch composeState.preview {
            case .noPreview: startLiveMessage(send: send, update: update)
            default: ()
            }
        } label: {
            Image(systemName: "bolt.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(.accentColor)
                .frame(width: 20, height: 20)
        }
        .frame(width: 29, height: 29)
        .padding([.bottom, .horizontal], 4)
    }

    private func startLiveMessage(send:  @escaping () async -> Void, update: @escaping () async -> Void) {
        if liveMessageAlertShown {
            start()
        } else {
            AlertManager.shared.showAlert(Alert(
                title: Text("Live message!"),
                message: Text("Send a live message - it will update for the recipient(s) as you type it"),
                primaryButton: .default(Text("Send")) {
                    liveMessageAlertShown = true
                    start()
                },
                secondaryButton: .cancel()
            ))
        }

        func start() {
            Task {
                await send()
                await MainActor.run { run() }
            }
        }

        @Sendable func run() {
            Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { t in
                withAnimation(.easeInOut(duration: 0.7)) {
                    sendButtonSize = sendButtonSize == 29 ? 26 : 29
                    sendButtonOpacity = sendButtonOpacity == 1 ? 0.75 : 1
                }
                if composeState.liveMessage == nil {
                    t.invalidate()
                    sendButtonSize = 29
                    sendButtonOpacity = 1
                }
            }
            Task {
                _ = try? await Task.sleep(nanoseconds: liveMsgInterval)
                while composeState.liveMessage != nil {
                    await update()
                    _ = try? await Task.sleep(nanoseconds: liveMsgInterval)
                }
            }
        }
    }

    private func finishVoiceMessageRecordingButton() -> some View {
        Button(action: { finishVoiceMessageRecording?() }) {
            Image(systemName: "stop.fill")
                .foregroundColor(.accentColor)
        }
        .disabled(composeState.disabled)
        .frame(width: 29, height: 29)
        .padding([.bottom, .trailing], 4)
    }

    private func updateHeight(_ g: GeometryProxy) -> Color {
        DispatchQueue.main.async {
            teHeight = min(max(g.frame(in: .local).size.height, minHeight), maxHeight)
            (teFont, teUiFont) = isShortEmoji(composeState.message)
                                    ? composeState.message.count < 4
                                        ? (largeEmojiFont, largeEmojiUIFont)
                                        : (mediumEmojiFont, mediumEmojiUIFont)
                                    : (.body, UIFont.preferredFont(forTextStyle: .body))
        }
        return Color.clear
    }
}

struct SendMessageView_Previews: PreviewProvider {
    static var previews: some View {
        @State var composeStateNew = ComposeState()
        let ci = ChatItem.getSample(1, .directSnd, .now, "hello")
        @State var composeStateEditing = ComposeState(editingItem: ci)
        @FocusState var keyboardVisible: Bool
        @State var sendEnabled: Bool = true

        return Group {
            VStack {
                Text("")
                Spacer(minLength: 0)
                SendMessageView(
                    composeState: $composeStateNew,
                    sendMessage: {},
                    onMediaAdded: { _ in },
                    keyboardVisible: $keyboardVisible
                )
            }
            VStack {
                Text("")
                Spacer(minLength: 0)
                SendMessageView(
                    composeState: $composeStateEditing,
                    sendMessage: {},
                    onMediaAdded: { _ in },
                    keyboardVisible: $keyboardVisible
                )
            }
        }
    }
}

import Foundation
import Speech
import AVFoundation
import Combine

class SpeechFollowEngine: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var isListening = false
    @Published var partialTranscript = ""
    @Published var activeLineIndex: Int = 0
    @Published var isDigressed: Bool = false
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var formattedLines: [String] = []
    private var endKeywords: [String] = []
    
    var onVoiceKeywordTriggered: ((String) -> Void)?
    var onLineIndexUpdated: ((Int) -> Void)?
    
    override init() {
        super.init()
        speechRecognizer?.delegate = self
        requestPermissions()
    }
    
    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                // 授权状态处理
            }
        }
    }
    
    /// 载入当前 Slide 的逐字稿与尾部关键词
    func loadSlideScript(script: String, keywords: [String]?) {
        self.formattedLines = HUDLayoutAdapter.shared.formatScriptToLines(script: script)
        self.endKeywords = keywords ?? []
        self.activeLineIndex = 0
        self.isDigressed = false
    }
    
    func startListening() {
        guard !audioEngine.isRunning else { return }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true
            
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, time in
                self.recognitionRequest?.append(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            
            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }
                if let result = result {
                    let transcript = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        self.partialTranscript = transcript
                        self.processTranscriptMatching(transcript)
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stopListening()
                }
            }
        } catch {
            isListening = false
        }
    }
    
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }
    
    /// 滑动窗口匹配：比较 partialTranscript 与当前 Slide 逐字稿行
    private func processTranscriptMatching(_ transcript: String) {
        guard !formattedLines.isEmpty else { return }
        
        // 1. 检查末尾关键词
        for keyword in endKeywords {
            if transcript.contains(keyword) {
                onVoiceKeywordTriggered?("NEXT")
                return
            }
        }
        
        // 2. 局部滑动窗口模糊匹配 (Matching last 10 chars)
        let tailString = String(transcript.suffix(12))
        var bestMatchIndex = activeLineIndex
        var maxSimilarity = 0
        
        let startIdx = max(0, activeLineIndex - 2)
        let endIdx = min(formattedLines.count - 1, activeLineIndex + 4)
        
        for idx in startIdx...endIdx {
            let line = formattedLines[idx]
            let sim = calculateOverlap(tailString, line)
            if sim > maxSimilarity {
                maxSimilarity = sim
                bestMatchIndex = idx
            }
        }
        
        if maxSimilarity >= 2 {
            self.activeLineIndex = bestMatchIndex
            self.isDigressed = false
            onLineIndexUpdated?(bestMatchIndex)
        } else {
            // 简单脱稿检测逻辑
        }
    }
    
    private func calculateOverlap(_ s1: String, _ s2: String) -> Int {
        var count = 0
        for char in s1 {
            if s2.contains(char) { count += 1 }
        }
        return count
    }
}

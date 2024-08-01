import Foundation
import AVFoundation

class AudioRecorder {
    private let audioEngine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private let outputFileURL: URL
    
    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputFileURL = documentsPath.appendingPathComponent("recording.wav")
    }
    
    func startRecording() {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        audioEngine.attach(mixer)
        audioEngine.connect(inputNode, to: mixer, format: inputFormat)
        audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: inputFormat)
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        do {
            audioFile = try AVAudioFile(forWriting: outputFileURL, settings: settings)
            
            mixer.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self, let audioFile = self.audioFile else { return }
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    print("Error writing audio: \(error.localizedDescription)")
                }
            }
            
            try audioEngine.start()
            isRecording = true
            print("Recording started. Press Enter to stop recording.")
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        audioEngine.stop()
        mixer.removeTap(onBus: 0)
        audioFile = nil
        isRecording = false
        print("Recording stopped.")
    }
    
    func transcribeAudio() {
        guard let apiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"] else {
            print("GROQ_API_KEY not set in environment variables")
            return
        }
        
        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        var body = Data()
        
        // Add file data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try! Data(contentsOf: outputFileURL))
        body.append("\r\n".data(using: .utf8)!)
        
        // Add other parameters
        let parameters = [
            "model": "whisper-large-v3",
            "temperature": "0",
            "response_format": "json",
            "language": "en"
        ]
        
        for (key, value) in parameters {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                print("Error: \(error.localizedDescription)")
                return
            }
            
            guard let data = data else {
                print("No data received")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let transcription = json["text"] as? String {
                    print("Transcription: \(transcription)")
                } else {
                    print("Invalid response format")
                }
            } catch {
                print("Error parsing JSON: \(error.localizedDescription)")
            }
        }
        
        task.resume()
        semaphore.wait()
    }
}

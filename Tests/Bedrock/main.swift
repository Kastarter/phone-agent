import Foundation

// VisionClient owns the real policy; the Bedrock adapter only needs URL parsing here.
enum ModelEndpointPolicy { static func url(_ text: String) throws -> URL { URL(string: text)! } }

@main struct BedrockChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) { guard condition else { fatalError(message) }; checks += 1 }

    static func main() throws {
        let creds = #"{"AccessKeyId":"ASIAEXAMPLE","SecretAccessKey":"secret","SessionToken":"token","Expiration":"2999-01-01T00:00:00Z"}"#

        expect(BedrockClient.region(for: URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com/chat/completions")!) == "eu-central-1", "region parse")
        expect(BedrockClient.region(for: URL(string: "https://api.openai.com/v1/chat/completions")!) == nil, "non-bedrock host")
        expect(BedrockClient.region(for: URL(string: "https://bedrock-runtime.evil.example.amazonaws.com.attacker.io/")!) == nil, "lookalike host")
        expect((try? BedrockClient.Credentials.parse(#"{"Credentials":\#(creds)}"#))?.SessionToken == "token", "accepts full STS output")
        expect((try? BedrockClient.Credentials.parse(#"{"AccessKeyId":"A","SecretAccessKey":"B","Expiration":"2001-01-01T00:00:00Z"}"#)) == nil, "rejects expired")
        expect((try? BedrockClient.Credentials.parse("sk-not-aws")) == nil, "rejects bearer key")

        // Chat Completions -> Converse
        var chat = URLRequest(url: URL(string: BedrockClient.endpoint())!)
        chat.httpMethod = "POST"
        chat.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "global.openai.gpt-6-luna", "max_completion_tokens": 2048, "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "rules"],
                ["role": "assistant", "content": "earlier reply"],
                ["role": "user", "content": "first"],
                ["role": "user", "content": [["type": "text", "text": "look"], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA", "detail": "high"]]]],
            ],
        ] as [String: Any])
        let request = try BedrockClient.converseRequest(from: chat, credentials: creds)
        expect(request.url?.absoluteString == "https://bedrock-runtime.eu-central-1.amazonaws.com/model/global.openai.gpt-6-luna/converse", "converse URL")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        expect((body["system"] as? [[String: Any]])?.first?["text"] as? String == "rules", "system prompt moved to system")
        let messages = body["messages"] as! [[String: Any]]
        expect(messages.map { $0["role"] as! String } == ["user", "assistant", "user"], "starts with user and alternates")
        let last = messages[2]["content"] as! [[String: Any]]
        expect(last.count == 3, "consecutive user turns merged")
        let image = last[2]["image"] as? [String: Any]
        expect(image?["format"] as? String == "jpeg" && (image?["source"] as? [String: Any])?["bytes"] as? String == "AAAA", "image block")
        expect((body["inferenceConfig"] as? [String: Any])?["maxTokens"] as? Int == 2048, "token limit")
        expect(body["response_format"] == nil, "response_format dropped")
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=ASIAEXAMPLE/") && auth.contains("/eu-central-1/bedrock/aws4_request"), "SigV4 scope")
        expect(auth.contains("SignedHeaders=content-type;host;x-amz-date;x-amz-security-token"), "signed headers")
        expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "token", "session token header")

        // Model ARNs need escaping in the path.
        var arnChat = chat
        arnChat.httpBody = try JSONSerialization.data(withJSONObject: ["model": "arn:aws:bedrock:eu-central-1:1:inference-profile/x", "messages": [["role": "user", "content": "hi"]]])
        expect(try BedrockClient.converseRequest(from: arnChat, credentials: creds).url!.absoluteString.contains("/model/arn%3Aaws%3Abedrock%3Aeu-central-1%3A1%3Ainference-profile%2Fx/converse"), "ARN path escaping")

        // Converse -> Chat Completions
        let ok = try JSONSerialization.data(withJSONObject: ["output": ["message": ["role": "assistant", "content": [["reasoningContent": ["x": 1]], ["text": "{\"kind\":\"wait\"}"]]]],
                                                             "stopReason": "max_tokens", "usage": ["inputTokens": 5, "outputTokens": 7, "totalTokens": 12]])
        let mapped = try JSONSerialization.jsonObject(with: BedrockClient.chatCompletionsBody(fromConverse: ok, status: 200)) as! [String: Any]
        let choice = (mapped["choices"] as! [[String: Any]])[0]
        expect((choice["message"] as! [String: Any])["content"] as? String == "{\"kind\":\"wait\"}", "text extracted, reasoning skipped")
        expect(choice["finish_reason"] as? String == "length", "stop reason mapped")
        let error = try JSONSerialization.jsonObject(with: BedrockClient.chatCompletionsBody(fromConverse: Data(#"{"message":"denied"}"#.utf8), status: 403)) as! [String: Any]
        expect((error["error"] as? [String: Any])?["message"] as? String == "denied", "error message kept")

        print("\(checks) Bedrock adapter checks passed. No network actions.")
    }
}

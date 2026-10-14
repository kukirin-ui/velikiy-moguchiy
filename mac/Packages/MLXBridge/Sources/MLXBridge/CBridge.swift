#if arch(arm64)

import Foundation

// Singleton manager instance
private var manager = MLXAsrManager()

@_cdecl("sp_mlx_load_model")
public func spMLXLoadModel(_ modelPath: UnsafePointer<CChar>?) -> Int32 {
    guard let modelPath = modelPath else { return -1 }
    let path = String(cString: modelPath)
    return manager.loadModel(path: path) ? 0 : -1
}

@_cdecl("sp_mlx_start_session")
public func spMLXStartSession(
    _ language: UnsafePointer<CChar>?,
    _ delayPreset: UnsafePointer<CChar>?,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> UInt64 {
    let lang = language.map { String(cString: $0) } ?? "auto"
    let preset = delayPreset.map { String(cString: $0) } ?? "realtime"
    return manager.startSession(
        language: lang,
        delayPreset: preset,
        callback: callback,
        context: ctx
    )
}

@_cdecl("sp_mlx_feed_audio")
public func spMLXFeedAudio(_ samples: UnsafePointer<Float>?, _ count: UInt32, _ generation: UInt64) {
    guard let samples = samples else { return }
    manager.feedAudio(samples, count: Int(count), generation: generation)
}

@_cdecl("sp_mlx_stop")
public func spMLXStop(_ generation: UInt64) {
    manager.stop(generation: generation)
}

@_cdecl("sp_mlx_cancel")
public func spMLXCancel(_ generation: UInt64) {
    manager.cancel(generation: generation)
}

@_cdecl("sp_mlx_unload_model")
public func spMLXUnloadModel() {
    manager.unloadModel()
}

// ─── LLM Bridge ────────────────────────────────────────────────────

private var llmManager = MLXLlmManager()

@_cdecl("sp_mlx_llm_generate")
public func spMLXLlmGenerate(
    _ modelPath: UnsafePointer<CChar>?,
    _ systemPrompt: UnsafePointer<CChar>?,
    _ userPrompt: UnsafePointer<CChar>?,
    _ temperature: Float,
    _ topP: Float,
    _ maxTokens: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard let modelPath = modelPath,
          let systemPrompt = systemPrompt,
          let userPrompt = userPrompt else { return nil }

    let path = String(cString: modelPath)
    let system = String(cString: systemPrompt)
    let user = String(cString: userPrompt)

    guard let result = llmManager.generate(
        modelPath: path,
        systemPrompt: system,
        userPrompt: user,
        temperature: temperature,
        topP: topP,
        maxTokens: Int(maxTokens)
    ) else { return nil }

    return strdup(result)
}

@_cdecl("sp_mlx_llm_free_string")
public func spMLXLlmFreeString(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

@_cdecl("sp_mlx_llm_unload_model")
public func spMLXLlmUnloadModel() {
    llmManager.unloadModel()
}

#endif

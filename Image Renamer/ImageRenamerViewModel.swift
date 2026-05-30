import SwiftUI
import Combine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if canImport(Vision)
import Vision
#endif

#if canImport(CoreML)
struct TranslationService {
    // MARK: Model URLs and instances
    private let encoderURL: URL
    private let decoderURL: URL
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var didLogModelInfo: Bool = false

    var logger: ((String) -> Void)?

    // MARK: Tokenizer resources
    private let tokenizerFolder: URL
    private var vocab: [String: Int] = [:]
    private var invVocab: [Int: String] = [:]
    private var mergesRank: [String: Int] = [:] // "a b" -> rank
    private var bosToken: String?
    private var eosToken: String?
    private var padToken: String?
    private var unkToken: String?

    init(encoderModelURL: URL, decoderModelURL: URL) {
        self.encoderURL = encoderModelURL
        self.decoderURL = decoderModelURL
        // Assume folder structure: ./{Encoder,Decoder}.mlmodelc
        self.tokenizerFolder = decoderModelURL.deletingLastPathComponent()
    }

    mutating func load() throws {
        if encoder == nil { encoder = try MLModel(contentsOf: encoderURL) }
        if decoder == nil { decoder = try MLModel(contentsOf: decoderURL) }
        if vocab.isEmpty { try loadTokenizer() }
        try loadTokenizerConfig()
        logger?("TranslationService loaded")
        if !didLogModelInfo, let encoder, let decoder {
            logModelDescription(encoder, name: "Encoder")
            logModelDescription(decoder, name: "Decoder")
            didLogModelInfo = true
        }
    }

    // MARK: Public API

    /// Translates an English string to the target language. If target is English, returns input.
    mutating func translate(_ text: String, to target: FilenameLanguage) throws -> String {
        if target == .english { return text }
        guard let decoder else { return text }

        let resolvedTarget = resolvedLanguageToken(for: target)
        let preview = String(text.prefix(80))
        logger?("Translate request target=\(target.rawValue) token=\(resolvedTarget) text=\(preview)")

        // 1) Attempt: decoder exposes (text, tgt_lang) -> text string interface
        if let out = try stringIOTranslate(text, to: resolvedTarget, using: decoder) {
            logger?("Translation path=stringIO output=\(String(out.prefix(80)))")
            return out
        }
        // 2) Attempt: single string input; prefix target token and decode
        if let out = try singleStringInputTranslate(text, to: resolvedTarget, using: decoder) {
            logger?("Translation path=singleString output=\(String(out.prefix(80)))")
            return out
        }
        // 3) Attempt: full encoder/decoder greedy decoding with tokenizer
        if let out = try greedySeq2SeqTranslate(text, to: resolvedTarget) {
            logger?("Translation path=greedySeq2Seq output=\(String(out.prefix(80)))")
            return out
        }

        throw NSError(domain: "TranslationService", code: -102, userInfo: [NSLocalizedDescriptionKey: "No supported translation interface found in models."])
    }

    // MARK: Language tokens

    /// Map UI language to NLLB-style language tag. Overridable via tokenizer/lang_tokens.json
    private func targetToken(for lang: FilenameLanguage) -> String {
        let defaults: [FilenameLanguage: String] = [
            .english: "__eng_Latn__",
            .french:  "__fra_Latn__",
            .german:  "__deu_Latn__",
            .spanish: "__spa_Latn__"
        ]
        // 1) Prefer explicit lang_tokens.json inside tokenizer folder
        let langTokensURL = tokenizerFolder.appendingPathComponent("lang_tokens.json")
        if let data = try? Data(contentsOf: langTokensURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            func lookup(_ key: String) -> String? { dict[key] }
            switch lang {
            case .english: return lookup("en") ?? lookup("English") ?? defaults[.english]!
            case .french:  return lookup("fr") ?? lookup("French")  ?? defaults[.french]!
            case .german:  return lookup("de") ?? lookup("German")  ?? defaults[.german]!
            case .spanish: return lookup("es") ?? lookup("Spanish") ?? defaults[.spanish]!
            }
        }
        // 2) Fallback to language_codes.json (sibling of tokenizer folder)
        let base = tokenizerFolder // TranslationModels/
        let codesURL = base.appendingPathComponent("language_codes.json")
        if let data = try? Data(contentsOf: codesURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            func lookup(_ key: String) -> String? { dict[key] }
            switch lang {
            case .english: return lookup("en") ?? lookup("English") ?? defaults[.english]!
            case .french:  return lookup("fr") ?? lookup("French")  ?? defaults[.french]!
            case .german:  return lookup("de") ?? lookup("German")  ?? defaults[.german]!
            case .spanish: return lookup("es") ?? lookup("Spanish") ?? defaults[.spanish]!
            }
        }
        // 3) Defaults
        return defaults[lang]!
    }

    private func resolvedLanguageToken(for lang: FilenameLanguage) -> String {
        resolveTokenVariant(targetToken(for: lang))
    }

    private func resolveTokenVariant(_ token: String) -> String {
        let candidates = [
            token,
            "__\(token)__",
            ">>\(token)<<",
            "<2\(token)>"
        ]
        for candidate in candidates {
            if vocab[candidate] != nil { return candidate }
        }
        return token
    }

    // MARK: Tokenizer loading

    private mutating func loadTokenizer() throws {
        // Try HuggingFace-style tokenizer.json
        let tokURL = tokenizerFolder.appendingPathComponent("tokenizer.json")
        if let data = try? Data(contentsOf: tokURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = json["model"] as? [String: Any] {
            if let vocabDict = model["vocab"] as? [String: Int] {
                self.vocab = vocabDict
                self.invVocab = Dictionary(uniqueKeysWithValues: vocabDict.map { ($0.value, $0.key) })
            } else if let vocabArr = model["vocab"] as? [[String: Any]] {
                // Some formats store an array of {"token": String, "id": Int}
                var map: [String: Int] = [:]
                for entry in vocabArr {
                    if let token = entry["token"] as? String, let id = entry["id"] as? Int { map[token] = id }
                }
                self.vocab = map
                self.invVocab = Dictionary(uniqueKeysWithValues: map.map { ($0.value, $0.key) })
            }
            // Load added tokens if present
            if let added = json["added_tokens"] as? [[String: Any]] {
                for entry in added {
                    if let content = entry["content"] as? String, let id = entry["id"] as? Int {
                        self.vocab[content] = id
                        self.invVocab[id] = content
                    }
                }
            }
            // Load merges for SentencePiece BPE if present
            if let merges = (model["merges"] as? [String]) ?? (json["merges"] as? [String]) {
                var rank: [String: Int] = [:]
                for (i, m) in merges.enumerated() {
                    rank[m] = i
                }
                self.mergesRank = rank
            }
        }
        // Fallback: vocab.json (BPE) style
        if vocab.isEmpty {
            let vocabURL = tokenizerFolder.appendingPathComponent("vocab.json")
            if let data = try? Data(contentsOf: vocabURL),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
                self.vocab = dict
                self.invVocab = Dictionary(uniqueKeysWithValues: dict.map { ($0.value, $0.key) })
            }
        }
        guard !vocab.isEmpty else {
            throw NSError(domain: "TranslationService", code: -200, userInfo: [NSLocalizedDescriptionKey: "Tokenizer vocab not found in \(tokenizerFolder.path)"])
        }
    }

    private mutating func loadTokenizerConfig() throws {
        // tokenizer_config.json may contain special tokens
        let configURL = tokenizerFolder.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let val = (json["bos_token"] as? [String: Any])?["content"] as? String { bosToken = val }
            if let val = (json["eos_token"] as? [String: Any])?["content"] as? String { eosToken = val }
            if let val = (json["pad_token"] as? [String: Any])?["content"] as? String { padToken = val }
            if let val = (json["unk_token"] as? [String: Any])?["content"] as? String { unkToken = val }
            if let val = json["bos_token"] as? String { bosToken = val }
            if let val = json["eos_token"] as? String { eosToken = val }
            if let val = json["pad_token"] as? String { padToken = val }
            if let val = json["unk_token"] as? String { unkToken = val }
        }
        // If still missing, infer from vocab entries
        if bosToken == nil { bosToken = vocab.keys.first(where: { $0.lowercased().contains("bos") }) }
        if eosToken == nil { eosToken = vocab.keys.first(where: { $0.lowercased().contains("eos") || $0 == "</s>" }) }
        if padToken == nil { padToken = vocab.keys.first(where: { $0.lowercased().contains("pad") }) }
        if unkToken == nil { unkToken = vocab.keys.first(where: { $0.lowercased().contains("unk") || $0 == "<unk>" }) }
    }

    // MARK: Tokenization

    private func id(for token: String) -> Int? { vocab[token] }
    private func token(for id: Int) -> String? { invVocab[id] }

    private func encode(_ text: String) -> [Int] {
        // Realistic SentencePiece-BPE style encoding using merges when available.
        // 1) Split into words by whitespace/punctuation
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        var ids: [Int] = []
        for w in words {
            let token = "▁" + w
            // If no merges available, fall back to direct vocab lookup or unk
            if mergesRank.isEmpty {
                if let id = vocab[token] { ids.append(id) }
                else if let id = vocab[w] { ids.append(id) }
                else if let unk = unkToken, let id = vocab[unk] { ids.append(id) }
                continue
            }
            // Apply BPE to the token
            let pieces = bpe(token)
            for p in pieces {
                if let id = vocab[p] { ids.append(id) }
                else if let unk = unkToken, let id = vocab[unk] { ids.append(id) }
            }
        }
        return ids
    }

    private func getPairs(_ symbols: [String]) -> Set<String> {
        guard symbols.count >= 2 else { return [] }
        var pairs: Set<String> = []
        for i in 0..<(symbols.count - 1) {
            pairs.insert(symbols[i] + " " + symbols[i + 1])
        }
        return pairs
    }

    private func bpe(_ token: String) -> [String] {
        // Split token into characters (Unicode scalars) to be mergeable units
        var symbols: [String] = token.unicodeScalars.map { String($0) }
        if symbols.isEmpty { return [] }
        var pairs = getPairs(symbols)
        while true {
            // Find the best-ranked pair to merge
            var minRank = Int.max
            var best: String? = nil
            for p in pairs {
                if let r = mergesRank[p], r < minRank { minRank = r; best = p }
            }
            guard let pair = best else { break }
            let comps = pair.split(separator: " ", maxSplits: 1).map(String.init)
            guard comps.count == 2 else { break }
            let first = comps[0]
            let second = comps[1]
            // Merge all occurrences of (first, second)
            var i = 0
            var newSymbols: [String] = []
            while i < symbols.count {
                if i < symbols.count - 1 && symbols[i] == first && symbols[i + 1] == second {
                    newSymbols.append(first + second)
                    i += 2
                } else {
                    newSymbols.append(symbols[i])
                    i += 1
                }
            }
            if newSymbols == symbols { break }
            symbols = newSymbols
            pairs = getPairs(symbols)
        }
        return symbols
    }

    private func decode(_ ids: [Int]) -> String {
        var tokens: [String] = []
        for id in ids {
            if let t = invVocab[id] {
                // Skip special tokens
                if t == bosToken || t == eosToken || t == padToken { continue }
                tokens.append(t)
            }
        }
        // Join and clean SentencePiece markers
        let joined = tokens.joined(separator: " ")
        return joined.replacingOccurrences(of: "▁", with: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: String IO paths

    private func stringIOTranslate(_ text: String, to targetToken: String, using model: MLModel) throws -> String? {
        let desc = model.modelDescription
        let sourceKeys = ["text", "src_text", "input_text", "source", "source_text"]
        let langKeys = ["tgt_lang", "target_lang", "lang", "language"]
        let outputKeys = ["text", "translation", "output_text", "target", "target_text"]
        guard let sourceKey = sourceKeys.first(where: { desc.inputDescriptionsByName[$0]?.type == .string }) else {
            logger?("stringIO: no string source input. inputs=\(desc.inputDescriptionsByName.keys.sorted())")
            return nil
        }
        guard let langKey = langKeys.first(where: { desc.inputDescriptionsByName[$0]?.type == .string }) else {
            logger?("stringIO: no language string input. inputs=\(desc.inputDescriptionsByName.keys.sorted())")
            return nil
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            sourceKey: MLFeatureValue(string: text),
            langKey: MLFeatureValue(string: targetToken)
        ])
        let prediction = try model.prediction(from: features)
        if let key = outputKeys.first(where: { prediction.featureValue(for: $0)?.type == .string }),
           let val = prediction.featureValue(for: key)?.stringValue, !val.isEmpty { return val }
        for name in prediction.featureNames {
            if let fv = prediction.featureValue(for: name), fv.type == .string, !fv.stringValue.isEmpty { return fv.stringValue }
        }
        return nil
    }

    private func singleStringInputTranslate(_ text: String, to targetToken: String, using model: MLModel) throws -> String? {
        let desc = model.modelDescription
        guard let inputKey = desc.inputDescriptionsByName.first(where: { $0.value.type == .string })?.key else {
            logger?("singleString: no string input. inputs=\(desc.inputDescriptionsByName.keys.sorted())")
            return nil
        }
        let prompt: String
        if let bos = bosToken { prompt = "\(targetToken) \(bos) \(text)" } else { prompt = "\(targetToken) \(text)" }
        let features = try MLDictionaryFeatureProvider(dictionary: [ inputKey: MLFeatureValue(string: prompt) ])
        let prediction = try model.prediction(from: features)
        if let key = prediction.featureNames.first(where: { prediction.featureValue(for: $0)?.type == .string }),
           let val = prediction.featureValue(for: key)?.stringValue, !val.isEmpty { return val }
        return nil
    }

    // MARK: Encoder/Decoder greedy decode

    private mutating func greedySeq2SeqTranslate(_ text: String, to targetToken: String) throws -> String? {
        guard let encoder, let decoder else { return nil }
        // Encode source text to ids
        var srcIds = encode(text)
        let sourceToken = resolveTokenVariant(self.targetToken(for: .english))
        if let srcLangId = id(for: sourceToken) {
            logger?("Encoder source token=\(sourceToken) id=\(srcLangId)")
            srcIds.append(srcLangId)
        } else {
            logger?("Encoder source token not found in vocab: \(sourceToken)")
        }
        if let eosToken, let eosId = id(for: eosToken) {
            srcIds.append(eosId)
        }
        guard !srcIds.isEmpty else { return text }

        // Prepare encoder inputs
        let encDesc = encoder.modelDescription
        var encInputs: [String: MLFeatureValue] = [:]
        let padId = padToken.flatMap { id(for: $0) } ?? 0
        let encMaxLen: Int = {
            if let shape = encDesc.inputDescriptionsByName["input_ids"]?.multiArrayConstraint?.shape, shape.count == 2 {
                return shape[1].intValue
            }
            return srcIds.count
        }()
        if srcIds.count > encMaxLen { srcIds = Array(srcIds.prefix(encMaxLen)) }
        // Find input_ids-like key with explicit preference for "input_ids"
        let encIdsKey = encDesc.inputDescriptionsByName["input_ids"] != nil ? "input_ids" : (findKey(in: encDesc.inputDescriptionsByName, candidates: ["src_ids", "encoder_input_ids", "tokens"]) ?? encDesc.inputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key)
        if let key = encIdsKey, let desc = encDesc.inputDescriptionsByName[key] {
            if let fv = try paddedMultiArrayFeature(from: srcIds, for: desc, padId: padId) {
                encInputs[key] = fv
            }
        } else {
            logger?("Encoder input_ids key not found. inputs=\(encDesc.inputDescriptionsByName.keys.sorted())")
        }
        // attention_mask if present; prefer "attention_mask"
        let encMaskKey = encDesc.inputDescriptionsByName["attention_mask"] != nil ? "attention_mask" : findKey(in: encDesc.inputDescriptionsByName, candidates: ["src_attention_mask"])
        if let maskKey = encMaskKey {
            if let fv = try onesMaskFeature(matching: encDesc.inputDescriptionsByName[maskKey], validLength: srcIds.count) { encInputs[maskKey] = fv }
        }
        let encProvider = try MLDictionaryFeatureProvider(dictionary: encInputs)
        let encOut = try encoder.prediction(from: encProvider)
        // Find encoder hidden states output with preference for "var_"
        let encHiddenKey = encOut.featureNames.contains("var_") ? "var_" : (findKey(in: encOut, candidates: ["last_hidden_state", "encoder_hidden_states", "hidden_states"]) ?? encOut.featureNames.first(where: { encOut.featureValue(for: $0)?.type == .multiArray }))
        guard let hiddenKey = encHiddenKey, let hidden = encOut.featureValue(for: hiddenKey)?.multiArrayValue else {
            logger?("Encoder hidden states not found. outputs=\(describeProvider(encOut))")
            return nil
        }

        // Decoder loop
        var generated: [Int] = []
        // Use BOS + target language token when both exist; otherwise fall back to language token
        let langId = id(for: targetToken)
        let bosId = bosToken.flatMap { id(for: $0) }
        let eosId = eosToken.flatMap { id(for: $0) }
        logger?("Decoder target token=\(targetToken) langId=\(langId.map(String.init) ?? "nil") bosId=\(bosId.map(String.init) ?? "nil") padId=\(padId) eosId=\(eosId.map(String.init) ?? "nil")")
        if let bosId, let langId, bosId != padId {
            generated.append(bosId)
            generated.append(langId)
        } else if let langId {
            generated.append(langId)
        } else if let bosId, bosId != padId {
            generated.append(bosId)
        }
        let maxNewTokens = 40

        let decDesc = decoder.modelDescription
        let decMaxLen: Int = {
            if let shape = decDesc.inputDescriptionsByName["decoder_input_ids"]?.multiArrayConstraint?.shape, shape.count == 2 {
                return shape[1].intValue
            }
            return 256
        }()
        for _ in 0..<maxNewTokens {
            if generated.count >= decMaxLen { break }
            var decInputs: [String: MLFeatureValue] = [:]
            // decoder input ids, prefer known candidate keys or first int32 multiArray input
            let decIdsKey: String? = {
                if let k = findKey(in: decDesc.inputDescriptionsByName, candidates: ["decoder_input_ids", "input_ids", "tgt_ids"]) { return k }
                // Fallback: first int-typed multiArray input
                for (k, d) in decDesc.inputDescriptionsByName {
                    if d.type == .multiArray, let t = d.multiArrayConstraint?.dataType, t == .int32 { return k }
                }
                return decDesc.inputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key
            }()
            if let key = decIdsKey, let desc = decDesc.inputDescriptionsByName[key] {
                if let fv = try paddedMultiArrayFeature(from: generated, for: desc, padId: padId) { decInputs[key] = fv }
            }
            // pass encoder hidden states with preference for "var_"
            let encHiddenInKey: String? = {
                if decDesc.inputDescriptionsByName["encoder_hidden_states"] != nil { return "encoder_hidden_states" }
                if decDesc.inputDescriptionsByName["hidden_states"] != nil { return "hidden_states" }
                if decDesc.inputDescriptionsByName["memory"] != nil { return "memory" }
                if decDesc.inputDescriptionsByName["var_"]?.type == .multiArray { return "var_" }
                for (k, d) in decDesc.inputDescriptionsByName {
                    if d.type == .multiArray, let t = d.multiArrayConstraint?.dataType, (t == .float32 || t == .double) { return k }
                }
                return nil
            }()
            if let key = encHiddenInKey { decInputs[key] = MLFeatureValue(multiArray: hidden) }
            // decoder attention mask if present with preference for "decoder_attention_mask"
            let decMaskKey: String? = {
                if decDesc.inputDescriptionsByName["decoder_attention_mask"] != nil { return "decoder_attention_mask" }
                if decDesc.inputDescriptionsByName["encoder_attention_mask"] != nil { return "encoder_attention_mask" }
                if decDesc.inputDescriptionsByName["attention_mask"]?.multiArrayConstraint?.dataType == .int32 { return "attention_mask" }
                // Find another int32 multiArray different from decIdsKey
                for (k, d) in decDesc.inputDescriptionsByName {
                    if k == decIdsKey { continue }
                    if d.type == .multiArray, let t = d.multiArrayConstraint?.dataType, t == .int32 { return k }
                }
                return nil
            }()
            if generated.count == 1 {
                logger?("Decoder input keys ids=\(decIdsKey ?? "nil") hidden=\(encHiddenInKey ?? "nil") mask=\(decMaskKey ?? "nil") inputs=\(decDesc.inputDescriptionsByName.keys.sorted())")
            }
            if let maskKey = decMaskKey, let fv = try onesMaskFeature(matching: decDesc.inputDescriptionsByName[maskKey], validLength: srcIds.count) { decInputs[maskKey] = fv }
            // Optional language string input
            if let langKey = decDesc.inputDescriptionsByName.first(where: { $0.value.type == .string && ["tgt_lang","target_lang","lang","language"].contains($0.key) })?.key {
                decInputs[langKey] = MLFeatureValue(string: targetToken)
            }
            let decProvider = try MLDictionaryFeatureProvider(dictionary: decInputs)
            let decOut = try decoder.prediction(from: decProvider)

            // Choose logits output and take argmax of last position
            guard let logits = chooseLogits(from: decOut) else {
                logger?("Decoder logits not found. outputs=\(describeProvider(decOut))")
                break
            }
            let nextId = argmax(from: logits, position: max(generated.count - 1, 0))
            if generated.count < 6 {
                let token = invVocab[nextId] ?? "?"
                logger?("Decoder step=\(generated.count) nextId=\(nextId) token=\(token)")
            }
            // Stop if EOS reached
            if let eosId, nextId == eosId { break }
            generated.append(nextId)
        }

        // Drop BOS and target language tokens before decoding
        var toDecode = generated
        if let first = toDecode.first, first == (bosId ?? -1) { toDecode.removeFirst() }
        if let first = toDecode.first, first == (langId ?? -1) { toDecode.removeFirst() }
        if toDecode.isEmpty {
            logger?("Decoder produced no content tokens")
            return nil
        }
        let textOut = decode(toDecode)
        return textOut.isEmpty ? nil : textOut
    }

    // MARK: Helpers

    private func logModelDescription(_ model: MLModel, name: String) {
        let desc = model.modelDescription
        let inputInfo = describeFeatureDescriptions(desc.inputDescriptionsByName)
        let outputInfo = describeFeatureDescriptions(desc.outputDescriptionsByName)
        logger?("\(name) inputs: \(inputInfo)")
        logger?("\(name) outputs: \(outputInfo)")
    }

    private func describeFeatureDescriptions(_ descriptions: [String: MLFeatureDescription]) -> String {
        let items = descriptions.keys.sorted().map { key -> String in
            guard let d = descriptions[key] else { return key }
            return "\(key)=\(describeFeatureDescription(d))"
        }
        return items.joined(separator: ", ")
    }

    private func describeFeatureDescription(_ desc: MLFeatureDescription) -> String {
        switch desc.type {
        case .string:
            return "string"
        case .image:
            return "image"
        case .dictionary:
            return "dictionary"
        case .multiArray:
            let shape = desc.multiArrayConstraint?.shape.map { $0.intValue } ?? []
            let type = multiArrayTypeDescription(desc.multiArrayConstraint?.dataType)
            return "multiArray\(shape) \(type)"
        default:
            return "other"
        }
    }

    private func multiArrayTypeDescription(_ dataType: MLMultiArrayDataType?) -> String {
        switch dataType {
        case .int32:
            return "int32"
        case .double:
            return "double"
        case .float32:
            return "float32"
        default:
            return "unknown"
        }
    }

    private func describeProvider(_ provider: MLFeatureProvider) -> String {
        let items = provider.featureNames.sorted().compactMap { name -> String? in
            guard let fv = provider.featureValue(for: name) else { return nil }
            return "\(name)=\(describeFeatureValue(fv))"
        }
        return items.joined(separator: ", ")
    }

    private func describeFeatureValue(_ fv: MLFeatureValue) -> String {
        switch fv.type {
        case .string:
            return "string"
        case .image:
            return "image"
        case .dictionary:
            return "dictionary"
        case .multiArray:
            if let ma = fv.multiArrayValue {
                let shape = ma.shape.map { $0.intValue }
                let type = multiArrayTypeDescription(ma.dataType)
                return "multiArray\(shape) \(type)"
            }
            return "multiArray"
        default:
            return "other"
        }
    }

    private func findKey(in dict: [String: MLFeatureDescription], candidates: [String]) -> String? {
        for c in candidates { if dict[c] != nil { return c } }
        return nil
    }

    private func findKey(in provider: MLFeatureProvider, candidates: [String]) -> String? {
        for c in candidates { if provider.featureValue(for: c) != nil { return c } }
        return nil
    }

    private func multiArrayFeature(from ids: [Int], for desc: MLFeatureDescription?) throws -> MLFeatureValue? {
        guard let desc, desc.type == .multiArray else { return nil }
        let dataType = desc.multiArrayConstraint?.dataType ?? .int32
        // Determine shape: use constraint.shape if provided; otherwise default to [1, seq]
        let shape: [NSNumber]
        if let s = desc.multiArrayConstraint?.shape, !s.isEmpty {
            shape = s
        } else {
            shape = [NSNumber(value: 1), NSNumber(value: ids.count)]
        }
        let arr = try MLMultiArray(shape: shape, dataType: dataType)
        if shape.count == 2 && shape[0].intValue == 1 {
            for (i, v) in ids.enumerated() { set(arr: arr, value: v, at: [0, i]) }
        } else {
            for (i, v) in ids.enumerated() { set(arr: arr, value: v, at: [i]) }
        }
        return MLFeatureValue(multiArray: arr)
    }

    private func paddedMultiArrayFeature(from ids: [Int], for desc: MLFeatureDescription?, padId: Int) throws -> MLFeatureValue? {
        guard let desc, desc.type == .multiArray else { return nil }
        let dataType = desc.multiArrayConstraint?.dataType ?? .int32
        let shape: [NSNumber]
        if let s = desc.multiArrayConstraint?.shape, !s.isEmpty {
            shape = s
        } else {
            shape = [NSNumber(value: 1), NSNumber(value: ids.count)]
        }
        let arr = try MLMultiArray(shape: shape, dataType: dataType)
        if shape.count == 2 && shape[0].intValue == 1 {
            let maxLen = shape[1].intValue
            for i in 0..<maxLen { set(arr: arr, value: padId, at: [0, i]) }
            let count = min(ids.count, maxLen)
            for i in 0..<count { set(arr: arr, value: ids[i], at: [0, i]) }
        } else {
            let maxLen = shape.first?.intValue ?? ids.count
            for i in 0..<maxLen { set(arr: arr, value: padId, at: [i]) }
            let count = min(ids.count, maxLen)
            for i in 0..<count { set(arr: arr, value: ids[i], at: [i]) }
        }
        return MLFeatureValue(multiArray: arr)
    }

    private func rightAlignedMultiArrayFeature(from ids: [Int], for desc: MLFeatureDescription?, padId: Int) throws -> (MLFeatureValue, Int)? {
        guard let desc, desc.type == .multiArray else { return nil }
        let dataType = desc.multiArrayConstraint?.dataType ?? .int32
        let shape: [NSNumber]
        if let s = desc.multiArrayConstraint?.shape, !s.isEmpty {
            shape = s
        } else {
            shape = [NSNumber(value: 1), NSNumber(value: ids.count)]
        }
        let arr = try MLMultiArray(shape: shape, dataType: dataType)
        if shape.count == 2 && shape[0].intValue == 1 {
            let maxLen = shape[1].intValue
            for i in 0..<maxLen { set(arr: arr, value: padId, at: [0, i]) }
            let count = min(ids.count, maxLen)
            let start = maxLen - count
            for i in 0..<count { set(arr: arr, value: ids[i], at: [0, start + i]) }
            return (MLFeatureValue(multiArray: arr), maxLen - 1)
        } else {
            let maxLen = shape.first?.intValue ?? ids.count
            for i in 0..<maxLen { set(arr: arr, value: padId, at: [i]) }
            let count = min(ids.count, maxLen)
            let start = maxLen - count
            for i in 0..<count { set(arr: arr, value: ids[i], at: [start + i]) }
            return (MLFeatureValue(multiArray: arr), maxLen - 1)
        }
    }

    private func onesMaskFeature(matching desc: MLFeatureDescription?, validLength: Int) throws -> MLFeatureValue? {
        guard let desc, desc.type == .multiArray else { return nil }
        let dataType = desc.multiArrayConstraint?.dataType ?? .int32
        let shape: [NSNumber]
        if let s = desc.multiArrayConstraint?.shape, !s.isEmpty {
            shape = s
        } else {
            shape = [NSNumber(value: 1), NSNumber(value: validLength)]
        }
        let arr = try MLMultiArray(shape: shape, dataType: dataType)
        let maxLen: Int
        if shape.count == 2 && shape[0].intValue == 1 {
            maxLen = shape[1].intValue
            let count = min(validLength, maxLen)
            for i in 0..<count { set(arr: arr, value: 1, at: [0, i]) }
        } else {
            maxLen = shape.first?.intValue ?? validLength
            let count = min(validLength, maxLen)
            for i in 0..<count { set(arr: arr, value: 1, at: [i]) }
        }
        return MLFeatureValue(multiArray: arr)
    }

    private func set(arr: MLMultiArray, value: Int, at index: [Int]) {
        let nsIndex = index.map { NSNumber(value: $0) }
        switch arr.dataType {
        case .int32:
            arr[nsIndex] = NSNumber(value: Int32(value))
        case .double:
            arr[nsIndex] = NSNumber(value: Double(value))
        case .float32:
            arr[nsIndex] = NSNumber(value: Float(value))
        default:
            arr[nsIndex] = NSNumber(value: value)
        }
    }

    private func chooseLogits(from provider: MLFeatureProvider) -> MLMultiArray? {
        // Prefer keys named like logits
        let candidates = ["logits", "decoder_logits", "output", "scores"]
        for key in candidates {
            if let ma = provider.featureValue(for: key)?.multiArrayValue { return ma }
        }
        // Fallback: any multiArray of floating type
        for name in provider.featureNames {
            if let ma = provider.featureValue(for: name)?.multiArrayValue, ma.dataType == .double || ma.dataType == .float32 { return ma }
        }
        // Last resort: any multiArray output
        for name in provider.featureNames {
            if let ma = provider.featureValue(for: name)?.multiArrayValue { return ma }
        }
        return nil
    }

    private func value(of ma: MLMultiArray, at indices: [Int]) -> Float {
        let ns = indices.map { NSNumber(value: $0) }
        let num = ma[ns]
        switch ma.dataType {
        case .double:
            return Float(truncating: num)
        case .float32:
            return Float(truncating: num)
        default:
            return Float(truncating: num)
        }
    }

    private func argmax(from logits: MLMultiArray, position: Int) -> Int {
        let shape = logits.shape.map { $0.intValue }
        if shape.count == 3 {
            // [batch, seq, vocab] assume batch=1
            let seq = min(max(position, 0), max(shape[1] - 1, 0))
            let vocab = shape[2]
            var best = 0
            var bestVal: Float = -Float.greatestFiniteMagnitude
            for i in 0..<vocab {
                let v = value(of: logits, at: [0, seq, i])
                if v > bestVal { bestVal = v; best = i }
            }
            return best
        } else if shape.count == 2 {
            // [seq, vocab]
            let seq = min(max(position, 0), max(shape[0] - 1, 0))
            let vocab = shape[1]
            var best = 0
            var bestVal: Float = -Float.greatestFiniteMagnitude
            for i in 0..<vocab {
                let v = value(of: logits, at: [seq, i])
                if v > bestVal { bestVal = v; best = i }
            }
            return best
        } else {
            // [vocab]
            let vocab = shape.first ?? logits.count
            var best = 0
            var bestVal: Float = -Float.greatestFiniteMagnitude
            for i in 0..<vocab {
                let v = value(of: logits, at: [i])
                if v > bestVal { bestVal = v; best = i }
            }
            return best
        }
    }
}
#endif

func sanitizeFilename(_ input: String) -> String {
    let lower = input.lowercased()
    let allowed = lower.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) || "-_ ".unicodeScalars.contains(scalar) {
            return Character(String(scalar))
        } else {
            return " "
        }
    }
    let interim = String(allowed)
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .components(separatedBy: CharacterSet.whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let hyphenated = interim.replacingOccurrences(of: " ", with: "-")
    return hyphenated.isEmpty ? "image" : hyphenated
}

enum FilenameLanguage: String, CaseIterable, Identifiable {
    case english = "English"
    case french = "French"
    case spanish = "Spanish"
    case german = "German"
    var id: String { rawValue }
}

enum AnalysisEngine: String, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case openAICompatible = "OpenAI API"
    case coreml = "Core ML"
    var id: String { rawValue }
}

enum TranslationMode: String, CaseIterable, Identifiable {
    case ai = "AI"
    case apple = "Apple"
    var id: String { rawValue }
}

private struct PreparedAnalysisImage: Sendable {
    let originalURL: URL
    let analysisURL: URL
    let temporaryURL: URL?
}

@MainActor
final class ImageRenamerViewModel: ObservableObject {
    // Only allow common image file extensions to be analyzed
    private let allowedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp"
    ]

    private func isSupportedImage(_ url: URL) -> Bool {
        Self.isSupportedImageURL(url, allowedExtensions: allowedImageExtensions)
    }

    private nonisolated static func isSupportedImageURL(_ url: URL, allowedExtensions: Set<String>) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    private nonisolated static func engineMarker(_ engine: AnalysisEngine) -> String {
        switch engine {
        case .ollama: return "__OLLAMA__"
        case .openAICompatible: return "__OPENAI__"
        case .coreml: return "__COREML__"
        }
    }

    private func engineMarker(_ engine: AnalysisEngine) -> String {
        Self.engineMarker(engine)
    }

    private func isAlreadyRenamed(_ url: URL, for engine: AnalysisEngine) -> Bool {
        Self.isAlreadyRenamed(url, for: engine, forceRename: forceRename)
    }

    private nonisolated static func isAlreadyRenamed(_ url: URL, for engine: AnalysisEngine, forceRename: Bool) -> Bool {
        if forceRename { return false }
        return url.deletingPathExtension().lastPathComponent.contains(engineMarker(engine))
    }

    private nonisolated static func prepareAnalysisImage(for url: URL) async throws -> PreparedAnalysisImage {
        try await Task.detached(priority: .userInitiated) {
            #if os(macOS)
            let ext = url.pathExtension.lowercased()
            guard ext == "heic" || ext == "heif" else {
                return PreparedAnalysisImage(originalURL: url, analysisURL: url, temporaryURL: nil)
            }

            guard let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
                throw NSError(domain: "ImageRenamer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare HEIC preview for \(url.lastPathComponent)"])
            }

            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent("ImageRenamer", isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jpg")
            try jpegData.write(to: tempURL, options: .atomic)

            // Preserve the original HEIC/HEIF. The temporary JPEG is only used for model analysis.
            return PreparedAnalysisImage(originalURL: url, analysisURL: tempURL, temporaryURL: tempURL)
            #else
            return PreparedAnalysisImage(originalURL: url, analysisURL: url, temporaryURL: nil)
            #endif
        }.value
    }

    private nonisolated static func readImageData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    private nonisolated static func cleanupTemporaryAnalysisFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // Selection processing configuration
    private let perRequestDelayNanoseconds: UInt64 = 300_000_000 // 300ms
    private(set) var allCandidateURLs: [URL] = [] // all eligible images discovered from the picker

    @Published var selectedURLs: [URL] = []
    @Published var results: [URL: String] = [:] // proposed base name (no extension)
    @Published var perFileErrors: [URL: String] = [:]
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var processedCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var autoRenameEnabled: Bool = true
    @Published var serverAddress: String = "http://127.0.0.1:11434"
    private var analysisTask: Task<Void, Never>? = nil
    private(set) var allResults: [URL: String] = [:]
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = "" {
        didSet {
            switch engine {
            case .ollama:
                ollamaSelectedModel = selectedModel
            case .openAICompatible:
                openAISelectedModel = selectedModel
            case .coreml:
                break
            }
        }
    }
    @Published var selectedLanguage: FilenameLanguage = .english
    @Published var translationMode: TranslationMode = .ai
    @Published var forceRename: Bool = false
    @Published var currentURLBeingProcessed: URL? = nil
    @Published var showDebugLog: Bool = false
    @Published var debugLog: String = ""

    @Published var engine: AnalysisEngine = .ollama {
        didSet {
            guard oldValue != engine else { return }
            synchronizeRemoteConfigurationForSelectedEngine()
        }
    }

    // Core ML local model selection
    #if canImport(CoreML)
    @Published var coreMLModelDisplayName: String = ""
    private var coreMLCompiledModelURL: URL?
    private var coreMLDescriber: CoreMLDescriber?
    var isCoreMLReady: Bool { coreMLCompiledModelURL != nil && coreMLDescriber != nil }

    private var translationService: TranslationService?

    private func resolveTranslationService() -> TranslationService? {
        if let service = translationService { return service }
        let fm = FileManager.default
        let enc = Bundle.main.url(forResource: "NLLB_Encoder_256", withExtension: "mlmodelc")
        let dec = Bundle.main.url(forResource: "NLLB_Decoder_256", withExtension: "mlmodelc")
        if let enc, let dec, fm.fileExists(atPath: enc.path), fm.fileExists(atPath: dec.path) {
            let service = TranslationService(encoderModelURL: enc, decoderModelURL: dec)
            translationService = service
            return service
        }

        if let base = Bundle.main.resourceURL {
            appendDebug("Translation models not found in bundle at \(base.path)")
        } else {
            appendDebug("Translation models not found: Bundle.main.resourceURL is nil")
        }
        return nil
    }
    #else
    @Published var coreMLModelDisplayName: String = ""
    var isCoreMLReady: Bool { false }
    #endif

    private let defaultOllamaModel = "llava:13b"
    private let defaultOpenAIModel = ""
    private var ollamaServerAddress: String = "http://127.0.0.1:11434"
    private var openAIServerAddress: String = "http://localhost:8887"
    private var ollamaSelectedModel: String = ""
    private var openAISelectedModel: String = ""
    var client: OllamaClient
    var openAIClient: OpenAICompatibleClient
    private var appleTranslator: ((String, FilenameLanguage) async throws -> String)?

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func appendDebug(_ message: String) {
        let stamp = ImageRenamerViewModel.debugDateFormatter.string(from: Date())
        debugLog.append("[\(stamp)] \(message)\n")
    }

    func setAppleTranslator(_ translator: ((String, FilenameLanguage) async throws -> String)?) {
        appleTranslator = translator
    }

    init(client: OllamaClient? = nil) {
        let savedOllamaAddress = UserDefaults.standard.string(forKey: "OllamaServerAddress") ?? "127.0.0.1"
        let ollamaFallbackURL = URL(string: "http://127.0.0.1:11434")!
        let normalizedOllamaURL = ImageRenamerViewModel.normalizeServerAddress(savedOllamaAddress, defaultPort: 11434)
        let ollamaURL = normalizedOllamaURL.flatMap { ImageRenamerViewModel.validateTransportPolicy(for: $0) == nil ? $0 : nil } ?? ollamaFallbackURL
        self.ollamaServerAddress = ollamaURL.absoluteString

        let savedOpenAIAddress = UserDefaults.standard.string(forKey: "OpenAICompatibleServerAddress") ?? "http://localhost:8887"
        let openAIFallbackURL = URL(string: "http://localhost:8887")!
        let normalizedOpenAIURL = ImageRenamerViewModel.normalizeServerAddress(savedOpenAIAddress, defaultPort: 8887)
        let openAIURL = normalizedOpenAIURL.flatMap { ImageRenamerViewModel.validateTransportPolicy(for: $0) == nil ? $0 : nil } ?? openAIFallbackURL
        self.openAIServerAddress = openAIURL.absoluteString

        if let client {
            self.client = client
            self.ollamaServerAddress = client.baseURL.absoluteString
        } else {
            self.client = OllamaClient(baseURL: ollamaURL, model: defaultOllamaModel)
        }
        self.openAIClient = OpenAICompatibleClient(baseURL: openAIURL, model: defaultOpenAIModel)
        self.ollamaSelectedModel = self.client.model
        self.serverAddress = self.ollamaServerAddress
        self.selectedModel = self.client.model
        self.availableModels = [self.client.model]
    }

    private static func normalizeServerAddress(_ input: String, defaultPort: Int) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.isEmpty { return nil }
        if !string.contains("://") {
            string = "http://" + string
        }
        guard var comps = URLComponents(string: string) else { return nil }
        if comps.scheme == nil { comps.scheme = "http" }
        if comps.port == nil { comps.port = defaultPort }
        return comps.url
    }

    private nonisolated static func validateTransportPolicy(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else {
            return "Server address must include http or https."
        }
        guard scheme == "http" || scheme == "https" else {
            return "Server address must use http or https."
        }
        if scheme == "https" { return nil }
        guard let host = url.host(percentEncoded: false), isPlainHTTPAllowedHost(host) else {
            return "HTTPS is required for WAN servers. Plain HTTP is allowed only for localhost, LAN, or Tailscale addresses."
        }
        return nil
    }

    private nonisolated static func isPlainHTTPAllowedHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".ts.net") {
            return true
        }
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let first = parts[0]
        let second = parts[1]
        return first == 10 ||
            first == 127 ||
            (first == 172 && (16...31).contains(second)) ||
            (first == 192 && second == 168) ||
            (first == 169 && second == 254) ||
            (first == 100 && (64...127).contains(second))
    }

    private func synchronizeRemoteConfigurationForSelectedEngine() {
        switch engine {
        case .ollama:
            serverAddress = ollamaServerAddress
            selectedModel = ollamaSelectedModel.isEmpty ? client.model : ollamaSelectedModel
            availableModels = selectedModel.isEmpty ? [client.model] : [selectedModel]
        case .openAICompatible:
            serverAddress = openAIServerAddress
            selectedModel = openAISelectedModel
            availableModels = selectedModel.isEmpty ? [] : [selectedModel]
        case .coreml:
            availableModels = []
        }
        errorMessage = nil
    }

    /// Apply the current `serverAddress` by recreating the client and refreshing models.
    func applyServerAddress() async {
        let defaultPort: Int
        let invalidMessage: String
        switch engine {
        case .ollama:
            defaultPort = 11434
            invalidMessage = "Invalid server address. Enter an IP or URL like 192.168.1.10 or https://example.com:11434."
        case .openAICompatible:
            defaultPort = 8887
            invalidMessage = "Invalid server address. Enter an IP or URL like 192.168.1.10 or https://example.com:8887."
        case .coreml:
            self.errorMessage = "Server address applies only to network engines."
            return
        }
        guard let url = ImageRenamerViewModel.normalizeServerAddress(serverAddress, defaultPort: defaultPort) else {
            self.errorMessage = invalidMessage
            return
        }
        if let policyError = ImageRenamerViewModel.validateTransportPolicy(for: url) {
            self.errorMessage = policyError
            return
        }
        self.serverAddress = url.absoluteString
        self.errorMessage = nil
        switch engine {
        case .ollama:
            self.ollamaServerAddress = url.absoluteString
            UserDefaults.standard.set(self.serverAddress, forKey: "OllamaServerAddress")
            let model = self.selectedModel.isEmpty ? defaultOllamaModel : self.selectedModel
            self.client = OllamaClient(baseURL: url, model: model)
        case .openAICompatible:
            self.openAIServerAddress = url.absoluteString
            UserDefaults.standard.set(self.serverAddress, forKey: "OpenAICompatibleServerAddress")
            let model = self.selectedModel.isEmpty ? defaultOpenAIModel : self.selectedModel
            self.openAIClient = OpenAICompatibleClient(baseURL: url, model: model)
        case .coreml:
            break
        }
        await refreshModels()
    }

    /// Starts the analysis in a cancellable Task so the UI can stop it.
    func startAnalysis(prompt: String = "Provide a descriptive filename for this image without file extension in less than 10 words, separated with a dash.") {
        guard !isProcessing else { return }
        debugLog = ""
        analysisTask = Task { [weak self] in
            await self?.analyzeSelected(prompt: prompt)
        }
    }

    /// Cancels an in-flight analysis run.
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    func pickImages() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType.image]
        if panel.runModal() == .OK {
            let urls = panel.urls
            let engine = self.engine
            let forceRename = self.forceRename
            let allowedImageExtensions = self.allowedImageExtensions
            Task { [weak self] in
                guard let self else { return }
                let candidates = await Self.discoverCandidateImages(
                    from: urls,
                    engine: engine,
                    forceRename: forceRename,
                    allowedExtensions: allowedImageExtensions
                )
                self.allCandidateURLs = candidates
                self.selectedURLs = candidates
                self.results.removeAll()
                self.perFileErrors.removeAll()
                self.processedCount = 0
                self.totalCount = self.selectedURLs.count
                self.errorMessage = candidates.isEmpty ? "No supported images found." : nil
            }
        }
        #else
        self.errorMessage = "Image picking is only implemented for macOS in this sample."
        #endif
    }

    private nonisolated static func discoverCandidateImages(
        from urls: [URL],
        engine: AnalysisEngine,
        forceRename: Bool,
        allowedExtensions: Set<String>
    ) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            var picked: [URL] = []
            let fm = FileManager.default
            for url in urls {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        while let file = enumerator.nextObject() as? URL {
                            if Self.isSupportedImageURL(file, allowedExtensions: allowedExtensions),
                               !Self.isAlreadyRenamed(file, for: engine, forceRename: forceRename) {
                                picked.append(file)
                            }
                        }
                    }
                } else if Self.isSupportedImageURL(url, allowedExtensions: allowedExtensions),
                          !Self.isAlreadyRenamed(url, for: engine, forceRename: forceRename) {
                    picked.append(url)
                }
            }
            return picked
        }.value
    }

    func refreshModels() async {
        guard engine != .coreml else {
            self.availableModels = []
            return
        }
        do {
            let models: [String]
            switch engine {
            case .ollama:
                models = try await client.listModels()
            case .openAICompatible:
                models = try await openAIClient.listModels()
            case .coreml:
                models = []
            }
            self.availableModels = models.sorted()
            if !self.availableModels.contains(self.selectedModel), let first = self.availableModels.first {
                self.selectedModel = first
            }
            if self.availableModels.isEmpty {
                self.selectedModel = ""
            }
            self.errorMessage = nil
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    #if os(macOS)
    func pickCoreMLModel() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "Choose Model"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try prepareCoreMLModel(from: url)
                self.errorMessage = nil
            } catch {
                self.errorMessage = "Failed to load Core ML model: \(error.localizedDescription)"
            }
        }
        #endif
    }

    private func prepareCoreMLModel(from url: URL) throws {
        #if canImport(CoreML)
        var compiledURL: URL
        if url.pathExtension.lowercased() == "mlmodel" {
            compiledURL = try MLModel.compileModel(at: url)
        } else {
            compiledURL = url
        }
        self.coreMLCompiledModelURL = compiledURL
        self.coreMLModelDisplayName = compiledURL.deletingPathExtension().lastPathComponent
        self.coreMLDescriber = try CoreMLDescriber(compiledModelURL: compiledURL)
        #else
        throw NSError(domain: "ImageRenamer", code: -100, userInfo: [NSLocalizedDescriptionKey: "Core ML is not available on this platform."])
        #endif
    }

    private nonisolated static func describeImage(with describer: CoreMLDescriber, imageURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try describer.describe(imageURL: imageURL)
        }.value
    }
    #endif

    private func maybeTranslate(_ text: String) async -> String {
        if selectedLanguage == .english { return text }
        switch translationMode {
        case .ai:
            #if canImport(CoreML)
            guard var service = resolveTranslationService() else {
                appendDebug("Translation skipped: no translation service")
                return text
            }
            service.logger = { [weak self] message in
                self?.appendDebug(message)
            }
            do {
                appendDebug("Translation start language=\(selectedLanguage.rawValue)")
                try service.load()
                let out = try service.translate(text, to: selectedLanguage)
                self.translationService = service // persist loaded tokenizer/models
                appendDebug("Translation result=\(String(out.prefix(80)))")
                return out
            } catch {
                self.errorMessage = "Translation failed: \(error.localizedDescription)"
                appendDebug("Translation failed error=\(error.localizedDescription)")
                return text
            }
            #else
            return text
            #endif
        case .apple:
            guard let appleTranslator else {
                appendDebug("Apple translation skipped: no session")
                return text
            }
            do {
                appendDebug("Apple translation start language=\(selectedLanguage.rawValue)")
                let out = try await appleTranslator(text, selectedLanguage)
                appendDebug("Apple translation result=\(String(out.prefix(80)))")
                return out
            } catch {
                self.errorMessage = "Apple translation failed: \(error.localizedDescription)"
                appendDebug("Apple translation failed error=\(error.localizedDescription)")
                return text
            }
        }
    }

    func analyzeSelected(prompt: String = "Provide a descriptive filename for this image without file extension in less than 10 words separated with a dash.") async {
        let selectedForRun = selectedURLs
        guard !selectedForRun.isEmpty else { return }

        // Process every selected candidate. Large selections are surfaced in the UI, but are not capped.
        let (supported, unsupported) = selectedForRun.partitioned { isSupportedImage($0) && !isAlreadyRenamed($0, for: self.engine) }
        processedCount = 0
        totalCount = supported.count
        isProcessing = true
        errorMessage = nil
        results.removeAll()
        perFileErrors.removeAll()
        for url in unsupported {
            perFileErrors[url] = "Unsupported file type or already renamed: .\(url.pathExtension.lowercased())"
        }
        guard !supported.isEmpty else {
            isProcessing = false
            analysisTask = nil
            return
        }
        if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }

        switch engine {
        case .ollama:
            // Verify Ollama server is reachable before sending large payloads
            do {
                try await client.healthCheck()
                if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                self.isProcessing = false
                return
            }

            for url in supported {
                if isAlreadyRenamed(url, for: self.engine) { self.processedCount += 1; continue }
                if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
                var currentURL = url
                do {
                    let prepared = try await Self.prepareAnalysisImage(for: url)
                    defer { Self.cleanupTemporaryAnalysisFile(prepared.temporaryURL) }
                    currentURL = prepared.originalURL
                    if isAlreadyRenamed(currentURL, for: self.engine) { self.processedCount += 1; continue }

                    // Update UI to show the current image being processed
                    self.currentURLBeingProcessed = currentURL

                    let data = try await Self.readImageData(from: prepared.analysisURL)
                    let promptWithLanguage = prompt + " Respond in \(self.selectedLanguage.rawValue)."

                    func requestOnce() async throws -> String {
                        return try await client.describeImage(data: data, prompt: promptWithLanguage, model: selectedModel)
                    }

                    var raw: String
                    do {
                        raw = try await requestOnce()
                    } catch {
                        if case OllamaClientError.httpStatus(let code, _) = error, code == 500 {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            raw = try await requestOnce()
                        } else { throw error }
                    }

                    var output = raw
                    // If the prompt asked for a non-English language, many models may still reply in English. Attempt translation.
                    output = await maybeTranslate(output)
                    let trimmed = String(output.prefix(120))
                    let sanitized = sanitizeFilename(trimmed)
                    let finalBase = String(sanitized.prefix(60))

                    if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }

                    if autoRenameEnabled {
                        let (newURL, markedBase) = try await Self.renameFile(originalURL: currentURL, base: finalBase, engine: self.engine)
                        // Update the current processing URL to the renamed file
                        self.currentURLBeingProcessed = newURL
                        if let idxAll = self.allCandidateURLs.firstIndex(of: currentURL) { self.allCandidateURLs[idxAll] = newURL }
                        if let idxSel = self.selectedURLs.firstIndex(of: currentURL) { self.selectedURLs[idxSel] = newURL }
                        if self.selectedURLs.contains(newURL) {
                            self.results.removeValue(forKey: currentURL)
                            self.results[newURL] = markedBase
                        }
                        self.allResults.removeValue(forKey: currentURL)
                        self.allResults[newURL] = markedBase
                    } else {
                        self.allResults[currentURL] = finalBase
                        if self.selectedURLs.contains(currentURL) { self.results[currentURL] = finalBase }
                    }
                    self.processedCount += 1
                    try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
                } catch {
                    if error is CancellationError || Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    self.perFileErrors[currentURL] = message
                    self.errorMessage = message
                    self.processedCount += 1
                    try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
                    continue
                }
            }
        case .openAICompatible:
            do {
                try await openAIClient.healthCheck()
                if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                self.isProcessing = false
                return
            }

            for url in supported {
                if isAlreadyRenamed(url, for: self.engine) { self.processedCount += 1; continue }
                if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
                var currentURL = url
                do {
                    let prepared = try await Self.prepareAnalysisImage(for: url)
                    defer { Self.cleanupTemporaryAnalysisFile(prepared.temporaryURL) }
                    currentURL = prepared.originalURL
                    if isAlreadyRenamed(currentURL, for: self.engine) { self.processedCount += 1; continue }

                    self.currentURLBeingProcessed = currentURL

                    let data = try await Self.readImageData(from: prepared.analysisURL)
                    let promptWithLanguage = prompt + " Respond in \(self.selectedLanguage.rawValue)."
                    let raw = try await openAIClient.describeImage(data: data, imageURL: prepared.analysisURL, prompt: promptWithLanguage, model: selectedModel)

                    var output = raw
                    output = await maybeTranslate(output)
                    let trimmed = String(output.prefix(120))
                    let sanitized = sanitizeFilename(trimmed)
                    let finalBase = String(sanitized.prefix(60))

                    if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }

                    if autoRenameEnabled {
                        let (newURL, markedBase) = try await Self.renameFile(originalURL: currentURL, base: finalBase, engine: self.engine)
                        self.currentURLBeingProcessed = newURL
                        if let idxAll = self.allCandidateURLs.firstIndex(of: currentURL) { self.allCandidateURLs[idxAll] = newURL }
                        if let idxSel = self.selectedURLs.firstIndex(of: currentURL) { self.selectedURLs[idxSel] = newURL }
                        if self.selectedURLs.contains(newURL) {
                            self.results.removeValue(forKey: currentURL)
                            self.results[newURL] = markedBase
                        }
                        self.allResults.removeValue(forKey: currentURL)
                        self.allResults[newURL] = markedBase
                    } else {
                        self.allResults[currentURL] = finalBase
                        if self.selectedURLs.contains(currentURL) { self.results[currentURL] = finalBase }
                    }
                    self.processedCount += 1
                    try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
                } catch {
                    if error is CancellationError || Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    self.perFileErrors[currentURL] = message
                    self.errorMessage = message
                    self.processedCount += 1
                    try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
                    continue
                }
            }
        case .coreml:
            #if canImport(CoreML)
            guard let describer = self.coreMLDescriber else {
                self.errorMessage = "Please choose a Core ML model first."
                self.isProcessing = false
                return
            }
            for url in supported {
                if isAlreadyRenamed(url, for: self.engine) { self.processedCount += 1; continue }
                if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
                var currentURL = url
                do {
                    let prepared = try await Self.prepareAnalysisImage(for: url)
                    defer { Self.cleanupTemporaryAnalysisFile(prepared.temporaryURL) }
                    currentURL = prepared.originalURL
                    if isAlreadyRenamed(currentURL, for: self.engine) { self.processedCount += 1; continue }

                    // Update UI to show the current image being processed
                    self.currentURLBeingProcessed = currentURL

                    // Use Core ML to describe the image off the main actor.
                    let raw = try await Self.describeImage(with: describer, imageURL: prepared.analysisURL)
                    let output = await maybeTranslate(raw)
                    let trimmed = String(output.prefix(120))
                    let sanitized = sanitizeFilename(trimmed)
                    let finalBase = String(sanitized.prefix(60))

                    if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }

                    if autoRenameEnabled {
                        let (newURL, markedBase) = try await Self.renameFile(originalURL: currentURL, base: finalBase, engine: self.engine)
                        // Update the current processing URL to the renamed file
                        self.currentURLBeingProcessed = newURL
                        if let idxAll = self.allCandidateURLs.firstIndex(of: currentURL) { self.allCandidateURLs[idxAll] = newURL }
                        if let idxSel = self.selectedURLs.firstIndex(of: currentURL) { self.selectedURLs[idxSel] = newURL }
                        if self.selectedURLs.contains(newURL) {
                            self.results.removeValue(forKey: currentURL)
                            self.results[newURL] = markedBase
                        }
                        self.allResults.removeValue(forKey: currentURL)
                        self.allResults[newURL] = markedBase
                    } else {
                        self.allResults[currentURL] = finalBase
                        if self.selectedURLs.contains(currentURL) { self.results[currentURL] = finalBase }
                    }
                    self.processedCount += 1
                    try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
                } catch {
                    if error is CancellationError || Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    self.perFileErrors[currentURL] = message
                    self.errorMessage = message
                    self.processedCount += 1
                    try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
                    continue
                }
            }
            #else
            self.errorMessage = "Core ML is not available on this platform."
            #endif
        }

        self.currentURLBeingProcessed = nil
        isProcessing = false
        analysisTask = nil
    }

    private nonisolated static func renameFile(originalURL: URL, base: String, engine: AnalysisEngine) async throws -> (URL, String) {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let ext = originalURL.pathExtension.isEmpty ? "" : "." + originalURL.pathExtension.lowercased()
            let marker = engineMarker(engine)
            let markedBase = base.contains(marker) ? base : "\(base)\(marker)"
            let dir = originalURL.deletingLastPathComponent()
            var candidate = dir.appendingPathComponent(markedBase + ext)

            var suffix = 1
            while fm.fileExists(atPath: candidate.path) {
                candidate = dir.appendingPathComponent("\(markedBase)-\(suffix)" + ext)
                suffix += 1
            }

            try fm.moveItem(at: originalURL, to: candidate)
            return (candidate, markedBase)
        }.value
    }

    func renameFiles() {
        guard !results.isEmpty else { return }
        let pending = results
        let engine = self.engine
        Task { [weak self] in
            guard let self else { return }
            var updated: [URL: String] = [:]
            for (url, base) in pending {
                do {
                    let (candidate, markedBase) = try await Self.renameFile(originalURL: url, base: base, engine: engine)
                    updated[candidate] = markedBase
                    self.allResults.removeValue(forKey: url)
                    self.allResults[candidate] = markedBase
                } catch {
                    let marker = Self.engineMarker(engine)
                    let markedBase = base.contains(marker) ? base : "\(base)\(marker)"
                    self.errorMessage = "Failed to rename \(url.lastPathComponent): \(error.localizedDescription)"
                    updated[url] = markedBase
                    self.allResults[url] = markedBase
                }
            }

            self.selectedURLs = Array(updated.keys)
            self.results = updated

        }
    }
}

#if os(macOS)
extension ImageRenamerViewModel {
    /// Prompts the user to authorize access to a folder (external or network) and stores a security-scoped bookmark.
    func authorizeFolderAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Authorize"
        panel.message = "Choose a folder (external or network) to grant the app access."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: "AuthorizedFolderBookmark")
                UserDefaults.standard.synchronize()
                self.errorMessage = nil
            } catch {
                self.errorMessage = "Failed to save folder authorization: \(error.localizedDescription)"
            }
        }
    }

    /// Resolves the previously stored security-scoped bookmark for the authorized folder.
    func resolveAuthorizedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "AuthorizedFolderBookmark") else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                // Re-save a fresh bookmark if needed
                let fresh = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(fresh, forKey: "AuthorizedFolderBookmark")
            }
            return url
        } catch {
            self.errorMessage = "Failed to resolve folder authorization: \(error.localizedDescription)"
            return nil
        }
    }

    /// Executes a closure with security-scoped access to the authorized folder, if available.
    @discardableResult
    func withAuthorizedFolderAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolveAuthorizedFolder() else {
            self.errorMessage = "No authorized folder. Please authorize access first."
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            self.errorMessage = "Could not start security-scoped access for the authorized folder."
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
}
#endif

private extension Array {
    func partitioned(by belongsInFirstPartition: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        first.reserveCapacity(count)
        second.reserveCapacity(count)
        for element in self {
            if belongsInFirstPartition(element) {
                first.append(element)
            } else {
                second.append(element)
            }
        }
        return (first, second)
    }
}

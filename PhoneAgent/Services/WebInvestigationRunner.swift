import Foundation

@MainActor struct WebInvestigationRunner {
    let settings: WebSearchSettings
    let searchKey: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = WebSearchClient.load
    func run(question: String, maxRounds: Int, authorized: () -> Bool,
             decide: (WebResearchContext) async throws -> WebResearchDecision,
             summarize: (WebSearchBatch) async throws -> WebSearchAnswer,
             progress: (WebInvestigationState) -> Void) async throws -> WebInvestigationState {
        let question = try WebSearchBatch.validatedQuery(question)
        guard (1...3).contains(maxRounds) else { throw AgentError.message("Research is limited to 1–3 rounds") }
        // Check search credentials before spending model quota.
        _ = try WebSearchClient(settings: settings, apiKey: searchKey, transport: transport).request(query: question)
        var state = WebInvestigationState(question: question, maxRounds: maxRounds, startedAt: Date())
        var results: [WebSearchBatch] = []; var attempted: [String] = []; var stop = ""
        func check() throws { try Task.checkCancellation(); guard authorized() else { throw CancellationError() } }
        do {
            try check()
            for number in 1...maxRounds {
                try check(); state.phase = .planning; progress(state); try check()
                let context = WebResearchContext(question: question, freshness: settings.freshness, round: number, maxRounds: maxRounds, attempted: attempted, evidence: state.evidence)
                try context.validate()
                state.modelRequests += 1
                let decision = try await decide(context); try check(); try decision.validate(attempted: attempted)
                state.rounds.append(.init(number: number, decision: decision, completedQueries: 0))
                state.evidence = try WebSearchBatch.accumulated(question: question, settings: settings, rounds: state.rounds, results: results, startedAt: state.startedAt)
                progress(state); try check()
                if decision.finish { stop = "The model suggested no further searches: " + decision.note; break }
                // Validate the whole proposed round before its first search.
                let clients = try decision.queries.map { item -> WebSearchClient in
                    let client = WebSearchClient(settings: .init(provider: settings.provider, freshness: item.freshness), apiKey: searchKey, transport: transport)
                    _ = try client.request(query: item.query); return client
                }
                for (index, client) in clients.enumerated() {
                    try check(); state.phase = .searching; progress(state); try check()
                    state.searches += 1
                    let result = try await client.search(query: decision.queries[index].query); try check()
                    results.append(result); attempted.append(decision.queries[index].query)
                    state.rounds[state.rounds.count - 1].completedQueries += 1
                    state.evidence = try WebSearchBatch.accumulated(question: question, settings: settings, rounds: state.rounds, results: results, startedAt: state.startedAt)
                    progress(state); try check()
                    if (state.evidence?.sources.count ?? 0) >= 20 {
                        stop = "Reached the 20-source cumulative limit; remaining searches were not run. Unfinished items and missing evidence still need review"
                        break
                    }
                }
                if !stop.isEmpty { break }
            }
            if stop.isEmpty { stop = "Reached this run's \(maxRounds)-round research limit; no more searches were added. Missing evidence still needs review" }
            state.message = stop
            state.evidence = try WebSearchBatch.accumulated(question: question, settings: settings, rounds: state.rounds, results: results, startedAt: state.startedAt, stop: stop)
            if let evidence = state.evidence, !evidence.sources.isEmpty {
                try check(); state.phase = .answering; progress(state); try check()
                state.modelRequests += 1
                let answer = try await summarize(evidence); try check()
                let encoded = try JSONEncoder().encode(answer)
                state.answer = try WebSearchAnswer.decode(String(decoding: encoded, as: UTF8.self), batch: evidence)
            } else { state.message += ". No usable sources, so the model was not asked for a factual answer" }
            try check(); state.phase = .finished; progress(state); return state
        } catch is CancellationError {
            state.phase = .cancelled; state.message = "Stopped sending requests. Returned sources were kept; data already sent can't be recalled"; progress(state); throw CancellationError()
        } catch {
            state.phase = .failed; state.message = error.localizedDescription + ". Returned sources were kept; no automatic retry or continuation"; progress(state); throw error
        }
    }
}

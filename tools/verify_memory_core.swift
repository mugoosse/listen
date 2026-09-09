import Foundation

@main struct VerifyMemoryCore {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("listen-memory-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try ContextDatabase(root: root)
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { fatalError(name) }; checks += 1; print("PASS \(name)")
        }
        var rapid = ContextOverride(id: "rapid", updated: "")
        rapid.replacement = "Correction"; rapid.mark(["replacement"], at: "2026-09-08T10:00:00Z")
        var rapidReset = rapid; rapidReset.replacement = nil; rapidReset.mark(["replacement"], at: "2026-09-08T10:00:00Z")
        try check(ContextSync.merge([rapid.id: rapid], [rapidReset.id: rapidReset])[rapid.id]?.replacement == nil, "reset in the same second supersedes its correction")
        try check(ContextOverride.timestamp("2026-09-08T10:00:00.001Z") > ContextOverride.timestamp("2026-09-08T10:00:00Z"), "fractional and legacy timestamps compare as instants")
        let alex = try db.transaction { try ContextLedger.entity("Alex Rivera", kind: "person", db: db) }
        try ContextLedger.alias("Alex R.", entity: alex.id, db: db)
        try check(try ContextLedger.entity("alex r.", kind: "person", db: db).id == alex.id, "reviewed alias resolves stable identity")
        try ContextLedger.alias("Alex Rivero", entity: alex.id, rename: true, db: db)
        try check(try ContextLedger.entity("Alex Rivera", kind: "person", db: db).id == alex.id, "rename preserves former name")
        let other = try db.transaction { try ContextLedger.entity("Alex Roy", kind: "person", db: db) }
        do { try ContextLedger.alias("Alex R.", entity: other.id, db: db); fatalError("ambiguous alias accepted") }
        catch { checks += 1 }
        do {
            try db.transaction { try db.put("lost", in: .metadata, id: "rollback"); throw ContextDatabase.Failure(message: "test") }
        } catch {}
        try check(try db.get(String.self, in: .metadata, id: "rollback") == nil, "failed transaction leaves no partial changes")
        try check(ContextTime.validDay("2026-02-12") && !ContextTime.validDay("2026-02-30"), "calendar dates validated")
        try check(ContextTime.statedDays("February 12, 2026") == ["2026-02-12"] && ContextTime.statedDays("12 de fevereiro de 2026") == ["2026-02-12"] && ContextTime.statedDays("12 februari 2026") == ["2026-02-12"], "fully stated English Portuguese and Dutch dates normalize with evidence")
        try check(ContextTime.statedDays("next Friday, February 12 or 03/04/2026").isEmpty, "ambiguous dates and unstated years are not guessed")
        do { try ContextTime(from: "2026-02-12", wording: "next Friday", precision: "day").validate(quote: "next Friday"); fatalError("invented date accepted") }
        catch { checks += 1 }
        func observation(_ id: String, source: String, recorded: String, quote: String,
                         direct: Bool = true, modality: String = "asserted", date: String? = nil) -> ContextObservation {
            ContextObservation(id: id, subject: alex.id, predicate: "role", value: quote, object: nil, objectKind: nil,
                polarity: "positive", modality: modality, attribution: direct ? "direct" : "reported",
                time: ContextTime(wording: date), evidence: ContextProvenance(source: source, revision: "v1", passage: 1,
                    quote: quote, quoteStart: 0, recordedAt: recorded, learnedAt: "2026-04-01", speaker: alex.id,
                    start: 0, end: 30, sourceGroups: [source], provider: "test", requestedModel: "test",
                    resolvedModel: nil, extractorVersion: 2))
        }
        let old = observation("january", source: "rec:jan", recorded: "2026-01-10", quote: "I lead Atlas.")
        let change = observation("handover", source: "rec:mar", recorded: "2026-03-03",
                                 quote: "I handed Atlas to Priya on 2026-02-12.", date: "2026-02-12")
        let rumor = observation("rumor", source: "rec:apr", recorded: "2026-04-02",
                                quote: "I think Alex leads Atlas on 2026-04-02.", direct: false, modality: "uncertain", date: "2026-04-02")
        for obs in [old, change, rumor] { try db.put(obs, in: .observations, id: obs.id) }
        let event = ContextTransition(operation: "supersedes", prior: old.id, next: change.id, supports: [change.id],
            effectiveDate: "2026-02-12", quote: change.evidence.quote, actor: "test", committedAt: "2026-04-01")
        try ContextLedger.apply([event], db: db)
        try check(try db.all(ContextTransition.self, in: .transitions).count == 1, "handover retains explicit effective time")
        let invalid = ContextTransition(operation: "supersedes", prior: change.id, next: rumor.id, supports: [rumor.id],
            effectiveDate: "2026-04-02", quote: rumor.evidence.quote, actor: "test", committedAt: "2026-04-02")
        do { try ContextLedger.apply([invalid], db: db); fatalError("reported reversal accepted") } catch { checks += 1 }
        let conflict = ContextTransition(operation: "contradicts", prior: old.id, next: rumor.id, supports: [old.id, rumor.id], actor: "test", committedAt: "2026-04-02")
        try ContextLedger.apply([conflict], db: db)
        try check(try db.all(ContextTransition.self, in: .transitions).count == 2, "conflicting report retained without choosing winner")
        var cessation = change; cessation.id = "cessation"; cessation.polarity = "negative"
        cessation.evidence.quote = "I stopped leading Atlas on 2026-02-12."
        try db.put(cessation, in: .observations, id: cessation.id)
        let retract = ContextTransition(operation: "retracts", prior: old.id, next: cessation.id, supports: [cessation.id], effectiveDate: "2026-02-12", quote: cessation.evidence.quote, actor: "test", committedAt: "2026-04-02")
        try ContextLedger.apply([retract], db: db)
        try check(try db.get(ContextTransition.self, in: .transitions, id: retract.id) != nil, "direct dated negative assertion can end a prior state")
        var decision = change; decision.id = "decision"; decision.predicate = "decision"
        try db.put(decision, in: .observations, id: decision.id)
        let handover = ContextTransition(operation: "supersedes", prior: old.id, next: decision.id, supports: [decision.id], effectiveDate: "2026-02-12", quote: decision.evidence.quote, actor: "test", committedAt: "2026-04-02")
        try ContextLedger.apply([handover], db: db)
        try check(try db.get(ContextTransition.self, in: .transitions, id: handover.id) != nil, "dated handover decision can end the prior role")
        do { try ContextTime(wording: "next Friday").validate(quote: "We have no date."); fatalError("invented unresolved wording accepted") } catch { checks += 1 }
        let wrongMerge = ContextTransition(operation: "paraphrase", prior: old.id, next: rumor.id, supports: [old.id, rumor.id], actor: "test", committedAt: "2026-04-02")
        do { try ContextLedger.apply([wrongMerge], db: db); fatalError("attribution lost") } catch { checks += 1 }
        let hidden = ContextOverride(id: old.id, hidden: true, replacement: "User correction", updated: "2026-04-02")
        try db.put(hidden, in: .overrides, id: hidden.id)
        try db.transaction { try ContextLedger.prune(currentRevisions: ["rec:jan": "v1", "rec:apr": "v1"], db: db) }
        try check(try db.get(ContextObservation.self, in: .observations, id: change.id) == nil, "deleted transition source removes observation text")
        let revoked = try db.get(ContextTransition.self, in: .transitions, id: event.id)
        try check(revoked?.revoked == true && revoked?.quote == nil, "revoked transition retains no deleted quotation")
        try check(try db.get(ContextOverride.self, in: .overrides, id: hidden.id)?.replacement == "User correction", "source deletion preserves user correction")
        let job = ContextJob(id: "job", source: "rec:jan#0", revision: "v1", stage: "extract", priority: 1)
        let now = Date()
        let first = try ContextLedger.claim(job, db: db, now: now)!
        let otherDB = try ContextDatabase(root: root)
        try check(try ContextLedger.claim(job, db: otherDB, now: now) == nil, "second connection cannot claim active job")
        let recovered = try ContextLedger.claim(job, db: otherDB, now: now.addingTimeInterval(601))!
        try check(first.lease != recovered.lease, "expired lease is recoverable after crash")
        do { try db.transaction { try ContextLedger.finish(first, failure: nil, db: db) }; fatalError("stale lease committed") } catch { checks += 1 }
        try otherDB.transaction { try ContextLedger.finish(recovered, failure: nil, db: otherDB) }
        try check(try ContextLedger.claim(job, db: db, now: now.addingTimeInterval(800)) == nil, "completed revision is idempotent")
        try db.transaction { try db.index(id: "passage", text: "Atlas is recruiting software engineers", namespace: "test:2", vector: [0.6, 0.8]) }
        try check(try db.lexical(["engineers"]) == ["passage"], "FTS retrieves words")
        try check(try db.lexical(["\" OR 1=1 --"]).isEmpty, "FTS treats query as data")
        try check(try db.rows("SELECT length(value) FROM vectors").first?.first == Data("8".utf8), "vectors stored as typed Float32 bytes")
        try check(try db.rows("PRAGMA integrity_check").first?.first == Data("ok".utf8), "SQLite integrity")
        let quote = "Alex works on Atlas and Borealis."
        let atlas = ContextLedger.claimID(subject: alex.id, predicate: "works_on", kind: "project", quote: quote, object: "atlas")
        let borealis = ContextLedger.claimID(subject: alex.id, predicate: "works_on", kind: "project", quote: quote, object: "borealis")
        try check(atlas != borealis, "two projects in one quote retain separate identities")
        let leased = try ContextLedger.claim(ContextJob(id: "budget", source: "x", revision: "1", stage: "extract", priority: 1), db: db)!
        try ContextLedger.release(leased, db: db)
        try check(try db.get(ContextJob.self, in: .jobs, id: leased.id)?.attempts == 0, "budget pause does not count as extraction failure")
        let phantom = observation("removed-in-repair", source: "rec:jan", recorded: "2026-01-10", quote: "Old rejected detail")
        try db.put(phantom, in: .observations, id: phantom.id)
        try db.transaction { try ContextLedger.prune(currentRevisions: ["rec:jan": "v1", "rec:apr": "v1"], activeIDs: [old.id, rumor.id], db: db) }
        try check(try db.get(ContextObservation.self, in: .observations, id: phantom.id) == nil, "same-revision re-extraction removes discarded observations")

        var correction = ContextOverride(id: "claim", updated: "")
        correction.replacement = "Alex advises Atlas."; correction.mark(["replacement"], at: "2026-04-01T10:00:00Z")
        var pin = ContextOverride(id: "claim", updated: "")
        pin.pinned = true; pin.mark(["pinned"], at: "2026-04-01T11:00:00Z")
        let merged = ContextSync.merge(["claim": correction], ["claim": pin])["claim"]!
        try check(merged.pinned && merged.replacement == correction.replacement, "concurrent pin and correction merge by field")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try check(try encoder.encode(ContextSync.merge(["claim": correction], ["claim": pin])) == encoder.encode(ContextSync.merge(["claim": pin], ["claim": correction])), "correction merge is commutative")
        try ContextSync.edit(correction, root: root); try ContextSync.edit(pin, root: root)
        try check(try ContextSync.edits(root: root)["claim"]?.replacement == correction.replacement, "file writes preserve a concurrent correction")
        var restored = merged; restored.replacement = nil; restored.mark(["replacement"], at: "2026-04-02T10:00:00Z")
        let reset = ContextSync.merge(["claim": merged], ["claim": restored])["claim"]!
        try check(reset.replacement == nil && reset.pinned, "restoring source wording preserves pin")

        let sourceURL = root.appendingPathComponent("source.txt"), changeURL = root.appendingPathComponent("change.txt")
        try Data("Original statement".utf8).write(to: sourceURL)
        try Data("Explicit handover".utf8).write(to: changeURL)
        let evidence = ContextCard.Evidence(source: "rec:jan", title: "January call", recordedAt: "2026-01-10T10:00:00Z",
            quote: "Alex leads the Atlas project.", speaker: "Alex", start: 4, revision: "v1", sourceGroups: ["rec:jan"], learnedAt: "2026-04-01")
        let entry = ContextCard.Entry(id: "claim", subject: alex.id, subjectName: "Alex", predicate: "role", text: "Alex leads Atlas.",
            object: "atlas", objectKind: "project", status: "historical", time: ContextTime(from: "2026-01-01", to: "2026-02-12"),
            evidence: [evidence], corrected: false, pinned: false, attribution: "direct", modality: "asserted", polarity: "positive",
            endingSupports: [["rec:mar"]], canonicalClaimIDs: ["claim", "paraphrase"], originalText: "Alex leads Atlas.",
            changeEvidence: [ContextCard.Evidence(source: "rec:mar", title: "March call", recordedAt: "2026-03-03T10:00:00Z",
                quote: "I handed Atlas to Priya on February 12, 2026.", speaker: "Alex", start: 8, revision: "v2")])
        var card = ContextCard(id: alex.id, kind: "person", name: "Alex", aliases: ["Alex R."],
            brief: [ContextCard.Sentence(text: "Alex used to lead Atlas.", claims: ["claim"])], entries: [entry], updated: "2026-04-01", pending: 0, failed: 0)
        var snapshot = ContextSnapshot(cards: [card], proofs: ["rec:jan": ["source.txt": sha256Hex(try Data(contentsOf: sourceURL))],
            "rec:mar": ["change.txt": sha256Hex(try Data(contentsOf: changeURL))]], overrides: [:], generatedAt: "2026-04-01")
        try check(snapshot.merging(local: [], reviewedSources: [], root: root).first?.entries.count == 1, "unprocessed second Mac retains the valid owner projection")
        try check(snapshot.merging(local: [], reviewedSources: ["rec:jan"], root: root).isEmpty, "completed empty extraction can remove a prior owner projection")
        var partial = card; partial.entries = []; partial.brief = []; partial.pending = 2
        try check(snapshot.merging(local: [partial], reviewedSources: [], root: root).first?.entries.count == 1, "partial local card cannot overwrite another Mac's sourced details")
        try check(try ContextBuilder.build(card).entries.isEmpty, "current context excludes supported ended roles")
        let january = try ContextBuilder.build(card, asOf: "2026-01-20")
        try check(january.entries.count == 1 && january.entries[0].status == "recorded", "historical query retrieves the role during its supported interval")
        try check(january.entries.first?.changeEvidence?.first?.source == "rec:mar", "budgeted history includes the original source of its temporal transition")
        try check(ContextPresentation.category("works_at", polarity: "negative") == "Does not work at"
            && ContextPresentation.qualifiers(modality: "uncertain", attribution: "reported") == ["Unconfirmed", "Reported"],
            "relationship labels preserve negation, uncertainty and reported attribution")
        try check(try ContextBuilder.build(card, asOf: "2025-12-31").entries.isEmpty, "historical query excludes claims before effective start")
        try check(try ContextBuilder.build(card, asOf: "2026-02-12").entries.isEmpty, "effective end is exclusive")
        do { _ = try ContextBuilder.build(card, asOf: "2026-02-30"); fatalError("invalid date filter accepted") } catch { checks += 1 }
        var unknown = entry; unknown.id = "unknown"; unknown.time = ContextTime(wording: "next Friday"); unknown.status = "recorded"
        card.entries.append(unknown)
        try check(try ContextBuilder.build(card, asOf: "2025-01-01").entries.first?.time?.from == nil, "unresolved relative wording remains unknown under historical retrieval")
        for budget in [256, 500, 1500, 16000] {
            let packet = try ContextBuilder.build(card, tokenBudget: budget)
            try check(try encoder.encode(packet).count <= budget * 3, "encoded context respects budget \(budget)")
        }
        var hiring = entry; hiring.id = "hiring"; hiring.status = "recorded"; hiring.time = nil
        hiring.predicate = "project"; hiring.text = "Hiring a software developer for the launch."
        hiring.object = nil; hiring.objectKind = nil; hiring.changeEvidence = nil
        hiring.canonicalClaimIDs = [hiring.id]; hiring.originalText = hiring.text; hiring.endingSupports = nil
        var searchable = card; searchable.entries = [hiring]; searchable.brief = []
        var projectCard = searchable; projectCard.id = "launch"; projectCard.kind = "project"
        projectCard.name = "Launch"; projectCard.aliases = ["Summer rollout"]
        let broad = try ContextSearch.search("Who is hiring?", cards: [searchable, projectCard], semantic: false)
        try check(broad.matches.count == 1 && broad.matches[0].entry.subjectName == "Alex", "generic memory query finds a person without a name or transcript search and deduplicates project copies")
        var communication = searchable; communication.id = "communication"; communication.entries[0].id = "preference"
        communication.entries[0].text = "Prefers short written follow-ups."
        var cat = searchable; cat.id = "cat"; cat.entries[0].id = "cat-detail"; cat.entries[0].text = "The cat sleeps on the sofa."
        let paraphrase = try ContextSearch.search("preferred way of communicating", cards: [searchable, communication, cat])
        if paraphrase.mode == "hybrid" {
            try check(paraphrase.matches.first?.id == "preference" && paraphrase.matches.first?.match == "semantic", "local sentence embeddings retrieve a communication preference without shared keywords")
            try check(!paraphrase.matches.contains { $0.id == "cat-detail" }, "unrelated memory is excluded from semantic preference results")
        } else { print("SKIP Apple sentence model unavailable on this test device") }
        try check(try ContextSearch.search("Summer rollout", cards: [projectCard], semantic: false).matches.first?.entity == "launch", "memory search resolves reviewed project aliases")
        try check(try ContextSearch.search("Atlas", cards: [snapshot.verified(snapshot.cards[0], root: root)], semantic: false).matches.isEmpty, "current memory search excludes ended claims")
        let past = try ContextSearch.search("Atlas", cards: [snapshot.verified(snapshot.cards[0], root: root)], asOf: "2026-01-20", semantic: false)
        try check(past.matches.first?.entry.changeEvidence?.first?.source == "rec:mar", "historical memory search preserves the change source")
        try check(try ContextSearch.search("Atlas", cards: [snapshot.verified(snapshot.cards[0], root: root)], asOf: "2026-02-12", semantic: false).matches.isEmpty, "memory search uses the same exclusive effective end")
        var negative = searchable; negative.entries[0].predicate = "works_on"; negative.entries[0].polarity = "negative"
        negative.entries[0].modality = "uncertain"; negative.entries[0].attribution = "reported"
        let negativeHit = try ContextSearch.search("hiring", cards: [negative], semantic: false).matches[0]
        try check(negativeHit.entry.polarity == "negative" && ContextSearch.text(negativeHit.entry).contains("Does not work on") && ContextSearch.text(negativeHit.entry).contains("Unconfirmed"), "search preserves negative and uncertain assertion meaning")
        var correctedSearch = searchable; correctedSearch.entries[0].text = "Designing the brand identity."
        correctedSearch.entries[0].corrected = true; correctedSearch.entries[0].originalText = hiring.text
        try check(try ContextSearch.search("hiring", cards: [correctedSearch], semantic: false).matches.isEmpty, "old evidence wording cannot match a corrected current memory")
        try check(try ContextSearch.search("brand", cards: [correctedSearch], semantic: false).matches.first?.entry.corrected == true, "corrected memory is searchable before reindexing")
        for budget in [256, 500, 1500] {
            let result = try ContextSearch.search("hiring", cards: [searchable], tokenBudget: budget, semantic: false)
            try check(try encoder.encode(result).count <= budget * 3, "search packet respects budget \(budget)")
        }
        var portable = snapshot; portable.cards = [searchable]
        try encoder.encode(portable).write(to: root.appendingPathComponent(ContextSnapshot.filename))
        try check(try ContextSearch.search("hiring", cards: ContextSync.readCards(root: root), semantic: false).matches.count == 1, "second device searches a verified synced card without a local ledger or index")
        var hideSearch = ContextOverride(id: hiring.id, updated: ""); hideSearch.hidden = true
        hideSearch.mark(["hidden"], at: "2026-09-08T10:00:00Z"); try ContextSync.edit(hideSearch, root: root)
        try check(try ContextSearch.search("hiring", cards: ContextSync.readCards(root: root), semantic: false).matches.isEmpty, "synced hide is applied before searching")
        hideSearch.hidden = false; hideSearch.mark(["hidden"], at: "2026-09-08T10:00:01Z"); try ContextSync.edit(hideSearch, root: root)
        try FileManager.default.removeItem(at: changeURL)
        let unsupported = snapshot.verified(snapshot.cards[0], root: root)
        try check(unsupported.entries.first?.status == "needs_review" && unsupported.entries.first?.time?.to == nil,
            "deleted handover evidence does not silently restore a current role")
        try check(unsupported.brief.isEmpty, "deleted transition invalidates summary even when the original claim survives")
        try check(unsupported.entries.first?.changeEvidence?.isEmpty == true, "deleted transition quotation is removed from the shared reading surface")
        var equivalent = correction; equivalent.id = "paraphrase"
        snapshot.overrides = ["paraphrase": equivalent]
        try check(snapshot.verified(snapshot.cards[0], root: root).entries.first?.text == correction.replacement, "correction applies across reviewed paraphrase identities")
        var correctedCard = snapshot.cards[0]; correctedCard.entries[0].text = correction.replacement!; correctedCard.entries[0].corrected = true
        snapshot.overrides = ["claim": reset]
        try check(snapshot.verified(correctedCard, root: root).entries.first?.text == "Alex leads Atlas.", "source wording restores from a previously corrected synced card")
        snapshot.overrides = ["claim": reset, "paraphrase": equivalent]
        try check(snapshot.verified(correctedCard, root: root).entries.first?.corrected == false, "newer reset wins over an older correction on a reviewed paraphrase")
        var contested = snapshot.cards[0]; contested.entries[0].status = "conflicted"
        contested.entries[0].endingSupports = nil; contested.entries[0].conflictSupports = [["rec:mar"]]
        try check(snapshot.verified(contested, root: root).entries.first?.status == "needs_review", "deleted contradiction evidence invalidates the phone's conflict status")
        do { _ = try ContextSnapshot.decode(Data("invalid".utf8)); fatalError("invalid snapshot accepted") } catch { checks += 1 }
        do { try ContextSync.validate(["wrong-id": reset]); fatalError("mismatched correction identity accepted") } catch { checks += 1 }
        try FileManager.default.removeItem(at: sourceURL)
        try check(snapshot.verified(snapshot.cards[0], root: root).entries.isEmpty, "deleted primary source removes phone context immediately")
        try check(try ContextSync.edits(root: root)["claim"]?.replacement != nil, "phone source deletion never destroys the user's correction")
        try check(try ContextSearch.search("hiring", cards: ContextSync.readCards(root: root), semantic: false).matches.isEmpty, "deleted primary source disappears from cross-device search")
        let preferencesRoot = root.appendingPathComponent("preferences")
        let peerRoot = root.appendingPathComponent("peer-preferences")
        let personID = MemoryPreferences.personID("Alice", root: preferencesRoot)
        try check(try !MemoryPreferences.policy(personID, root: preferencesRoot).automatic, "missing per-person consent is manual")
        let firstModel = MemoryPreferences.Model(provider: "claude", model: "sonnet", name: "Sonnet · Claude Code", executor: "mac-one")
        let secondModel = MemoryPreferences.Model(provider: "codex", model: "gpt", name: "GPT · Codex", executor: "mac-two")
        try MemoryPreferences.advertise(firstModel, root: preferencesRoot)
        try MemoryPreferences.select(["rec:one"], known: ["rec:one", "rec:two"], person: personID, root: preferencesRoot)
        try check(try !MemoryPreferences.policy(personID, root: preferencesRoot).automatic, "choosing sources does not enable background generation")
        try MemoryPreferences.automatic(true, person: personID, root: preferencesRoot)
        try MemoryPreferences.advertise(secondModel, root: preferencesRoot)
        let policy = try MemoryPreferences.policy(personID, root: preferencesRoot)
        try check(policy.model == firstModel, "another Mac cannot change an existing person's automatic model")
        try check(policy.includes("rec:one") && !policy.includes("rec:two") && policy.includes("note:new"), "automatic updates include new sources but remember a deselected source")
        let request = try MemoryPreferences.request(person: personID, name: "Alice", sources: ["rec:one"], model: firstModel, root: preferencesRoot)
        let original = try Data(contentsOf: preferencesRoot.appendingPathComponent(MemoryPreferences.filename))
        _ = try MemoryPreferences.receive(original, root: peerRoot)
        try MemoryPreferences.cancel(request.id, root: peerRoot)
        try MemoryPreferences.finish(request, state: "complete", root: preferencesRoot)
        _ = try MemoryPreferences.receive(Data(contentsOf: peerRoot.appendingPathComponent(MemoryPreferences.filename)), root: preferencesRoot)
        try check(try MemoryPreferences.requests(root: preferencesRoot).first?.state == "cancelled", "phone cancellation wins over a late Mac completion")
        let next = try MemoryPreferences.request(person: personID, name: "Alice", sources: ["rec:two"], model: secondModel, root: preferencesRoot)
        let replacement = try MemoryPreferences.request(person: personID, name: "Alice", sources: ["rec:one"], model: firstModel, root: preferencesRoot)
        try check(try MemoryPreferences.requests(root: preferencesRoot).first { $0.id == next.id }?.state == "cancelled", "a new explicit request cancels an obsolete queued request")
        try MemoryPreferences.deleteMemory(person: personID, root: preferencesRoot)
        let deletedPolicy = try MemoryPreferences.policy(personID, root: preferencesRoot)
        try check(!deletedPolicy.automatic && !deletedPolicy.deletedBefore.isEmpty, "deleting generated memory records a durable cutoff and turns updates off")
        try check(try MemoryPreferences.requests(root: preferencesRoot).first { $0.id == replacement.id }?.state == "cancelled", "deleting memory cancels queued generation")
        try MemoryPreferences.associate("Alicia", id: personID, root: preferencesRoot)
        try check(MemoryPreferences.personID("Alicia", root: preferencesRoot) == personID, "a rename keeps the stable note identity")
        let mergedID = MemoryPreferences.personID("Alex", root: preferencesRoot)
        try MemoryPreferences.redirect(personID, to: mergedID, root: preferencesRoot)
        try check(MemoryPreferences.canonicalID(personID, root: preferencesRoot) == mergedID && MemoryPreferences.personID("Alicia", root: preferencesRoot) == mergedID, "an explicit merge redirects existing notes and aliases")
        let noteURL = preferencesRoot.appendingPathComponent("notes/private-note.md")
        try FileManager.default.createDirectory(at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nexclude_from_ai: \"true\"\n---\nOwner words".write(to: noteURL, atomically: true, encoding: .utf8)
        try check(!MemoryPreferences.sourceAllowed("note:private-note", root: preferencesRoot), "a quoted exclusion removes note access")
        try check(MemoryPreferences.excludedNotes(root: preferencesRoot) == ["private-note"], "exclusion changes can invalidate active AI history")
        try "---\nexclude_from_ai: false\n---\nOwner words".write(to: noteURL, atomically: true, encoding: .utf8)
        try check(MemoryPreferences.sourceAllowed("note:private-note", root: preferencesRoot), "an explicit allow restores note access")
        try check(!MemoryPreferences.sourceAllowed("note:../escape", root: preferencesRoot), "invalid note IDs cannot escape the note directory")
        try check(MemoryPreferences.merge(["x": .init(text: "a", updated: "2026-01-01T00:00:00Z")], ["x": .init(text: "b", updated: "2026-01-01T00:00:00Z")])["x"]?.text == "b", "equal-clock settings merges converge deterministically")
        try check(MemoryPreferences.merge(["person:a:automatic": .init(text: "true", updated: "2026-01-01T00:00:00Z")], ["person:a:automatic": .init(text: "false", updated: "2026-01-01T00:00:00Z")])["person:a:automatic"]?.text == "false", "turning off wins a simultaneous automatic-consent conflict")
        print("\(checks) memory core checks passed")
    }
}

import Foundation

/// APIKeyStore with a fake Keychain: no real Keychain is touched.
@main
struct APIKeyStoreTests {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { fputs("APIKeyStoreTests FAILED: \(message)\n", stderr); exit(1) }
    }

    final class FakeKeychain {
        var items: [String: String] = [:]
        var reads = 0
        var refuseSave = false
        var keychain: APIKeyStore.Keychain {
            APIKeyStore.Keychain(read: { self.reads += 1; return self.items[$0] },
                                 save: { if self.refuseSave { return false }; self.items[$1] = $0; return true },
                                 delete: { self.items[$0] = nil })
        }
    }

    static func load(_ store: APIKeyStore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task { @MainActor in store.load { done.resume() } }
        }
    }

    static func main() async {
        let fake = FakeKeychain()
        fake.items[KeychainSecret.openAI] = "sk-keychain"
        let store = APIKeyStore(environment: ["ELEVENLABS_API_KEY": "el-env"], keychain: fake.keychain)
        check(store.key(.openAI) == nil && !store.loaded && fake.reads == 0, "no Keychain read before the launch load")
        await load(store)
        check(store.loaded, "loaded after completion")
        check(await MainActor.run { store.key(.openAI) } == "sk-keychain", "Keychain key")
        check(await MainActor.run { store.key(.elevenLabs) } == "el-env", "environment wins")
        check(store.hasCachedKey(.openAI) && store.hasCachedKey(.elevenLabs), "both cached")
        check(store.inEnvironment(.elevenLabs) && !store.inEnvironment(.openAI), "environment flags")
        let readsAfterLoad = fake.reads
        _ = store.key(.openAI); _ = store.key(.openAI)
        check(fake.reads == readsAfterLoad, "cached keys are not read again")

        check(store.save("sk-new", for: .openAI) && store.key(.openAI) == "sk-new" && fake.items[KeychainSecret.openAI] == "sk-new", "save")
        fake.refuseSave = true
        check(!store.save("sk-other", for: .openAI) && store.key(.openAI) == "sk-new", "refused save keeps the old key")
        fake.refuseSave = false

        store.delete(.openAI)
        check(fake.items[KeychainSecret.openAI] == nil && store.key(.openAI) == nil && !store.hasCachedKey(.openAI), "delete")

        let empty = APIKeyStore(environment: [:], keychain: FakeKeychain().keychain)
        await load(empty)
        check(empty.key(.openAI) == nil && empty.key(.elevenLabs) == nil, "missing keys are nil")

        // A key saved while the launch read was in flight wins over the read.
        let racing = FakeKeychain()
        racing.items[KeychainSecret.elevenLabs] = "el-old"
        let early = APIKeyStore(environment: [:], keychain: racing.keychain)
        _ = early.save("el-typed", for: .elevenLabs)
        await load(early)
        check(early.key(.elevenLabs) == "el-typed", "saved key wins over the launch read")
        print("APIKeyStoreTests: \(count) checks passed")
    }
}

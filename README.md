# FieldCopilot — offline-first field service with on-device AI

A Couchbase Mobile demo: an HVAC technician opens a work order, asks an AI
assistant a question in plain language, and gets an answer grounded in that
unit's service manuals — **with the network off**. The model *and* the vector
database both run on the phone.

| | |
|---|---|
| **`FieldCopilot/`** | iPhone/iPad app (SwiftUI). On-device RAG over synced manuals + shared field notes, hybrid vector/FTS search, and an agentic work-order assistant with tool calling, a context-window meter and smart suggested prompts. |
| **`FieldDispatcher/`** | macOS companion. A dispatcher creates work orders; they sync through Capella to the technician's phone. |

### What runs where

**On the device — no network required:**
- **Couchbase Lite** — embedded database *and* retrieval engine: a vector
  index over manual-chunk embeddings, full-text search for exact hits (fault
  codes, part numbers), and both rankings fused with reciprocal rank fusion.
- **Qwen3-Embedding-0.6B** on Apple **Core AI** — every embedding, query and
  document.
- **Apple Foundation model** — message routing, streamed answers with tool
  calls, and small guided calls: detecting when a technician reports a *new*
  fix worth sharing, summarizing long chats, and writing follow-up suggestions.
- **Qwen3.5-4B via MLX** (optional) — a heavier local model (text-only build,
  pinned revision), downloaded on demand with a real progress bar.

**In the cloud — optional:**
- **Capella App Services** — bidirectional sync of work orders and field notes.
- **OpenAI** — a cloud-comparison backend, off unless you supply a key.

### What the agent does

- **Tool calling: refrigerant calculator.** For superheat, subcooling or
  saturation questions the model calls a tool instead of doing the math. The
  tool uses real pressure-temperature tables (R-410A, R-22, R-32, R-134a,
  generated with CoolProp), compares the result with the target range the
  model copied from the manual, and returns the verdict and what it means
  ("3.2°F, 4.8°F below the 8-12°F target: the evaporator is overfed"). Small
  models get this wrong on their own: without the tool, the on-device model
  answered 15°F, and with the number but no verdict it called 3.2°F "within
  8-12°F". Works on all three backends; each call shows as a card in the chat.
- **New knowledge, shared.** When a tech reports a fix the manuals don't
  cover, the app writes a field note, embeds it, and syncs it, so it surfaces
  for the next tech who hits the same fault.
- **Context-window meter.** A ring in the message field shows how full the
  model's window will be for the next question (exact token counts on the
  Foundation model and Qwen). Tap it for a breakdown and **Compact
  conversation**: older turns become a structured summary (readings,
  what the assistant suggested, what the tech did), shown as a card in the
  chat. Auto-compacts at 85%. Windows: Foundation 8,192 tokens, Qwen3.5
  262,144 (its maximum), OpenAI 400,000.
- **Smart suggested prompts.** Chips are built from the work order: the next
  unticked checklist step, the reported fault code, the required part, the
  unit's service history, a teammate's synced field note, and a close-out
  summary once the fix is reported. Model-written follow-ups fill spare
  slots. Every chip that depends on the manuals is search-checked first and
  dropped if nothing in the manuals or notes is close enough to answer it;
  at most one chip per category is shown. Demo work orders still show their
  scripted prompt first.

---

## Requirements

- macOS with **Xcode 26.6+** (the app targets iOS 27; Core AI is iOS 27-only)
- An iPhone that supports **Apple Intelligence** (the Foundation model backend)
- A **Couchbase Capella** account (free tier is fine) — only needed for sync
- ~4 GB free disk for the SDKs and the embedding model, plus ~2.4 GB on the
  phone if you enable the optional Qwen3.5 model

---

## Setup

### 1. Clone and add your credentials

```bash
git clone https://github.com/BurningFenix/couchbase-technician.git
cd couchbase-technician
cp .env.example .env      # then edit .env with your values
./scripts/setup.sh
```

`.env` is **gitignored**. `scripts/setup.sh` reads it and generates the two
files each app actually consumes — re-run it any time you change `.env`:

- `FieldCopilot/FieldCopilot/Secrets.xcconfig` (iOS, read at build time)
- `FieldDispatcher/capella-config.json` (macOS, read at runtime)

> The script handles one non-obvious detail for you: `.xcconfig` treats `//`
> as a comment, so a raw `wss://…` URL gets truncated to `wss:` and sync fails
> with a confusing "Can't assign requested address". It splits the slashes
> with an empty `$()` substitution.

### 2. Set up Capella App Services

Per-technician isolation (Kyle and BJ each see only their own work orders):
**[`capella-per-user-access.md`](capella-per-user-access.md)**.

Full walkthrough: **[`capella-app-services-setup.md`](capella-app-services-setup.md)**
and **[`FieldDispatcher/README.md`](FieldDispatcher/README.md)**. The short version:

1. Create an Operational cluster and a bucket named **`fieldcopilot`**.
2. In that bucket create a scope named **`field`** with **all six** collections:
   `assets`, `manualChunks`, `serviceHistory`, `parts`, `workOrders`, `fieldNotes`.
   The app replicates all six — if one is missing, sync errors out.
3. Create an App Service + App Endpoint named **`fieldcopilot-endpoint`**,
   mapped to that scope.
4. Give every collection this access control function (single channel, demo-grade):
   ```javascript
   function (doc, oldDoc, meta) {
     channel("demo");
   }
   ```
5. Create an App User (e.g. `tech1`) and set its **admin channels to `*`** for
   every collection.

   > **The #1 gotcha.** Pushing only needs *write* access, so a device can
   > upload documents with no channel grant — and then pull **nothing**. If the
   > app connects but never receives anything, this is why.
6. Enable public connectivity (allow all IPs for a demo), copy the connection
   string into `.env`, and re-run `./scripts/setup.sh`.

Sanity-check your endpoint without launching anything:

```bash
curl -sk -u "$SYNC_USERNAME:$SYNC_PASSWORD" \
  "https://YOUR-ID.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint/"
```

`200` means endpoint, user, password and channels are all good. `401` means bad
credentials or missing channel access.

### 3. Add the Couchbase Lite Enterprise SDKs

Not committed — they're ~300 MB and their dSYMs exceed GitHub's file limits.
Download from [Couchbase downloads](https://www.couchbase.com/downloads/?family=couchbase-lite)
(Couchbase Lite **Swift, Enterprise**, plus the **Vector Search** extension) and
unzip so the folders sit here:

```
FieldCopilot/couchbase-lite-swift_xc_enterprise_4/CouchbaseLiteSwift.xcframework
FieldCopilot/couchbase-lite-vector-search_xcframework_2/CouchbaseLiteVectorSearch.xcframework
```

Both are already referenced by the Xcode project — matching those paths is all
that's needed.

### 4. Add the embedding model

Also not committed (1.1 GB, over GitHub's 100 MB limit). You need a Core AI
export of **Qwen3-Embedding-0.6B** at:

```
FieldCopilot/Qwen3Embedding/qwen3-embedding-0.6b_float16_s512_static.aimodel
FieldCopilot/Qwen3Embedding/Qwen3Tokenizer/          (tokenizer.json, tokenizer_config.json, chat_template.jinja)
```

Export it with Core AI's tooling from
[`Qwen/Qwen3-Embedding-0.6B`](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B),
float16, static sequence length 512.

> **Note on the project's file type for this model.** It's deliberately
> referenced as an opaque `folder` rather than `folder.aimodel`, which skips
> Xcode's `MLAssetCompile` (AOT) step. That step requires the Metal Toolchain,
> which is broken in some Xcode 27 betas. The app falls back to compiling the
> model on-device at first launch and caching it — so **the first launch is
> slower**, then normal. If your toolchain is healthy and you want AOT back,
> flip that one line in `project.pbxproj` to `lastKnownFileType = folder.aimodel`.

### 5. Build and run

**iPhone** — open `FieldCopilot/FieldCopilot.xcodeproj`, set your signing team,
and run on a device. First launch seeds the database and embeds ~234 manual
chunks (progress is shown). On first build, Xcode will ask you to
**"Trust & Enable"** the MLX build plugin and macro. The app needs a real
device: Core AI (the embedding model) isn't available in the Simulator.

**Optional — Qwen3.5 4B:** Settings → AI model → Qwen3.5 4B downloads ~2.4 GB
once (progress shown in Settings and in the Ask header), then runs offline.

**macOS dispatcher:**

```bash
cd FieldDispatcher
swift run
```

### 6. Try the demo

> **Presenting?** Use the scripted story in **[`DEMO.md`](DEMO.md)**: WO-4821, an E11
> call where the agent uses its refrigerant-calculator tool, saves a new fix, and the
> next tech receives it.

Before a demo, run **Settings → Reset demo to defaults** (work orders only
seed into an empty database, so this loads the current demo data).

1. **Work** tab → **WO-4821** → **Ask AI about this issue**. Tap the first
   suggested prompt each time: E11 explained from the manual, then superheat
   and subcooling worked out by the calculator tool (tool cards show the
   numbers and the verdict).
2. Report the fix ("the EEV stepper harness had chafed…") — the app
   recognizes it as new knowledge, embeds it, and saves it to the synced
   field-notes collection. Then **Complete work**.
3. **Settings** → switch technician (Kyle ↔ BJ) → Ask. A chip offers Kyle's
   fix, and his note surfaces as a tip in the answer.
4. Tap the **context ring** to see the token breakdown and compact the chat.
5. Open any answer's **Sources** sheet and toggle **Hybrid / FTS / Vector** to
   see why hybrid retrieval wins.
6. On the Mac, **Generate sample** → **Create & sync** → it appears on the phone.

Turn on Airplane Mode and repeat steps 1–5. Everything still works.

---

## Getting this running with Claude Code

Paste this into Claude Code from the cloned repo root:

```
Get this project running on my machine. It's a Couchbase Mobile demo with two
apps: an iOS app (FieldCopilot/, Xcode project) and a macOS companion
(FieldDispatcher/, Swift package). Read the README first, then help me through
setup in this order, checking each step actually worked before moving on:

1. Verify prerequisites: Xcode version, that xcode-select points at an Xcode
   with an iOS 27 SDK, and that a physical iPhone is connected
   (xcrun devicectl list devices). Tell me what's missing rather than
   guessing around it.

2. Credentials: copy .env.example to .env, ask me for my Capella endpoint URL,
   username, password, and optional OpenAI key, write them into .env, then run
   ./scripts/setup.sh and confirm the generated Secrets.xcconfig has the
   wss:/$()/ form (not a truncated "wss:").

3. Check whether the two Couchbase Lite xcframeworks and the Qwen3Embedding
   .aimodel exist at the paths the README lists. They are NOT in git. If any
   are missing, stop and tell me exactly what to download and where to put it.

4. Verify my Capella endpoint before building — curl the endpoint with my
   credentials and confirm HTTP 200, and confirm the App User can actually
   READ (a _changes request should return documents, not just _user/...).
   A 200 on the endpoint but no documents means missing channel access.

5. Build the iOS app for my device and install it. Pipe xcodebuild output to a
   file and grep for "error:" and "BUILD SUCCEEDED" rather than streaming the
   whole log.

6. Build and run the macOS dispatcher with swift run, and confirm its sync
   status reaches "Connected".

Standing rules while you work: never print or commit my .env, Secrets.xcconfig,
or capella-config.json contents. Before coding against any SDK API, check the
installed .swiftinterface for the real signature instead of assuming. If a
build fails, read the actual error before changing anything.
```

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Sync error: *"Can't assign requested address"* (POSIX 49) | The endpoint URL got truncated to `wss:` by xcconfig's `//` comment rule. Re-run `./scripts/setup.sh`. |
| Connects fine but never receives documents | The App User lacks **read** channel access. Set admin channels to `*` on every collection, then stop/start sync. |
| A device's own documents reach Capella, but a new one won't push | A document id reused after a delete conflicts with the remote tombstone. Use fresh ids. |
| *"Core AI requires the Metal Toolchain"* | Xcode-beta toolchain issue. The committed project already routes around it (see step 4). |
| First launch is slow | Expected — the embedding model compiles on-device once, then caches. |
| Xcode stops on the MLX plugin/macro | Click **Trust & Enable**. |
| WO-4821 still says "E11 high-pressure fault" | The device seeded before the demo data changed. **Settings → Reset demo to defaults**. |
| *"Qwen unavailable — using Foundation model…"* | Qwen hit an error (still loading, or a failed load) and the Foundation model answered instead. Check the Xcode console for the `[AIService] Qwen failed` line. |
| App killed after a few Qwen turns (`CriticalMemoryPressure` in the log) | Fixed: the app now caps and clears MLX's GPU buffer cache. If it returns, check nothing else raised `Memory.cacheLimit`. |
| Xcode shows `'weak' ownership of capture 'self'…` warnings | Stale issues from an older build. **Product → Clean Build Folder**, then build. |

# FieldCopilot demo guide (about 7 minutes)

**The story:** a rooftop chiller is down. The AI agent works through the diagnosis with the tech. It reads the manual, runs real calculations instead of guessing, and keeps the fix the tech finds so the next tech gets it. All of it runs on the phone, offline.

## Before you start
- **Settings → Reset demo to defaults**. This loads the scripted work order and clears old field notes.
- **Settings → AI model → Foundation**. This is the most reliable option, and Qwen3.5 / OpenAI work too. Signed in as **Kyle**.
- Optional: turn on **Airplane Mode** now and say so. Nothing below needs a network.

## The flow
Work tab → **WO-4821 · E11 low-superheat alarm** → **Ask AI about this issue**. Each time, tap the **first** suggested prompt (the scripted one). The chips beside it are live suggestions built from the job: its checklist, fault code, unit history and teammates' notes.

| # | Tap | What to point out |
|---|---|---|
| 1 | *"…latching E11 and the suction line is frosting…"* | **Search over the manual, on the phone.** It cites §9.2, p.90: E11 = low superheat, a risk of liquid reaching the compressor. Open **Sources** and toggle Hybrid / FTS / Vector. |
| 2 | *"Suction is reading 118 psig… 43°F…"* | **Tool call.** The model hands the math *and* the comparison to a calculator tool → **Superheat 3.2°F · 4.8°F below the 8–12°F target**: the evaporator is overfed, so liquid can reach the compressor. |
| 3 | *"…head is 365 psig… liquid line 98°F… subcooling?"* | **Second tool call** → **Subcooling 11.9°F · within the 10–14°F target**. The charge is correct, so this isn't a charge problem. |
| 4 | *"Found it — the EEV stepper harness had chafed…"* | **Saves new knowledge.** This fix isn't in the manual. The agent writes a **field note**, stores it in Couchbase Lite, and syncs it. |
| 5 | **Complete work** | The work order closes and syncs to the dispatcher. |
| 6 | Settings → switch to **BJ** → Ask tab → *"What fix did Kyle find for E11…"* (or *"The AC-5000 is latching E11 again…"*) | **The team's knowledge reaches the next tech.** The first chip appears only because Kyle's note synced. His fix shows up as a tip card in BJ's answer. |

**Punchline for beat 2:** ask a model with no tools the same superheat question and it confidently answers **15°F**. Even when it gets 3.2°F right, it has said "within 8–12°F, no action needed". With the tool, both the number and the verdict come from code. The model decides *when* to calculate; your code does the calculation.

**Context ring (optional, after beat 3):** tap the small ring in the message field. It shows how full the model's 8,192-token window is and what's using it. Tap **Compact conversation**: earlier turns collapse into a summary card, and the next answer still remembers the readings.

**Smart chips (optional, after beat 4):** the row is now a mix. A **Summarise … for the completion notes** chip appears once the fix is reported, plus a ✨ follow-up written by the model from the last answer. Every chip that depends on the manuals is search-checked first, so none of them leads to a dead end.

**Extras if there's time:** turn Airplane Mode off and show the field note arriving in Capella. Or create a work order in the Mac **FieldDispatcher** and watch it appear on the phone.

## If something goes off-script
- **No tool card on beat 2 or 3:** the agent only offers the calculator when the message has a pressure in psig. Re-tap the suggested prompt rather than retyping it.
- **Beat 4 doesn't save a note:** that check runs a few seconds after the answer appears, so wait for the "saved your fix" line. If it still misses, run Reset and rerun the flow.
- **Qwen3.5 selected:** the first time it's enabled, it downloads about 2.4 GB with a progress bar. Do that before the meeting, not live.

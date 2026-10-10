# FieldCopilot demo guide (about 7 minutes)

**The story:** a rooftop chiller is down. The AI agent works through the diagnosis with the tech. It reads the manual, runs real calculations instead of guessing, and keeps the fix the tech finds so the next tech gets it. All of it runs on the phone, offline.

## Before you start
- **Settings → Reset demo to defaults**. This loads the scripted work order and clears old field notes.
- **Settings → AI model → Foundation**. This is the most reliable option, and Qwen3.5 / OpenAI work too. Signed in as **Kyle**.
- Optional: turn on **Airplane Mode** now and say so. Nothing below needs a network.

## The flow
Work tab → **WO-4821 · E11 low-superheat alarm** → **Ask AI about this issue**. Tap each suggested prompt in order.

| # | Tap | What to point out |
|---|---|---|
| 1 | *"…latching E11 and the suction line is frosting…"* | **Search over the manual, on the phone.** It cites §9.2, p.90: E11 = low superheat, a risk of liquid reaching the compressor. Open **Sources** and toggle Hybrid / FTS / Vector. |
| 2 | *"Suction is reading 118 psig… 43°F…"* | **Tool call.** The model does the refrigerant math with a calculator tool instead of guessing → **Superheat 3.2°F**. Below E11's 4°F trip point, so the alarm is real. |
| 3 | *"…head is 365 psig… liquid line 98°F… subcooling?"* | **Second tool call** → **Subcooling 11.9°F**, inside the 10–14°F target. The charge is fine, so the agent points to the expansion valve. |
| 4 | *"Found it — the EEV stepper harness had chafed…"* | **Saves new knowledge.** This fix isn't in the manual. The agent writes a **field note**, stores it in Couchbase Lite, and syncs it. |
| 5 | **Complete work** | The work order closes and syncs to the dispatcher. |
| 6 | Settings → switch to **BJ** → Ask tab → *"The AC-5000 is latching E11 again…"* | **The team's knowledge reaches the next tech.** Kyle's fix shows up as a tip card in BJ's answer. |

**Punchline for beat 2:** ask a model with no tools the same superheat question and it confidently answers **15°F**. With the tool it's **3.2°F**. The model decides *when* to calculate; your code does the calculation.

**Extras if there's time:** turn Airplane Mode off and show the field note arriving in Capella. Or create a work order in the Mac **FieldDispatcher** and watch it appear on the phone.

## If something goes off-script
- **No tool card on beat 2 or 3:** the agent only offers the calculator when the message has a pressure in psig. Re-tap the suggested prompt rather than retyping it.
- **Beat 4 doesn't save a note:** that check runs a few seconds after the answer appears, so wait for the "saved your fix" line. If it still misses, run Reset and rerun the flow.
- **Qwen3.5 selected:** the first time it's enabled, it downloads about 2.4 GB with a progress bar. Do that before the meeting, not live.

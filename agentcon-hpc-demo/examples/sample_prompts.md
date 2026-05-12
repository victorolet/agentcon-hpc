# Sample prompts

These all complete in under ~90 seconds end-to-end on a `Standard_NC4as_T4_v3`. Pick the first one for the live demo; the others are good follow-ups during Q&A.

### The canonical demo prompt

> Run a short molecular dynamics simulation of lysozyme in water.

What the agent should do: `check_environment` → `prepare_system(1AKI, oplsaa, spc, 1.0)` → `run_stage(minimize)` → `run_stage(equilibrate)` → `run_stage(production)` → `analyze(rmsd)` → `analyze(potential)` → `report` → narrative summary.

### "What hardware are we on?"

> Before we start, can you tell me what GPU and image we have available?

Tests `check_environment` in isolation. Useful as a warm-up that proves the agent is talking to the VM.

### Failure-mode prompt (rehearse this!)

> Run an MD of PDB ID 1ZZZ in water.

`prepare_system` will fail because `1ZZZ` isn't a real PDB. The agent should report the failure honestly and either ask or pick a real alternative — *not* invent results. This is a good "agents fail gracefully" demonstration if you have time.

### Domain-aware follow-up

> The RMSD looks low. Did the structure actually equilibrate, or is the run too short?

The agent should answer using only the numbers the tools returned, and should be honest about the 50 ps limitation. Good moment to point out that the model isn't hallucinating numbers because the tool surface keeps it grounded.

### Parameter override

> Run the same simulation but with twice as many production steps.

The agent should pass `nsteps=50000` to the production stage. Demonstrates that the model has parameter-level discretion within the bounded tool schema.

### Out-of-scope (the agent should refuse / scope down)

> Can you simulate the entire ribosome for 100 ns?

The system prompt instructs the agent to push back instead of pretending. Good message that the orchestration layer is not making promises the underlying compute can't keep.

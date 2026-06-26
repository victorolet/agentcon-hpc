# Talk outline — AI Agents as Aid to HPC

**Length:** 30 minutes (target ~25 min talk + ~5 min Q&A; or 28 + 2 if rooms run hard cutoff).
**Core message:** *Agents are not replacing HPC systems. They are simplifying access to them by acting as orchestration layers.*

The outline below is structured as three acts — Science, Infrastructure, Orchestration — with the live demo as the climax of Act III. Times are approximate; trim Act I or the lessons section if you run long.

---

## Act I — Why this matters (≈8 min, slides 1–8)

### Slide 1 — Title (0:00–0:30)
- "AI Agents as Aid to HPC: Lessons from a Live Demo"
- Your name, affiliation, AgentCon
- One-line hook: *"I spent a day getting an AI agent to run a real molecular dynamics simulation on a GPU. Most of that day wasn't about the AI."*

### Slide 2 — Why are we here? (0:30–1:30)
- Two communities that rarely talk: AI/agents engineers and HPC scientists
- Both have the same underlying problem: *complexity is the bottleneck*
- The promise: agents can act as a thin layer that makes HPC accessible to people who shouldn't need to learn Slurm
- The honest framing: this is *not* an autonomous research agent — it's a constrained orchestration tool

### Slide 3 — The science: molecular dynamics in one slide (1:30–3:00)
- Diagram: protein in a box of water, atoms vibrating, Newton's laws integrated over picoseconds
- Why MD matters: drug discovery, materials science, protein folding, ion channels, COVID spike protein simulations
- The unit of work: *one simulation = picoseconds to microseconds of integrated motion of thousands of atoms*
- The numbers: lysozyme in water is ~33,000 atoms; a 100 ns simulation is ~50 million timesteps

### Slide 4 — MD as a pipeline of distinct jobs (3:00–5:00)
- This is the key concept slide. Lay out the stages visually as a flowchart:
  1. **System preparation** — fetch PDB, generate topology (pdb2gmx), build simulation box (editconf), solvate (solvate), add ions (genion)
  2. **Energy minimization** — relieve unfavourable contacts. Steepest descent. ~5,000 steps. Cheap.
  3. **NVT equilibration** — constant N, V, T. Position restraints on the protein while water settles around it. ~50 ps.
  4. **NPT equilibration** *(not in our demo, mention as the textbook fourth step)* — constant pressure too. Lets the box settle. ~50 ps.
  5. **Production MD** — restraints off, statistics gathered. Where the actual science happens. ns to µs.
  6. **Analysis** — RMSD, RMSF, secondary structure, hydrogen bonds, etc.
- Speaker note: each of these stages is a separate scientific decision and a separate GROMACS invocation. Six tool calls, in the right order, with the right files in the right places.

### Slide 5 — How this normally happens (5:00–6:30)
- The HPC scientist's morning:
  - Write a Slurm submission script
  - SSH to the cluster login node
  - Copy input files to parallel filesystem
  - Submit; wait
  - Poll `squeue`; check `slurm-*.out`; parse mdrun logs by hand
  - Realise you got the box size wrong; restart
- Point: *the science is one slide. The plumbing is the entire process.*

### Slide 6 — The accessibility gap (6:30–7:30)
- The people who *want* simulation results are not the people fluent in `sbatch`
- Pharma chemists, structural biologists, materials engineers, students
- A scientist with a question shouldn't need to learn batch systems to get an answer
- This is where an orchestration layer earns its keep

### Slide 7 — What about the cloud? (7:30–8:00)
- Hyperscalers solve "machines" but not "ergonomics"
- An Azure GPU VM doesn't help if you still need to know `cmake`, `mdrun`, `genion`, `grompp`
- Cloud is necessary infrastructure; not sufficient interface

### Slide 8 — Act I close: the gap, named (8:00–8:30)
- One sentence summary of Act I: *real science exists on capable hardware behind a wall of plumbing nobody wants to learn*

---

## Act II — The orchestration story (≈6 min, slides 9–14)

### Slide 9 — What an agent is, for our purposes (8:30–9:30)
- Not a generic chatbot. Not autonomous research.
- A specific definition: *a reasoning model + a tool surface + a controller that loops between them*
- "Constrained reliability over autonomy" — the design choice

### Slide 10 — The four-layer architecture (9:30–11:00)
- Architecture diagram (the Mermaid one from `docs/architecture.md`):
  - **Reasoning:** Azure AI Foundry + GPT-4o
  - **Agent execution:** Python loop with bounded tools
  - **Compute:** Azure GPU VM (T4)
  - **Containerized workflow:** Docker + GROMACS
- The model never executes commands. The agent layer is the only thing that runs things.
- That separation *is* the safety property.

### Slide 11 — The six-tool surface (11:00–12:00)
- Show the actual tool list:
  - `check_environment`
  - `prepare_system(pdb_id, force_field, water_model, box_nm)`
  - `run_stage(run_id, stage, nsteps)`
  - `analyze(run_id, metric)`
  - `visualize_trajectory(run_id)`
  - `report(run_id)`
- "The model has discretion over *which tools to call and in what order with what parameters*. It does not have discretion over *what is possible*. That is the reliability story."

### Slide 12 — How the model decides (12:00–13:00)
- Show the actual sequence diagram (the one from `docs/architecture.md`)
- Animate (or click-build) one tool call at a time so the audience tracks the back-and-forth
- Each tool returns small structured JSON, not log walls. The model's context stays clean.

### Slide 13 — Why this isn't AutoGPT (13:00–13:30)
- Single agent, no multi-agent choreography
- No long-horizon planning, no self-modification, no chain-of-thought outside what the model emits naturally
- "I deliberately chose the boring architecture. The constraint is the feature."

### Slide 14 — Act II close: orchestration as a primitive (13:30–14:00)
- The agent layer is the same shape whether the workload is MD, CFD, weather, or genomics
- We're going to demonstrate it with lysozyme, but the pattern generalises

---

## Act III — Live demo and reality check (≈12 min, slides 15–22)

### Slide 15 — The demo prompt (14:00–14:30)
- Single line on the slide: *"Run a short molecular dynamics simulation of lysozyme in water."*
- "What I'm going to type. What it's going to do. What you should watch for."

### Slides 16–18 — LIVE DEMO (14:30–22:30)
- Switch to the terminal (or your VS Code remote SSH window)
- Run the prompt
- Narrate while the agent works:
  - **`check_environment`**: "It's confirming Docker, the T4 GPU, and the GROMACS image"
  - **`prepare_system`**: "It picked PDB 1AKI — that's lysozyme — and reasonable defaults: OPLS-AA force field, SPC water, 1 nm box. ~33,000 atoms after solvation."
  - **`run_stage(minimize/equilibrate/production)`**: "Three stages, each a separate tool call. Minimisation is fast on CPU. Equilibration and production use the GPU; on a T4 we're getting about 270 ns/day."
  - **`analyze`** + **`visualize_trajectory`**: "Plots and a viewable trajectory."
- Stop and show:
  - The RMSD plot (`/data/run-XXXX/analysis/rmsd.png`)
  - The trajectory in the browser (`viewer.html` open in advance)
- "This took about 90 seconds. None of those 90 seconds were me typing a `gmx` command."

### Slide 19 — Behind the scenes: the build (22:30–24:00)
- Cluster of screenshots (small, multi-image slide):
  - Azure Portal: VM + NSG + managed identity
  - Foundry Portal: project, model deployment, agent
  - Docker images on the VM
  - The Dockerfile (a screenshot of the multi-stage CUDA build)
- One line under each: "≈10 min to provision the VM, ≈10 min to build the image, ≈5 min to wire up Foundry RBAC, one-time."
- See `docs/build-journal.md` for the inspection commands behind each screenshot.

### Slide 20 — Lessons learned (24:00–25:30)
- The honest one. Three bullets:
  1. **Most of the work was not AI.** Foundry RBAC role-name drift, Docker version differences in `docker images` output, GROMACS' `-ntmpi` requirement, dotenv override semantics, container `set -u` clashing with `GMXRC`, `posre.itp` include path resolution. *None* of those are the model. All of them are orchestration plumbing.
  2. **The model confabulated tool output once.** Bounded tools don't fully prevent the model from inventing facts in its natural-language summaries; tighten the system prompt and force structured-only summaries where it matters.
  3. **When a defensive layer has more failure modes than the operation it gates, the layer is the problem.** I removed the image-presence pre-check because it was version-brittle; letting docker's own error surface was simpler and clearer.

### Slide 21 — Where this goes (25:30–26:30)
- Swap the workload: same agent, same tool shape, different scientific domain (LAMMPS, OpenFOAM, NAMD)
- Scale out: replace single-VM with VMSS or Slurm or AKS, still no agent change
- Real HPC: front a Slurm cluster, with the agent submitting jobs and parsing `squeue`
- Multi-step planning: the agent could propose a series of simulations and analyze across them — but only once the single-simulation pattern is rock solid

### Slide 22 — Close (26:30–27:00)
- Restate the core message: *"Agents are not replacing HPC systems. They are simplifying access to them by acting as orchestration layers."*
- One sentence call to action: *"If you're an HPC engineer, the orchestration layer is the highest-leverage piece of software you can write right now. If you're an agents engineer, the science workflows on the other side of that layer are an enormous unmet need."*
- Slide also has: link to the repo, your email, "Questions?"

### Q&A (27:00–30:00)

---

## Speaker notes / production tips

### Pacing
- Act I is the part most likely to overrun. If you need to cut, drop Slide 5 (Slurm workflow) — the audience often already knows.
- Live demo target: **8 minutes**. Hard ceiling: 10. Past 10, the audience disengages waiting for the simulation.
- If the GPU is fast and the demo finishes early, fill with Slide 19 (Behind the scenes) — talk through the build artifacts.

### Demo risk profile
- Pre-warm the VM 30 minutes before. SSH in once before the talk to confirm the agent starts cleanly with a "what's the GPU?" prompt.
- Pre-open: terminal, Foundry portal trace view in second tab, browser tab on yesterday's rehearsal `viewer.html` (your fallback if today's network is flaky).
- Backup plan: if Foundry has a transient 5xx, retry once. If still failing, switch to Slide 19 (build artifacts) and narrate what would have happened from yesterday's recorded run.

### What to *not* put on slides
- No source code beyond the six-tool list. Code-on-slides reads as defensive and slows pacing.
- No Mermaid diagrams in their raw form — re-render as images.
- No bullet lists longer than three items. If a slide has six bullets, it's two slides.

### Recommended visual style
- One idea per slide. Use the diagram space for diagrams, not text.
- Code only on the tool-list slide; everything else is prose or imagery.
- Consistent colour for the four layers across the architecture slide and the sequence diagram.

### Possible cuts under time pressure
- Slide 13 (not-AutoGPT) is the easiest to drop.
- Slide 7 (cloud) can be folded into Slide 5.
- Slide 21 (where this goes) can compress to one bullet on Slide 22.


# Demo runbook

Everything needed to stand this up before a talk and run it on stage with low risk.

## Hardware and quota

You need one of these VM sizes available in your subscription:

| SKU | GPU | vCPU/RAM | Notes |
|---|---|---|---|
| `Standard_NC4as_T4_v3` | 1× T4 | 4 / 28 GB | Cheapest, recommended. 50 ps lysozyme MD ≈ 15 s. |
| `Standard_NV6ads_A10_v5` | 1× A10 (1/6) | 6 / 55 GB | If you can't get T4 quota. Same job ≈ 8 s. |

In Azure, GPU quota is per-region and per-family. Request quota at least a week before the talk; the request is sometimes manual.

## Pre-talk timeline

### T-7 days
- Request GPU quota in the target region if you don't already have it.
- Create the Foundry project; deploy `gpt-4o` or `gpt-4.1`.
- Run `infra/provision-vm.sh` and `infra/setup-vm.sh` end to end. Build the GROMACS container. Run the canonical prompt at least once. Save the agent's response and the generated plots — these are your fallback.

### T-1 day
- Power the VM **on** the day before. Do not deallocate it overnight before the talk — boot + driver re-init occasionally surfaces issues you don't want at 9am.
- Run the canonical prompt once. Confirm: `gpu_ok=true`, run completes, RMSD plot generates.
- Put the VM's public IP in a sticky note. Pre-open the SSH session in your terminal.

### T-1 hour
- Verify SSH still works.
- Run `docker run --rm --gpus all gromacs-demo:latest gmx --version` — this catches NVIDIA driver / Docker runtime breakage from any unexpected reboot.
- Pre-open: terminal with SSH session, browser tab on the Foundry project's tracing view, browser tab on `/data/run-XXX/analysis/rmsd.png` from yesterday's rehearsal (your fallback image).

### T-5 minutes
- Activate the Python venv in the SSH session.
- Have `python agent.py` typed, but not pressed-enter.

## On-stage sequence

Approx. 8 minutes for the live demo segment.

1. **Set up the message (1 min).** "I'm going to ask an agent to run a molecular dynamics simulation. The agent has six tools. It cannot execute arbitrary code. Watch what it does." Show the architecture diagram from `architecture.md`.

2. **Start the agent (15 s).** Hit enter. Confirm it prints `agent_id=...` and `thread_id=...`.

3. **The canonical prompt (5 min).**
   ```
   > Run a short molecular dynamics simulation of lysozyme in water.
   ```
   While the agent works, narrate:
   - "It's calling `check_environment` first. It'll come back with `gpu_ok: true`."
   - "Now `prepare_system`. It picked PDB 1AKI — that's lysozyme, the model knows that."
   - "Three runs: minimize, equilibrate, production. Each is a tool call, not a model-generated shell command."
   - During the production stage, switch to the Foundry tracing view and show the tool-call ping-pong live.

4. **Show the result (1 min).** Open `/data/run-XXX/analysis/rmsd.png`. Read the agent's natural-language summary from the terminal.

5. **One follow-up (1 min, time permitting).** Use the "RMSD looks low — did it actually equilibrate?" prompt. This shows the agent staying honest about a 50 ps run instead of overclaiming. It is the most important moment of the demo.

## What to say while it's running

There's about 60 seconds of dead air during the production MD step. Use it. Some options that have worked:

- *"This is the part that, on a 'real' HPC system, would mean writing a Slurm script, copying input files to a parallel filesystem, polling `squeue`, and parsing log output by hand. Notice that none of that is happening. The agent is doing the orchestration; the VM is doing the science."*
- *"Notice what the model is **not** doing. It's not writing GROMACS commands. It's choosing parameters within a bounded tool schema. That's why this is reliable enough to do live."*
- *"The trace on the right is what the audit log of an agent looks like. Every decision the model made is replayable."*

## Fallbacks (in increasing order of pessimism)

1. **Foundry transient error.** Re-run. The SDK retries internally; one explicit re-run almost always works.
2. **VM unreachable.** SSH from a phone hotspot in case the venue Wi-Fi has weird routing. Have the VM's public IP memorized.
3. **GPU container fails.** `docker run --rm --gpus all gromacs-demo:latest gmx --version` first. If it fails: `sudo systemctl restart docker`. If still failing: switch to recorded run.
4. **Whole VM is dead.** Open the saved screenshots and run the trace replay you saved at T-1 day. Narrate as if it were live; the message survives. Be honest with the audience that you're showing a recording — they will respect that more than a recovery attempt that eats 5 minutes.

## After the talk

```bash
# Free the GPU. You're paying for it by the hour.
az vm deallocate -g agentcon-hpc-demo -n hpc-agent-vm

# When you're sure you don't need the data:
./infra/teardown.sh
```

A T4 VM running 24/7 in `eastus` is approximately $400/month. A T4 VM deallocated is essentially free except for the OS disk (~$10/month).

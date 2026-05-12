# Example tool-calling flow (annotated trace)

This is what an end-to-end run actually looks like over the wire — useful to project on a screen during the talk so the audience can follow the agent's reasoning. Trimmed for readability; structurally faithful to what Foundry traces look like.

## User prompt

> Run a short molecular dynamics simulation of lysozyme in water.

## Turn 1 — model emits tool call

```json
{
  "role": "assistant",
  "tool_calls": [{
    "id": "call_01",
    "type": "function",
    "function": {
      "name": "check_environment",
      "arguments": "{}"
    }
  }],
  "content": null
}
```

## Turn 1 — tool result

```json
{
  "tool_call_id": "call_01",
  "content": {
    "docker_ok": true,
    "gpu_ok": true,
    "gpu_name": "Tesla T4",
    "image_present": true,
    "image_tag": "gromacs-demo:latest"
  }
}
```

## Turn 2 — model picks parameters and prepares the system

The model knows (from training) that lysozyme has PDB ID `1AKI` (or it can ask, but the system prompt tells it to default sensibly). It picks OPLS-AA force field and SPC water — the canonical Lemkul-tutorial choices for this protein.

```json
{
  "role": "assistant",
  "tool_calls": [{
    "id": "call_02",
    "type": "function",
    "function": {
      "name": "prepare_system",
      "arguments": "{\"pdb_id\": \"1AKI\", \"force_field\": \"oplsaa\", \"water_model\": \"spc\", \"box_nm\": 1.0}"
    }
  }]
}
```

```json
{
  "tool_call_id": "call_02",
  "content": {
    "run_id": "run-7c41",
    "pdb_id": "1AKI",
    "n_atoms": 33012,
    "n_water": 10518,
    "box_nm": [6.97, 6.97, 6.97],
    "files": ["topology/topol.top", "em.tpr"]
  }
}
```

## Turns 3–5 — the three MD stages

The model issues these one at a time, waiting for each to complete:

```json
{"function": "run_stage", "arguments": "{\"run_id\": \"run-7c41\", \"stage\": \"minimize\", \"nsteps\": 5000}"}
{"function": "run_stage", "arguments": "{\"run_id\": \"run-7c41\", \"stage\": \"equilibrate\", \"nsteps\": 25000}"}
{"function": "run_stage", "arguments": "{\"run_id\": \"run-7c41\", \"stage\": \"production\", \"nsteps\": 25000}"}
```

Each tool result looks like:

```json
{
  "tool_call_id": "call_05",
  "content": {
    "stage": "production",
    "walltime_s": 14.7,
    "ns_per_day": 294.0,
    "final_potential_kJ_mol": -5.41e5,
    "trajectory": "prod/md.xtc"
  }
}
```

## Turns 6–7 — analysis

```json
{"function": "analyze", "arguments": "{\"run_id\": \"run-7c41\", \"metric\": \"rmsd\"}"}
{"function": "analyze", "arguments": "{\"run_id\": \"run-7c41\", \"metric\": \"potential\"}"}
```

```json
{
  "tool_call_id": "call_06",
  "content": {
    "metric": "rmsd",
    "plot_path": "/data/run-7c41/analysis/rmsd.png",
    "summary": {
      "mean_nm": 0.182,
      "stdev_nm": 0.024,
      "plateau_after_ps": 30
    }
  }
}
```

## Turn 8 — final natural-language summary

```json
{
  "role": "assistant",
  "content": "Done. I ran a 50 ps molecular dynamics simulation of lysozyme (PDB 1AKI) in SPC water on a T4 GPU. The protein equilibrated quickly: backbone RMSD plateaued around 0.18 nm after ~30 ps, which is typical for a well-folded globular protein on this timescale. Mean potential energy was -5.4×10⁵ kJ/mol with no drift — the system is stable. Plots are at /data/run-7c41/analysis/. For a publication-quality run you'd want at least 100 ns and probably NPT equilibration; this was sized for the demo."
}
```

## What the audience should notice

- The model never wrote `gmx` commands. It made six tool calls.
- Tool results are small, structured, and cheap — no walls of mdrun log spam reach the model.
- The model's *only* contribution was choosing PDB ID, force field, water model, box size, and step counts — and writing the closing paragraph. Everything else is the orchestration layer.
- This is good. The reliability comes from how *little* discretion the model has.

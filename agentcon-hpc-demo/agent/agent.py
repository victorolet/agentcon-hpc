"""Main entry point: a small REPL that drives an Azure AI Foundry agent
through the molecular-dynamics tool surface defined in tools.py.

Run on the GPU VM after setup-vm.sh and the container build:

    cp .env.example .env
    # edit .env
    pip install -r requirements.txt
    python agent.py

Type a natural-language request, e.g.:
    > Run a short molecular dynamics simulation of lysozyme in water.

Quit with Ctrl-D.
"""
from __future__ import annotations

import os
import sys
import time

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import FunctionTool, ToolSet
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv
from rich.console import Console
from rich.panel import Panel

from prompts import SYSTEM_PROMPT
from tools import ALL_TOOLS

console = Console()


def main() -> int:
    load_dotenv()
    conn_str = os.environ.get("PROJECT_CONNECTION_STRING")
    model = os.environ.get("MODEL_DEPLOYMENT_NAME", "gpt-4o")
    if not conn_str:
        console.print("[red]PROJECT_CONNECTION_STRING is required (see .env.example)[/red]")
        return 2

    project = AIProjectClient.from_connection_string(
        credential=DefaultAzureCredential(),
        conn_str=conn_str,
    )

    # Build the toolset from our Python callables. Foundry will inspect
    # type hints and docstrings to generate the JSON schemas the model sees.
    functions = FunctionTool(functions=ALL_TOOLS)
    toolset = ToolSet()
    toolset.add(functions)

    # Reuse the same agent across runs so we don't litter the project.
    agent = project.agents.create_agent(
        model=model,
        name="hpc-orchestrator-demo",
        instructions=SYSTEM_PROMPT,
        toolset=toolset,
    )
    console.print(f"[dim]agent_id={agent.id}[/dim]")

    thread = project.agents.create_thread()
    console.print(f"[dim]thread_id={thread.id}[/dim]")
    console.print(Panel.fit(
        "[bold]HPC orchestration agent ready.[/bold]\n"
        "Type a request. Ctrl-D to exit.",
        border_style="cyan",
    ))

    try:
        while True:
            try:
                user_input = console.input("\n[bold green]> [/bold green]").strip()
            except EOFError:
                break
            if not user_input:
                continue

            project.agents.create_message(
                thread_id=thread.id, role="user", content=user_input,
            )

            t0 = time.time()
            with console.status("[cyan]agent working...[/cyan]"):
                run = project.agents.create_and_process_run(
                    thread_id=thread.id, agent_id=agent.id,
                )
            elapsed = time.time() - t0

            if run.status != "completed":
                console.print(f"[red]Run ended with status: {run.status}[/red]")
                if run.last_error:
                    console.print(f"[red]{run.last_error}[/red]")
                continue

            # Print only the latest assistant message.
            msgs = project.agents.list_messages(thread_id=thread.id)
            for msg in msgs.data:
                if msg.role == "assistant":
                    for chunk in msg.content:
                        if chunk.type == "text":
                            console.print(Panel(
                                chunk.text.value,
                                title="agent",
                                border_style="cyan",
                                subtitle=f"{elapsed:.1f}s",
                            ))
                    break

    finally:
        # Clean up to keep the Foundry project tidy.
        try:
            project.agents.delete_agent(agent.id)
        except Exception:
            pass

    return 0


if __name__ == "__main__":
    sys.exit(main())

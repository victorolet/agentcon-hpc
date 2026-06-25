"""Main entry point: a small REPL that drives an Azure AI Foundry agent
through the molecular-dynamics tool surface defined in tools.py.

Written for the GA SDK: azure-ai-agents >= 1.0.
"""
from __future__ import annotations

import os
import sys
import time

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import FunctionTool, ListSortOrder, ToolSet
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv
from rich.console import Console
from rich.panel import Panel

from prompts import SYSTEM_PROMPT
from tools import ALL_TOOLS

console = Console()


def main() -> int:
    # Default load_dotenv behaviour: shell-exported env vars take precedence
    # over .env. Lets you do `WORKFLOW_DIR=... python3 agent.py` to override
    # on the command line. Trade-off: stale exports from a prior session
    # also win silently. If your demo is breaking and the cause looks like
    # a config mismatch, check the running shell with `env | grep -E
    # 'WORKFLOW_DIR|GMX_IMAGE|GPU_VENDOR'` and `unset` anything stale.
    load_dotenv()

    endpoint = os.environ.get("PROJECT_ENDPOINT") or os.environ.get("PROJECT_CONNECTION_STRING")
    model = os.environ.get("MODEL_DEPLOYMENT_NAME", "gpt-4o")
    if not endpoint:
        console.print("[red]PROJECT_ENDPOINT is required (see .env.example)[/red]")
        return 2

    agents_client = AgentsClient(
        endpoint=endpoint,
        credential=DefaultAzureCredential(),
    )

    with agents_client:
        functions = FunctionTool(functions=ALL_TOOLS)
        toolset = ToolSet()
        toolset.add(functions)
        agents_client.enable_auto_function_calls(toolset)

        agent = agents_client.create_agent(
            model=model,
            name="hpc-orchestrator-demo",
            instructions=SYSTEM_PROMPT,
            toolset=toolset,
        )
        console.print(f"[dim]agent_id={agent.id}[/dim]")

        thread = agents_client.threads.create()
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

                agents_client.messages.create(
                    thread_id=thread.id, role="user", content=user_input,
                )

                t0 = time.time()
                with console.status("[cyan]agent working...[/cyan]"):
                    run = agents_client.runs.create_and_process(
                        thread_id=thread.id, agent_id=agent.id,
                    )
                elapsed = time.time() - t0

                if run.status != "completed":
                    console.print(f"[red]Run ended with status: {run.status}[/red]")
                    if getattr(run, "last_error", None):
                        console.print(f"[red]{run.last_error}[/red]")
                    continue

                msgs = agents_client.messages.list(
                    thread_id=thread.id, order=ListSortOrder.DESCENDING,
                )
                for msg in msgs:
                    if msg.role != "assistant":
                        continue
                    if msg.text_messages:
                        text = msg.text_messages[-1].text.value
                        console.print(Panel(
                            text, title="agent",
                            border_style="cyan",
                            subtitle=f"{elapsed:.1f}s",
                        ))
                    break

        finally:
            try:
                agents_client.delete_agent(agent.id)
            except Exception:
                pass

    return 0


if __name__ == "__main__":
    sys.exit(main())

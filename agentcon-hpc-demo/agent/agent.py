"""Main entry point: a small REPL that drives an Azure AI Foundry agent
through the molecular-dynamics tool surface defined in tools.py.

Written for the GA SDK:
    azure-ai-agents >= 1.0    (agents, threads, messages, runs, tools)

In the GA layout, AgentsClient is the canonical entry point for all
agent operations (and is what carries enable_auto_function_calls).
AIProjectClient from azure-ai-projects is for project-level operations
like connections and deployments; for an agent loop we don't need it.

Run on the GPU VM after setup + container build:

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
    load_dotenv()

    # GA SDK takes an endpoint URL, not a beta-style connection string.
    # We accept either PROJECT_ENDPOINT or PROJECT_CONNECTION_STRING (legacy
    # name from when the .env.example was first written) so users with the
    # old name don't have to re-edit. The value is the same: the project
    # endpoint URL, e.g.
    #   https://<resource>.services.ai.azure.com/api/projects/<project>
    endpoint = os.environ.get("PROJECT_ENDPOINT") or os.environ.get("PROJECT_CONNECTION_STRING")
    model = os.environ.get("MODEL_DEPLOYMENT_NAME", "gpt-4o")
    if not endpoint:
        console.print("[red]PROJECT_ENDPOINT is required (see .env.example)[/red]")
        return 2

    # AgentsClient is the GA entry point. enable_auto_function_calls,
    # threads, messages, runs all hang off this object directly.
    agents_client = AgentsClient(
        endpoint=endpoint,
        credential=DefaultAzureCredential(),
    )

    with agents_client:
        # Build the toolset from our Python callables. The SDK introspects
        # type hints and docstrings to generate the JSON tool schemas the
        # model sees.
        functions = FunctionTool(functions=ALL_TOOLS)
        toolset = ToolSet()
        toolset.add(functions)

        # Register the toolset for auto-dispatch during runs.create_and_process.
        # Without this, runs hang in "requires_action" because the SDK doesn't
        # know which Python callables back the tool definitions.
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
                    thread_id=thread.id,
                    role="user",
                    content=user_input,
                )

                t0 = time.time()
                with console.status("[cyan]agent working...[/cyan]"):
                    run = agents_client.runs.create_and_process(
                        thread_id=thread.id,
                        agent_id=agent.id,
                    )
                elapsed = time.time() - t0

                if run.status != "completed":
                    console.print(f"[red]Run ended with status: {run.status}[/red]")
                    if getattr(run, "last_error", None):
                        console.print(f"[red]{run.last_error}[/red]")
                    continue

                # Pull the latest assistant message. GA: messages.list returns
                # an ItemPaged; DESCENDING puts newest first.
                msgs = agents_client.messages.list(
                    thread_id=thread.id,
                    order=ListSortOrder.DESCENDING,
                )
                for msg in msgs:
                    if msg.role != "assistant":
                        continue
                    # msg.text_messages is a list of MessageTextContent; the
                    # last one is the visible reply.
                    if msg.text_messages:
                        text = msg.text_messages[-1].text.value
                        console.print(Panel(
                            text,
                            title="agent",
                            border_style="cyan",
                            subtitle=f"{elapsed:.1f}s",
                        ))
                    break

        finally:
            # Clean up so the Foundry project doesn't accumulate stale agents.
            try:
                agents_client.delete_agent(agent.id)
            except Exception:
                pass

    return 0


if __name__ == "__main__":
    sys.exit(main())

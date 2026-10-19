"""Apply the shared context budget at every legacy LangChain model request."""

from langchain.agents.middleware import AgentMiddleware, ModelRequest
from langchain_core.messages import convert_to_openai_messages
from langchain_core.utils.function_calling import convert_to_openai_tool

from .conversation_context import bounded_context


class ContextBudgetMiddleware(AgentMiddleware):
    def __init__(self, limit: int):
        self.limit = limit

    def _bounded_request(self, request: ModelRequest) -> ModelRequest:
        messages = request.messages
        wire = convert_to_openai_messages(messages)
        # chat() supplies only complete old text pairs. Everything from the last
        # human message onwards is the live turn, including all tool exchanges.
        current = max((i for i, m in enumerate(messages) if m.type == "human"), default=0)
        old = [wire[i:i + 2] for i in range(0, current, 2)]
        retained = bounded_context(
            {"role": "system", "content": request.system_message.content
             if request.system_message is not None else ""},
            old, wire[current:], [convert_to_openai_tool(t) for t in request.tools], self.limit,
        )
        removed = len(wire) - (len(retained) - 1)
        # Do not mutate graph state or message identities: only the provider input
        # changes. The original current-turn messages remain available to callers.
        return request.override(messages=messages[removed:])

    def wrap_model_call(self, request, handler):
        return handler(self._bounded_request(request))

    async def awrap_model_call(self, request, handler):
        return await handler(self._bounded_request(request))

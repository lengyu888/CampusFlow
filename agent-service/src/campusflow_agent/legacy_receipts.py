"""Keep completed legacy tool receipts scoped to one chat, including on timeout."""

from contextvars import ContextVar
from copy import deepcopy

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import AIMessage, ToolMessage

CURRENT_LEGACY_RECEIPTS: ContextVar[list[tuple[dict, ToolMessage]] | None] = ContextVar(
    "legacy_chat_receipts", default=None,
)


class LegacyReceiptMiddleware(AgentMiddleware):
    async def awrap_tool_call(self, request, handler):
        receipts = CURRENT_LEGACY_RECEIPTS.get()
        call = deepcopy(request.tool_call)
        result = await handler(request)
        if receipts is not None and isinstance(result, ToolMessage):
            # No await between receiving the actual result and retaining it. Child
            # tool tasks share this chat's list, not a service-wide mutable default.
            receipts.append((call, result.model_copy(deep=True)))
        return result


def receipt_messages(receipts: list[tuple[dict, ToolMessage]]) -> list:
    messages = []
    for call, result in receipts:
        messages.extend([AIMessage(content="", tool_calls=[call]), result])
    return messages

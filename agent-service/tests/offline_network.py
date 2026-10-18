"""Socket isolation for offline tests, including Windows asyncio's local wakeup pair."""

import socket
from collections.abc import Callable, Iterator
from contextlib import ExitStack, contextmanager
from contextvars import ContextVar
from ipaddress import ip_address
from typing import NoReturn
from unittest.mock import patch


@contextmanager
def deny_network(denied: Callable[..., NoReturn]) -> Iterator[None]:
    """Block TCP/DNS/UDP; permit only socketpair's synchronous local construction.

    Windows implements socketpair using a temporary loopback listener. Do not
    whitelist localhost generally: the exception exists only inside the trusted
    standard-library factory, with no await, and is isolated by thread/context.
    """
    creating_pair = ContextVar("creating_offline_socketpair", default=False)
    original_pair = socket.socketpair
    original_connect = socket.socket.connect
    original_connect_ex = socket.socket.connect_ex
    original_sendto = socket.socket.sendto

    def local_pair_address(address):
        if not creating_pair.get() or not isinstance(address, tuple) or len(address) < 2:
            return False
        try:
            return ip_address(address[0]).is_loopback
        except ValueError:
            return False

    def connect(sock, address):
        if sock.family in {socket.AF_INET, socket.AF_INET6} and not local_pair_address(address):
            denied()
        return original_connect(sock, address)

    def connect_ex(sock, address):
        if sock.family in {socket.AF_INET, socket.AF_INET6} and not local_pair_address(address):
            denied()
        return original_connect_ex(sock, address)

    def sendto(sock, *args):
        if sock.family in {socket.AF_INET, socket.AF_INET6}:
            denied()
        return original_sendto(sock, *args)

    def socketpair(*args, **kwargs):
        token = creating_pair.set(True)
        try:
            return original_pair(*args, **kwargs)
        finally:
            creating_pair.reset(token)

    with ExitStack() as stack:
        stack.enter_context(patch.object(socket.socket, "connect", connect))
        stack.enter_context(patch.object(socket.socket, "connect_ex", connect_ex))
        stack.enter_context(patch.object(socket.socket, "sendto", sendto))
        stack.enter_context(patch.object(socket, "socketpair", socketpair))
        stack.enter_context(patch.object(socket, "create_connection", denied))
        stack.enter_context(patch.object(socket, "getaddrinfo", denied))
        yield

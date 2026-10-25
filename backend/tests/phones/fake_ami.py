"""Just enough of an Asterisk Manager Interface to test the client: challenge login, a few list actions,
and events emitted on demand."""

from __future__ import annotations

import asyncio
import hashlib

from pos.phones.ami import Message, encode_packet, read_packet


class FakePBX:
    def __init__(self, secret: str = "s3cret", challenge: str = "4242") -> None:
        self.secret, self.challenge = secret, challenge
        self.received: list[Message] = []
        self.port = 0
        self._writers: list[asyncio.StreamWriter] = []

    async def __aenter__(self) -> FakePBX:
        self._server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *exc: object) -> None:
        self._server.close()
        await self._server.wait_closed()

    async def emit(self, **fields: str) -> None:
        for writer in self._writers:
            writer.write(encode_packet(fields))
            await writer.drain()

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        writer.write(b"Asterisk Call Manager/7.0.3\r\n")
        await writer.drain()
        self._writers.append(writer)
        try:
            while True:
                packet = await read_packet(reader)
                self.received.append(packet)
                for reply in self._replies(packet):
                    writer.write(encode_packet(reply))
                await writer.drain()
                if packet.get("Action") == "Logoff":
                    break
        except ConnectionError:
            pass
        finally:
            self._writers.remove(writer)
            writer.close()

    def _replies(self, packet: Message) -> list[Message]:
        action, action_id = packet.get("Action"), packet.get("ActionID", "")
        ok: Message = {"Response": "Success", "ActionID": action_id}
        if action == "Challenge":
            return [{**ok, "Challenge": self.challenge}]
        if action == "Login":
            key = hashlib.md5((self.challenge + self.secret).encode(), usedforsecurity=False).hexdigest()
            if packet.get("Key") == key or packet.get("Secret") == self.secret:
                return [{**ok, "Message": "Authentication accepted"}]
            return [{"Response": "Error", "ActionID": action_id, "Message": "Authentication failed"}]
        if action == "CoreSettings":
            return [{**ok, "AsteriskVersion": "20.5.0", "SystemName": "freepbx-test"}]
        if action == "QueueSummary":
            rows = [
                {"Queue": "6001", "LoggedIn": "3", "Available": "2", "Callers": "0", "HoldTime": "0"},
                {"Queue": "6002", "LoggedIn": "1", "Available": "1", "Callers": "1", "HoldTime": "12"},
            ]
            return self._list(action_id, "QueueSummary", rows)
        if action == "PJSIPShowEndpoints":
            rows = [
                {"ObjectName": "201", "DeviceState": "Not in use"},
                {"ObjectName": "202", "DeviceState": "Unavailable"},
            ]
            return self._list(action_id, "EndpointList", rows)
        if action == "CoreShowChannels":
            return self._list(action_id, "CoreShowChannel", [])
        if action in ("QueuePause", "Originate"):
            return [{**ok, "Message": f"{action} accepted"}]
        if action == "Logoff":
            return [{"Response": "Goodbye", "ActionID": action_id, "Message": "Thanks for all the fish."}]
        return [{"Response": "Error", "ActionID": action_id, "Message": "Invalid/unknown command"}]

    @staticmethod
    def _list(action_id: str, event: str, rows: list[Message]) -> list[Message]:
        head: Message = {"Response": "Success", "ActionID": action_id, "EventList": "start", "Message": "will follow"}
        items: list[Message] = [{"Event": event, "ActionID": action_id, **row} for row in rows]
        tail: Message = {"Event": f"{event}Complete", "ActionID": action_id, "EventList": "Complete"}
        return [head, *items, tail]

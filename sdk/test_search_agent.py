"""Run: python3 -m unittest discover -s sdk -p 'test_search_agent.py'."""
import json
import io
import socket
import threading
import unittest

from search_agent import Agent, AgentError, AgentTimeout, SocketGone


class AgentLifecycleTest(unittest.TestCase):
    def setUp(self):
        client, self.server = socket.socketpair()
        self.agent = Agent(timeout=0.05)
        self.agent._sock = client
        self.agent._file = client.makefile("rb")
        self.agent._reader = threading.Thread(target=self.agent._read, daemon=True)
        self.agent._reader.start()
        self.server_file = self.server.makefile("rb")

    def tearDown(self):
        self.agent.close()
        self.server.close()
        self.server_file.close()

    def reply(self, message):
        self.server.sendall((json.dumps(message) + "\n").encode())

    def test_timeout_receipt_and_late_answer_are_bounded(self):
        with self.assertRaises(AgentTimeout) as raised:
            self.agent.call("page.js", js="sideEffect()")
        original = json.loads(self.server_file.readline())
        self.assertEqual(raised.exception.request_id, original["id"])
        self.assertEqual(raised.exception.receipt["outcome"], "unknown")
        self.assertFalse(self.agent._pending)

        def respond():
            status = json.loads(self.server_file.readline())
            self.assertEqual(status["args"]["requestId"], original["id"])
            self.reply({"id": original["id"], "result": {"late": True}})
            self.reply({"id": status["id"], "result": {"state": "running", "outcome": "unknown"}})

        thread = threading.Thread(target=respond)
        thread.start()
        status = self.agent.request_status(original["id"])
        thread.join()
        self.assertEqual(status["state"], "running")
        self.assertFalse(self.agent._results)

    def test_server_error_metadata_and_cancel_target(self):
        def respond():
            request = json.loads(self.server_file.readline())
            self.reply({"id": request["id"], "error": "outcome unknown", "code": "TIMEOUT",
                        "receipt": {"requestId": request["id"], "outcome": "unknown"}, "detail": 7})
            cancel = json.loads(self.server_file.readline())
            self.assertEqual(cancel["op"], "request.cancel")
            self.assertEqual(cancel["args"]["requestId"], request["id"])
            self.reply({"id": cancel["id"], "result": {"cancelRequested": True, "state": "running"}})

        thread = threading.Thread(target=respond)
        thread.start()
        with self.assertRaises(AgentError) as raised:
            self.agent.call("page.js", timeout=1)
        error = raised.exception
        self.assertEqual(error.code, "TIMEOUT")
        self.assertEqual(error.metadata["detail"], 7)
        self.assertEqual(error.receipt["outcome"], "unknown")
        self.assertTrue(self.agent.request_cancel(error.request_id)["cancelRequested"])
        thread.join()

    def test_disconnect_requires_explicit_reconnect(self):
        self.agent._fail("connection closed")
        self.agent.connect = lambda: self.fail("call silently reconnected")
        with self.assertRaises(SocketGone):
            self.agent.call("act.click")

    def test_reconnect_generation_ends_old_wait_without_retry(self):
        failures = []

        def call():
            try:
                self.agent.call("act.click", timeout=None)
            except SocketGone as error:
                failures.append(error)

        thread = threading.Thread(target=call)
        thread.start()
        original = json.loads(self.server_file.readline())
        with self.agent._cond:
            self.agent._generation += 1
            self.agent._cond.notify_all()
        thread.join(timeout=1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures[0].request_id, original["id"])
        self.assertEqual(failures[0].outcome, "unknown")
        self.agent._fail("old reader stopped", generation=0)
        self.assertIsNone(self.agent._dead)

    def test_events_drop_oldest_and_oversized_payloads(self):
        for i in range(300):
            self.agent._put_event({"event": "sample", "data": {"i": i}})
        self.assertEqual(self.agent._events.qsize(), 256)
        self.assertEqual(self.agent.next_event(0)["data"]["i"], 44)
        self.agent._put_event({"event": "sample", "data": {"text": "x" * 70_000}})
        self.assertEqual(self.agent.dropped_events, 45)

    def test_replaced_reader_cannot_deliver_buffered_events(self):
        old_reader = io.BytesIO(b'{"event":"page.dialog","data":{"id":"old"}}\n')
        self.agent._read(old_reader, generation=self.agent._generation - 1)
        self.assertIsNone(self.agent.next_event(0))
        self.assertIsNone(self.agent._dead)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Synthetic protocol peer for the production canvas Codex client; never runs tools."""
import json
import os
import sys
import time

mode = os.environ.get("OMG_CODEX_TEST_MODE", "stream")
capture = os.environ["OMG_CODEX_TEST_CAPTURE"]
thread_id = os.environ["OMG_CODEX_TEST_THREAD_ID"]
turn_number = 0
active_turn = None


def emit(value, split=False):
    data = (json.dumps(value, ensure_ascii=False) + "\n").encode()
    if split:
        boundary = data.index("🌱".encode()) + 1
        sys.stdout.buffer.write(data[:boundary])
        sys.stdout.buffer.flush()
        time.sleep(0.01)
        sys.stdout.buffer.write(data[boundary:])
    else:
        sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def note(method, params):
    emit({"method": method, "params": dict(threadId=thread_id, **params)})


def reply(request, result):
    emit({"id": request["id"], "result": result})


def thread(identifier=thread_id):
    value = {"id": identifier, "cwd": os.getcwd(), "turns": [{"id": "history-turn", "status": "completed", "items": [
        {"type": "userMessage", "id": "history-user", "content": [{"type": "text", "text": "Earlier prompt"}]},
        {"type": "agentMessage", "id": "history-agent", "text": "Earlier response"},
        {"type": "commandExecution", "id": "old-command", "command": "must never replay", "status": "completed"}
    ]}]}
    if mode == "interrupt_complete" and active_turn:
        value["turns"].append({"id": active_turn, "status": "completed", "items": []})
    return value


for line in sys.stdin:
    request = json.loads(line)
    with open(capture, "a") as log:
        log.write(json.dumps(request) + "\n")
    method = request.get("method")
    if method == "initialize":
        if mode != "timeout":
            reply(request, {})
    elif method == "thread/start":
        reply(request, {"thread": {"id": thread_id, "cwd": os.getcwd(), "turns": []}})
    elif method == "thread/read":
        reply(request, {"thread": thread("wrong-thread" if mode == "mismatch" else thread_id)})
    elif method == "thread/resume":
        reply(request, {"thread": thread()})
    elif method == "turn/start":
        turn_number += 1
        active_turn = f"turn-{turn_number}"
        note("turn/started", {"turn": {"id": active_turn, "status": "inProgress"}})
        note("item/started", {"turnId": active_turn, "item": {"type": "userMessage", "id": f"user-{turn_number}", "content": request["params"]["input"]}})
        if mode in ("interrupt", "interrupt_complete"):
            reply(request, {"turn": {"id": active_turn, "status": "inProgress"}})
        elif mode == "approval":
            reply(request, {"turn": {"id": active_turn, "status": "inProgress"}})
            emit({"id": 901, "method": "item/commandExecution/requestApproval", "params": {"threadId": thread_id, "turnId": active_turn, "itemId": "command-1", "command": "echo test", "reason": "A synthetic approval"}})
        else:
            emit({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": active_turn, "itemId": f"agent-{turn_number}", "delta": "Hello 🌱"}}, split=True)
            note("item/completed", {"turnId": active_turn, "item": {"type": "agentMessage", "id": f"agent-{turn_number}", "text": "Hello 🌱"}})
            note("turn/completed", {"turn": {"id": active_turn, "status": "completed", "error": None}})
            # Completion can precede the request reply; a late reply must not resurrect work.
            reply(request, {"turn": {"id": active_turn, "status": "inProgress"}})
    elif method == "turn/interrupt":
        if mode == "interrupt_complete":
            emit({"id": request["id"], "error": {"code": -32600, "message": "no active turn to interrupt"}})
        else:
            reply(request, {})
            note("turn/completed", {"turn": {"id": active_turn, "status": "interrupted", "error": None}})
    elif method is None and request.get("id") == 901:
        emit({"id": "question-902", "method": "item/tool/requestUserInput", "params": {"threadId": thread_id, "turnId": active_turn, "itemId": "question-item", "questions": [{"id": "tone", "question": "Choose tone", "isOther": True, "options": [{"label": "Calm", "description": "Short and clear"}]}]}})
    elif method is None and request.get("id") == "question-902":
        note("turn/completed", {"turn": {"id": active_turn, "status": "completed", "error": None}})
